use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, Mutex, Notify as Wake};
use tokio::task::JoinSet;
use veilid_core::{
    api_startup, AllowOffline, Crypto, DHTSchema, DHTSchemaSMPLMember, KeyPair, Nonce, RecordKey,
    RoutingContext, SetDHTValueOptions, SharedSecret, TableDB, VeilidAPI, VeilidConfig,
    VeilidUpdate, CRYPTO_KIND_VLD0,
};

use crate::core::{Book, Contact, Effect, Error, Media, Message, CHUNK, HELLO, MEDIA_MAX, SUBKEYS};

const BOOK: &[u8] = b"book";
const POLL: Duration = Duration::from_secs(20);
const FETCH_TRIES: u32 = 4;
const AEAD_TAG: u64 = 16;

pub type Notify = Arc<dyn Fn(Value) + Send + Sync>;

const KEYS: &str = "chat could not open its keys on this phone";
const STORAGE: &str = "chat could not read what it keeps on this phone";
const NETWORK: &str = "chat could not join the Veilid network";

#[derive(Clone, Debug)]
pub struct StartError {
    pub what: &'static str,
    pub detail: String,
}

fn at<E: std::fmt::Display>(what: &'static str) -> impl FnOnce(E) -> StartError {
    move |e| StartError {
        what,
        detail: e.to_string(),
    }
}

pub struct Node {
    api: VeilidAPI,
    rc: RoutingContext,
    db: TableDB,
    book: Mutex<Book>,
    notify: Notify,
    opened: Mutex<HashSet<String>>,
    retry: Mutex<Vec<Effect>>,
    wake: Arc<Wake>,
    dir: PathBuf,
    fetch: mpsc::UnboundedSender<(String, u64)>,
    media: Mutex<()>,
}

impl Node {
    pub async fn start(dir: &str, notify: Notify) -> Result<Arc<Node>, StartError> {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let wake = Arc::new(Wake::new());
        let callback = {
            let notify = notify.clone();
            let wake = wake.clone();
            Arc::new(move |update: VeilidUpdate| match update {
                VeilidUpdate::ValueChange(change) => {
                    let _ = tx.send(change);
                }
                VeilidUpdate::Attachment(a) => {
                    wake.notify_one();
                    notify(json!({"event": "attachment", "state": a.state.to_string()}))
                }
                _ => {}
            })
        };
        let mut config = VeilidConfig::new("upgrade-chat", "", "", Some(dir), Some(dir));
        config.protected_store.always_use_insecure_storage = !cfg!(target_os = "android");
        let api = api_startup(callback, config).await.map_err(at(KEYS))?;
        let rc = api.routing_context().map_err(at(NETWORK))?;
        let db = api.open_table_db("chat", 1).await.map_err(at(STORAGE))?;
        let book = match db
            .load(0, BOOK.to_vec().into())
            .await
            .map_err(at(STORAGE))?
        {
            Some(bytes) => serde_json::from_slice(&bytes).map_err(at(STORAGE))?,
            None => Book::new(""),
        };
        let retry = Mutex::new(book.resend());
        let (fetch, fetches) = mpsc::unbounded_channel();
        let _ = fs::remove_dir_all(PathBuf::from(dir).join("media-open"));
        let node = Arc::new(Node {
            api,
            rc,
            db,
            book: Mutex::new(book),
            notify,
            opened: Mutex::default(),
            retry,
            wake,
            dir: PathBuf::from(dir),
            fetch,
            media: Mutex::default(),
        });
        node.api.attach().await.map_err(at(NETWORK))?;

        let watcher = node.clone();
        tokio::spawn(async move {
            while let Some(change) = rx.recv().await {
                let record = change.key.to_string();
                let mut subkeys = change.subkeys.iter();
                let mut work = Vec::new();
                // Veilid has checked the value's signature, and it is the first subkey's.
                if let Some(value) = &change.value {
                    if let Some(first) = subkeys.next() {
                        let seen = watcher
                            .book
                            .lock()
                            .await
                            .observe(&record, first, value.data());
                        work.extend(seen.unwrap_or_default());
                    }
                }
                work.extend(subkeys.map(|subkey| Effect::Read {
                    record: record.clone(),
                    subkey,
                }));
                watcher.run(work).await;
            }
        });
        tokio::spawn(node.clone().fetcher(fetches));
        let poller = node.clone();
        tokio::spawn(async move {
            loop {
                poller.tick().await;
                tokio::select! {
                    _ = tokio::time::sleep(POLL) => {}
                    _ = poller.wake.notified() => {}
                }
            }
        });
        Ok(node)
    }

    async fn tick(&self) {
        self.open_all().await;
        let mut retry = std::mem::take(&mut *self.retry.lock().await);
        let records = self.book.lock().await.records();
        retry.retain(|e| match e {
            Effect::Write { record, .. } => records.iter().any(|(r, _)| r == record),
            _ => false,
        });
        self.run(retry).await;
        let reads = self.book.lock().await.catch_up();
        self.run(reads).await;
    }

    async fn open_all(&self) {
        let mut records = self.book.lock().await.records();
        {
            let opened = self.opened.lock().await;
            records.retain(|(r, _)| !opened.contains(r));
        }
        for (record, writer) in records {
            let _ = self.open(&record, writer.as_deref()).await;
        }
    }

    async fn open(&self, record: &str, writer: Option<&str>) -> Result<(), Error> {
        let key = RecordKey::from_str(record)?;
        let writer = writer.map(KeyPair::from_str).transpose()?;
        let _ = self.rc.open_dht_record(key.clone(), writer, None).await?;
        self.rc.watch_dht_values(key, None, None, None).await?;
        self.opened.lock().await.insert(record.to_owned());
        Ok(())
    }

    async fn run(&self, mut work: Vec<Effect>) {
        let mut changed = false;
        while !work.is_empty() {
            // Local effects go first and are shown before any network round trip.
            let local = work
                .iter()
                .position(|e| matches!(e, Effect::Stored { .. } | Effect::Changed));
            if local.is_none() && changed {
                self.publish().await;
                changed = false;
            }
            match work.remove(local.unwrap_or(0)) {
                Effect::Write {
                    record,
                    subkey,
                    data,
                } => self.write(record, subkey, data).await,
                Effect::Read { record, subkey } => work.extend(self.read(&record, subkey).await),
                Effect::Stored { contact, message } => {
                    self.stored(contact, message).await;
                    changed = true;
                }
                Effect::Changed => changed = true,
                Effect::Joined => {
                    self.open_all().await;
                    changed = true;
                }
                Effect::Drop { record } => self.forget(&record).await,
            }
        }
        if changed {
            self.publish().await;
        }
    }

    async fn write(&self, record: String, subkey: u32, data: Vec<u8>) {
        let options = SetDHTValueOptions {
            allow_offline: Some(AllowOffline(true)),
            ..Default::default()
        };
        let Ok(key) = RecordKey::from_str(&record) else {
            return;
        };
        let r = self
            .rc
            .set_dht_value(key, subkey, data.clone(), Some(options))
            .await;
        if r.is_err() {
            self.retry.lock().await.push(Effect::Write {
                record,
                subkey,
                data,
            });
        }
    }

    async fn read(&self, record: &str, subkey: u32) -> Vec<Effect> {
        let Ok(key) = RecordKey::from_str(record) else {
            return Vec::new();
        };
        let Ok(Some(value)) = self.rc.get_dht_value(key, subkey, true).await else {
            return Vec::new();
        };
        let more = self.book.lock().await.observe(record, subkey, value.data());
        more.unwrap_or_default()
    }

    async fn stored(&self, contact: String, message: Message) {
        let _ = self.store(&contact, &message).await;
        if !message.mine && message.media.as_ref().is_some_and(|m| !m.stored) {
            let _ = self.fetch.send((contact, message.index));
        }
    }

    async fn fetcher(self: Arc<Self>, mut fetches: mpsc::UnboundedReceiver<(String, u64)>) {
        while let Some((contact, index)) = fetches.recv().await {
            for _ in 0..FETCH_TRIES {
                if self.fetch(&contact, index).await.is_ok() {
                    break;
                }
                tokio::time::sleep(POLL).await;
            }
        }
    }

    async fn publish(&self) {
        let _ = self.save().await;
        (self.notify)(json!({"event": "changed"}));
    }

    async fn forget(&self, record: &str) {
        self.opened.lock().await.remove(record);
        if let Ok(key) = RecordKey::from_str(record) {
            let _ = self.rc.close_dht_record(key.clone()).await;
            let _ = self.rc.delete_dht_record(key).await;
        }
    }

    async fn create(&self, schema: DHTSchema) -> Result<(String, String), Error> {
        let record = self
            .rc
            .create_dht_record(CRYPTO_KIND_VLD0, schema, None)
            .await?;
        let Some(owner) = record.owner_keypair() else {
            return Err(Error("the record came back without its owner key".into()));
        };
        let key = record.key();
        if self
            .rc
            .watch_dht_values(key.clone(), None, None, None)
            .await
            .is_ok()
        {
            self.opened.lock().await.insert(key.to_string());
        }
        Ok((key.to_string(), owner.to_string()))
    }

    async fn save(&self) -> Result<(), Error> {
        let bytes = serde_json::to_vec(&*self.book.lock().await)?;
        self.db.store(0, BOOK.to_vec().into(), bytes.into()).await?;
        Ok(())
    }

    pub async fn call(&self, request: Value) -> Result<Value, Error> {
        let op = request["op"].as_str().unwrap_or_default();
        let text = |field: &str| request[field].as_str().unwrap_or_default().to_owned();
        let index = || request["index"].as_u64().unwrap_or_default();
        match op {
            "state" => self.state().await,
            "name" => {
                self.book.lock().await.name = text("name");
                self.save().await?;
                Ok(Value::Null)
            }
            "invite" => self.invite().await,
            "join" => self.join(&text("code")).await,
            "send" => {
                let at = request["at"].as_u64().unwrap_or_default();
                let effects = self
                    .book
                    .lock()
                    .await
                    .send(&text("record"), &text("text"), at)?;
                self.run(effects).await;
                Ok(Value::Null)
            }
            "messages" => self.messages(&text("record")).await,
            "media" => {
                let views = request["views"].as_u64().unwrap_or_default().min(2) as u32;
                let at = request["at"].as_u64().unwrap_or_default();
                self.send_media(&text("record"), &text("path"), &text("kind"), views, at)
                    .await
            }
            "open" => self.view(&text("record"), index()).await,
            "close" => self.close(&text("record"), index()).await,
            "verify" => self.edit(&text("record"), |c| c.verified = true).await,
            "rename" => self.edit(&text("record"), |c| c.name = text("name")).await,
            "remove" => self.remove(&text("record")).await,
            _ => Err(Error(format!("unknown op {op}"))),
        }
    }

    async fn state(&self) -> Result<Value, Error> {
        let (name, mut contacts) = {
            let book = self.book.lock().await;
            let contacts: Vec<Value> = book
                .contacts
                .iter()
                .map(|c| {
                    json!({
                        "record": c.record,
                        "name": c.name,
                        "verified": c.verified,
                        "safety": book.safety(&c.record),
                        "count": c.count,
                    })
                })
                .collect();
            (book.name.clone(), contacts)
        };
        for contact in &mut contacts {
            let (Some(record), Some(count)) =
                (contact["record"].as_str(), contact["count"].as_u64())
            else {
                continue;
            };
            let Some(last) = count.checked_sub(1) else {
                continue;
            };
            if let Some(message) = self.load(record, last).await? {
                contact["last"] = public(&message)?;
            }
        }
        let attachment = self.api.get_state().await?.attachment.state.to_string();
        Ok(json!({"name": name, "attachment": attachment, "contacts": contacts}))
    }

    async fn invite(&self) -> Result<Value, Error> {
        let member = Crypto::generate_keypair(CRYPTO_KIND_VLD0)?;
        let schema = DHTSchema::smpl(
            HELLO as u16,
            vec![DHTSchemaSMPLMember {
                m_key: self.api.generate_member_id(&member.key())?.value(),
                m_cnt: 1,
            }],
        )?;
        let (record, writer) = self.create(schema).await?;
        let (mine, mine_writer) = self.create(DHTSchema::dflt(SUBKEYS as u16)?).await?;
        let (code, stale) = {
            let mut book = self.book.lock().await;
            let stale = book.invite_records();
            let code = book.invite(&record, &writer, &member.to_string(), &mine, &mine_writer);
            (code, stale)
        };
        for stale in stale {
            self.forget(&stale).await;
        }
        self.save().await?;
        let ack = serde_json::to_vec(&json!({"ack": 0}))?;
        let publish = [record, mine].map(|record| Effect::Write {
            record,
            subkey: 0,
            data: ack.clone(),
        });
        self.run(publish.into()).await;
        Ok(json!({"code": code}))
    }

    async fn join(&self, code: &str) -> Result<Value, Error> {
        let (mine, writer) = self.create(DHTSchema::dflt(SUBKEYS as u16)?).await?;
        let joined = self.book.lock().await.join(code, &mine, &writer);
        let effects = match joined {
            Ok(effects) => effects,
            Err(e) => {
                self.forget(&mine).await;
                return Err(e);
            }
        };
        self.run(effects).await;
        self.save().await?;
        Ok(Value::Null)
    }

    async fn messages(&self, record: &str) -> Result<Value, Error> {
        let (count, acked) = match self.book.lock().await.contact(record) {
            Some(c) => (c.count, c.acked),
            None => return Err(Error("no such contact".into())),
        };
        let mut out = Vec::new();
        for index in 0..count {
            let Some(message) = self.load(record, index).await? else {
                continue;
            };
            let mut value = public(&message)?;
            value["delivered"] = json!(message.mine && message.seq <= acked);
            out.push(value);
        }
        Ok(Value::Array(out))
    }

    async fn edit(&self, record: &str, change: impl FnOnce(&mut Contact)) -> Result<Value, Error> {
        {
            let mut book = self.book.lock().await;
            let Some(contact) = book.contact_mut(record) else {
                return Err(Error("no such contact".into()));
            };
            change(contact);
        }
        self.save().await?;
        Ok(Value::Null)
    }

    async fn remove(&self, record: &str) -> Result<Value, Error> {
        let Some(contact) = ({
            let mut book = self.book.lock().await;
            let at = book.contacts.iter().position(|c| c.record == record);
            at.map(|at| book.contacts.remove(at))
        }) else {
            return Err(Error("no such contact".into()));
        };
        self.save().await?;
        let _media = self.media.lock().await;
        for index in 0..contact.count {
            let _ = self.db.delete(0, message_key(record, index).into()).await;
            let _ = fs::remove_file(self.sealed(record, index));
        }
        for record in [&contact.record, &contact.mine, &contact.theirs] {
            self.forget(record).await;
        }
        Ok(Value::Null)
    }
    async fn load(&self, record: &str, index: u64) -> Result<Option<Message>, Error> {
        let Some(bytes) = self.db.load(0, message_key(record, index).into()).await? else {
            return Ok(None);
        };
        Ok(Some(serde_json::from_slice(&bytes)?))
    }

    async fn store(&self, record: &str, message: &Message) -> Result<(), Error> {
        let bytes = serde_json::to_vec(message)?;
        self.db
            .store(0, message_key(record, message.index).into(), bytes.into())
            .await?;
        Ok(())
    }

    fn sealed(&self, record: &str, index: u64) -> PathBuf {
        self.dir.join("media").join(file_name(record, index))
    }

    fn viewed(&self, record: &str, index: u64) -> PathBuf {
        self.dir.join("media-open").join(file_name(record, index))
    }

    async fn send_media(
        &self,
        record: &str,
        path: &str,
        kind: &str,
        views: u32,
        at: u64,
    ) -> Result<Value, Error> {
        let plain = fs::read(path)?;
        if plain.is_empty() || plain.len() as u64 > MEDIA_MAX - AEAD_TAG {
            return Err(Error(format!(
                "media goes up to {} MB",
                MEDIA_MAX / 1024 / 1024
            )));
        }
        let crypto = self.api.crypto()?;
        let Some(vld) = crypto.get_async(CRYPTO_KIND_VLD0) else {
            return Err(Error("no VLD0 crypto".into()));
        };
        let (key, nonce) = (vld.random_shared_secret().await, vld.random_nonce().await);
        let sealed = vld
            .encrypt_aead(plain.into(), &nonce, &key, None)
            .await?
            .to_vec();
        let media = Media {
            kind: kind.to_owned(),
            records: self.upload(&sealed).await?,
            size: sealed.len() as u64,
            key: key.to_string(),
            nonce: nonce.to_string(),
            views,
            seen: 0,
            stored: false,
        };
        let effects = {
            let mut book = self.book.lock().await;
            let index = book.contact(record).map(|c| c.count).unwrap_or_default();
            let path = self.sealed(record, index);
            if views == 0 {
                write(&path, &sealed)?;
            }
            book.send_media(record, media, at).inspect_err(|_| {
                let _ = fs::remove_file(&path);
            })?
        };
        self.run(effects).await;
        Ok(Value::Null)
    }

    async fn upload(&self, sealed: &[u8]) -> Result<Vec<String>, Error> {
        let mut records = Vec::new();
        for part in sealed.chunks(CHUNK * SUBKEYS as usize) {
            let chunks: Vec<Vec<u8>> = part.chunks(CHUNK).map(<[u8]>::to_vec).collect();
            let schema = DHTSchema::dflt(chunks.len() as u16)?;
            let key = self
                .rc
                .create_dht_record(CRYPTO_KIND_VLD0, schema, None)
                .await?
                .key();
            let mut writes = JoinSet::new();
            for (subkey, chunk) in chunks.into_iter().enumerate() {
                let (rc, key) = (self.rc.clone(), key.clone());
                let online = SetDHTValueOptions {
                    allow_offline: Some(AllowOffline(false)),
                    ..Default::default()
                };
                writes.spawn(async move {
                    rc.set_dht_value(key, subkey as u32, chunk, Some(online))
                        .await
                });
            }
            let done = writes.join_all().await;
            self.forget(&key.to_string()).await;
            for write in done {
                write?;
            }
            records.push(key.to_string());
        }
        Ok(records)
    }

    async fn download(&self, media: &Media) -> Result<Vec<u8>, Error> {
        let size = media.size as usize;
        let mut sealed = Vec::with_capacity(size);
        let ours: HashSet<String> = {
            let book = self.book.lock().await;
            let records = book.records().into_iter().map(|(record, _)| record);
            records.chain(book.invite_records()).collect()
        };
        if media.records.iter().any(|record| ours.contains(record)) {
            return Err(Error(
                "the media points at a conversation's own record".into(),
            ));
        }
        for record in &media.records {
            let key = RecordKey::from_str(record)?;
            let _ = self.rc.open_dht_record(key.clone(), None, None).await?;
            let count = (size - sealed.len()).div_ceil(CHUNK).min(SUBKEYS as usize);
            let mut reads = JoinSet::new();
            for subkey in 0..count as u32 {
                let (rc, key) = (self.rc.clone(), key.clone());
                reads.spawn(async move { (subkey, rc.get_dht_value(key, subkey, true).await) });
            }
            let mut done = reads.join_all().await;
            self.forget(record).await;
            done.sort_by_key(|(subkey, _)| *subkey);
            for (_, read) in done {
                let Some(value) = read? else {
                    return Err(Error("a piece of the media is missing".into()));
                };
                if value.data().len() > CHUNK || sealed.len() + value.data().len() > size {
                    return Err(Error("a piece of the media does not fit".into()));
                }
                sealed.extend_from_slice(value.data());
            }
        }
        if sealed.len() != size {
            return Err(Error("the media came back short".into()));
        }
        Ok(sealed)
    }

    async fn fetch(&self, record: &str, index: u64) -> Result<(), Error> {
        let _media = self.media.lock().await;
        let Some(mut message) = self.load(record, index).await? else {
            return Err(Error("no such message".into()));
        };
        let Some(media) = message.media.as_mut() else {
            return Err(Error("no media in this message".into()));
        };
        if media.stored || media.spent() || message.mine {
            return Ok(());
        }
        write(&self.sealed(record, index), &self.download(media).await?)?;
        media.stored = true;
        self.store(record, &message).await?;
        self.publish().await;
        Ok(())
    }

    /// The view is counted, and the last one deletes the sealed copy and the key, before the
    /// picture is handed out: a phone that dies while showing it has still spent it.
    async fn view(&self, record: &str, index: u64) -> Result<Value, Error> {
        self.fetch(record, index).await?;
        let _media = self.media.lock().await;
        let Some(mut message) = self.load(record, index).await? else {
            return Err(Error("no such message".into()));
        };
        let Some(media) = message.media.as_mut() else {
            return Err(Error("no media in this message".into()));
        };
        if media.spent() || !media.stored {
            return Err(Error("this media is gone".into()));
        }
        let crypto = self.api.crypto()?;
        let Some(vld) = crypto.get_async(CRYPTO_KIND_VLD0) else {
            return Err(Error("no VLD0 crypto".into()));
        };
        let plain = vld
            .decrypt_aead(
                fs::read(self.sealed(record, index))?.into(),
                &Nonce::from_str(&media.nonce)?,
                &SharedSecret::from_str(&media.key)?,
                None,
            )
            .await?;
        if media.views > 0 {
            media.seen += 1;
            if media.spent() {
                fs::remove_file(self.sealed(record, index))?;
                media.stored = false;
                media.key.clear();
                media.nonce.clear();
            }
            self.store(record, &message).await?;
        }
        let path = self.viewed(record, index);
        write(&path, &plain)?;
        self.publish().await;
        Ok(json!({"path": path.to_string_lossy()}))
    }

    async fn close(&self, record: &str, index: u64) -> Result<Value, Error> {
        let _media = self.media.lock().await;
        let _ = fs::remove_file(self.viewed(record, index));
        Ok(Value::Null)
    }
}

fn file_name(record: &str, index: u64) -> String {
    format!("{}-{index}", record.replace(':', "_"))
}

fn write(path: &std::path::Path, bytes: &[u8]) -> Result<(), Error> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, bytes)?;
    Ok(())
}

fn public(message: &Message) -> Result<Value, Error> {
    let mut value = serde_json::to_value(message)?;
    if let Some(media) = value.get_mut("media").and_then(Value::as_object_mut) {
        for secret in ["key", "nonce", "records"] {
            media.remove(secret);
        }
    }
    Ok(value)
}

fn message_key(record: &str, index: u64) -> Vec<u8> {
    format!("m/{record}/{index}").into_bytes()
}
