use std::collections::HashSet;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{mpsc, Mutex, Notify as Wake};
use veilid_core::{
    api_startup, AllowOffline, Crypto, DHTSchema, DHTSchemaSMPLMember, KeyPair, RecordKey,
    RoutingContext, SetDHTValueOptions, TableDB, VeilidAPI, VeilidConfig, VeilidUpdate,
    CRYPTO_KIND_VLD0,
};

use crate::core::{Book, Contact, Effect, Error, Message, HELLO, SUBKEYS};

const BOOK: &[u8] = b"book";
const POLL: Duration = Duration::from_secs(20);

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
        let node = Arc::new(Node {
            api,
            rc,
            db,
            book: Mutex::new(book),
            notify,
            opened: Mutex::default(),
            retry,
            wake,
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
                } => {
                    let options = SetDHTValueOptions {
                        allow_offline: Some(AllowOffline(true)),
                        ..Default::default()
                    };
                    let Ok(key) = RecordKey::from_str(&record) else {
                        continue;
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
                Effect::Read { record, subkey } => {
                    let Ok(key) = RecordKey::from_str(&record) else {
                        continue;
                    };
                    let Ok(Some(value)) = self.rc.get_dht_value(key, subkey, true).await else {
                        continue;
                    };
                    let more = self
                        .book
                        .lock()
                        .await
                        .observe(&record, subkey, value.data());
                    if let Ok(more) = more {
                        work.extend(more);
                    }
                }
                Effect::Stored { contact, message } => {
                    let _ = self
                        .db
                        .store(
                            0,
                            message_key(&contact, message.index).into(),
                            serde_json::to_vec(&message).unwrap_or_default().into(),
                        )
                        .await;
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
            if let Some(bytes) = self.db.load(0, message_key(record, last).into()).await? {
                contact["last"] = serde_json::from_slice(&bytes)?;
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
            let Some(bytes) = self.db.load(0, message_key(record, index).into()).await? else {
                continue;
            };
            let message: Message = serde_json::from_slice(&bytes)?;
            let delivered = message.mine && message.seq <= acked;
            let mut value = serde_json::to_value(&message)?;
            value["delivered"] = json!(delivered);
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
        for index in 0..contact.count {
            let _ = self.db.delete(0, message_key(record, index).into()).await;
        }
        for record in [&contact.record, &contact.mine, &contact.theirs] {
            self.forget(record).await;
        }
        Ok(Value::Null)
    }
}

fn message_key(record: &str, index: u64) -> Vec<u8> {
    format!("m/{record}/{index}").into_bytes()
}
