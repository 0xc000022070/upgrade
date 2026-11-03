use std::collections::BTreeMap;

use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde::{Deserializer, Serializer};
use sha2::{Digest, Sha256};
use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;

pub const SUBKEYS: u32 = 32;
const SLOTS: u64 = SUBKEYS as u64 - 1;
pub const HELLO: u32 = 1;

#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    Write {
        record: String,
        subkey: u32,
        data: Vec<u8>,
    },
    Read {
        record: String,
        subkey: u32,
    },
    Stored {
        contact: String,
        message: Message,
    },
    Joined,
    Drop {
        record: String,
    },
    Changed,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub index: u64,
    pub mine: bool,
    pub body: String,
    pub at: u64,
    pub seq: u64,
}

#[derive(Serialize, Deserialize)]
struct Invite {
    record: String,
    writer: String,
    mine: String,
    mine_writer: String,
    otk: String,
}

#[derive(Serialize, Deserialize)]
pub struct Contact {
    pub record: String,
    pub name: String,
    pub peer: String,
    pub verified: bool,
    pub owner: bool,
    pub mine: String,
    pub writer: String,
    pub theirs: String,
    pub member: Option<String>,
    #[serde(with = "pickled_session")]
    session: Session,
    pub sent: u64,
    pub acked: u64,
    pub read: u64,
    pub count: u64,
    queue: BTreeMap<u64, Vec<u8>>,
    #[serde(default)]
    outbox: BTreeMap<u64, Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
pub struct Book {
    #[serde(with = "pickled_account")]
    account: Account,
    pub name: String,
    invite: Option<Invite>,
    pub contacts: Vec<Contact>,
}

#[derive(Serialize, Deserialize)]
struct Code {
    v: u8,
    name: String,
    key: String,
    otk: String,
    record: String,
    member: String,
    theirs: String,
}

#[derive(Serialize, Deserialize)]
struct Envelope {
    seq: u64,
    olm: OlmMessage,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Payload {
    Hello { name: String, record: String },
    Text { body: String, at: u64 },
}

#[derive(Serialize, Deserialize)]
struct Ack {
    ack: u64,
}

#[derive(Debug)]
pub struct Error(pub String);

impl<E: std::fmt::Display> From<E> for Error {
    fn from(e: E) -> Self {
        Error(e.to_string())
    }
}

fn fail<T>(why: &str) -> Result<T, Error> {
    Err(Error(why.to_owned()))
}

impl Book {
    pub fn new(name: &str) -> Self {
        Book {
            account: Account::new(),
            name: name.to_owned(),
            invite: None,
            contacts: Vec::new(),
        }
    }

    pub fn identity(&self) -> String {
        self.account.curve25519_key().to_base64()
    }

    pub fn invite_records(&self) -> Vec<String> {
        self.invite
            .iter()
            .flat_map(|i| [i.record.clone(), i.mine.clone()])
            .collect()
    }

    pub fn records(&self) -> Vec<(String, Option<String>)> {
        let mut out = Vec::new();
        for c in &self.contacts {
            out.push((c.mine.clone(), Some(c.writer.clone())));
            out.push((c.theirs.clone(), None));
            if let Some(member) = &c.member {
                out.push((c.record.clone(), Some(member.clone())));
            }
        }
        if let Some(i) = &self.invite {
            out.push((i.record.clone(), Some(i.writer.clone())));
            out.push((i.mine.clone(), Some(i.mine_writer.clone())));
        }
        out
    }

    pub fn invite(
        &mut self,
        record: &str,
        writer: &str,
        member: &str,
        mine: &str,
        mine_writer: &str,
    ) -> String {
        let otk = self.account.generate_one_time_keys(1).created[0];
        self.account.mark_keys_as_published();
        self.invite = Some(Invite {
            record: record.to_owned(),
            writer: writer.to_owned(),
            mine: mine.to_owned(),
            mine_writer: mine_writer.to_owned(),
            otk: otk.to_base64(),
        });
        let code = Code {
            v: 1,
            name: self.name.clone(),
            key: self.identity(),
            otk: otk.to_base64(),
            record: record.to_owned(),
            member: member.to_owned(),
            theirs: mine.to_owned(),
        };
        B64.encode(serde_json::to_vec(&code).expect("code serializes"))
    }

    pub fn join(&mut self, code: &str, mine: &str, writer: &str) -> Result<Vec<Effect>, Error> {
        let code: Code = serde_json::from_slice(&B64.decode(code.trim())?)?;
        if code.v != 1 {
            return fail("unknown invitation version");
        }
        if code.key == self.identity() {
            return fail("this is your own invitation");
        }
        if self.contact(&code.record).is_some() {
            return fail("already joined");
        }
        let session = self.account.create_outbound_session(
            SessionConfig::version_1(),
            Curve25519PublicKey::from_base64(&code.key)?,
            Curve25519PublicKey::from_base64(&code.otk)?,
        )?;
        self.contacts.push(Contact {
            record: code.record.clone(),
            name: code.name,
            peer: code.key,
            verified: false,
            owner: false,
            mine: mine.to_owned(),
            writer: writer.to_owned(),
            theirs: code.theirs,
            member: Some(code.member),
            session,
            sent: 0,
            acked: 0,
            read: 0,
            count: 0,
            queue: BTreeMap::new(),
            outbox: BTreeMap::new(),
        });
        let hello = Payload::Hello {
            name: self.name.clone(),
            record: mine.to_owned(),
        };
        let mut out = vec![Effect::Joined];
        out.extend(self.enqueue(&code.record, &hello)?);
        let contact = self.contact(&code.record).unwrap();
        out.push(ack(contact));
        out.extend(peer_reads(contact));
        Ok(out)
    }

    pub fn send(&mut self, record: &str, body: &str, at: u64) -> Result<Vec<Effect>, Error> {
        let payload = Payload::Text {
            body: body.to_owned(),
            at,
        };
        let mut out = self.enqueue(record, &payload)?;
        let contact = self.contact_mut(record).unwrap();
        let message = Message {
            index: contact.count,
            mine: true,
            body: body.to_owned(),
            at,
            seq: contact.sent,
        };
        contact.count += 1;
        out.push(Effect::Stored {
            contact: record.to_owned(),
            message,
        });
        Ok(out)
    }

    fn enqueue(&mut self, record: &str, payload: &Payload) -> Result<Vec<Effect>, Error> {
        let Some(contact) = self.contact_mut(record) else {
            return fail("no such contact");
        };
        contact.sent += 1;
        contact
            .queue
            .insert(contact.sent, serde_json::to_vec(payload)?);
        flush(contact)
    }

    pub fn observe(
        &mut self,
        record: &str,
        subkey: u32,
        data: &[u8],
    ) -> Result<Vec<Effect>, Error> {
        let Some(contact) = self.contacts.iter_mut().find(|c| c.theirs == record) else {
            return self.accept(record, subkey, data);
        };
        if subkey >= SUBKEYS {
            return Ok(Vec::new());
        }
        if subkey == 0 {
            let Ok(Ack { ack }) = serde_json::from_slice(data) else {
                return Ok(Vec::new());
            };
            if ack <= contact.acked || ack > contact.sent {
                return Ok(Vec::new());
            }
            contact.acked = ack;
            contact.outbox.retain(|&seq, _| seq > ack);
            let mut out = flush(contact)?;
            if contact.member.take().is_some() {
                out.push(Effect::Drop {
                    record: contact.record.clone(),
                });
            }
            out.push(Effect::Changed);
            return Ok(out);
        }
        let Ok(envelope) = serde_json::from_slice::<Envelope>(data) else {
            return Ok(Vec::new());
        };
        if envelope.seq != contact.read + 1 || slot(envelope.seq) != subkey {
            return Ok(Vec::new());
        }
        let Ok(plain) = contact.session.decrypt(&envelope.olm) else {
            return Ok(Vec::new());
        };
        let id = contact.record.clone();
        self.receive(&id, plain)
    }

    fn accept(&mut self, record: &str, subkey: u32, data: &[u8]) -> Result<Vec<Effect>, Error> {
        let Some(invite) = self.invite.as_ref().filter(|i| i.record == record) else {
            return Ok(Vec::new());
        };
        if subkey != HELLO {
            return Ok(Vec::new());
        }
        let Ok(Envelope {
            seq: 1,
            olm: OlmMessage::PreKey(pre),
        }) = serde_json::from_slice(data)
        else {
            return Ok(Vec::new());
        };
        if pre.one_time_key().to_base64() != invite.otk {
            return Ok(Vec::new());
        }
        // Taking the one-time key is final, so a hello that does not parse
        // is checked on a copy before the account gives it up.
        let mut account = Account::from_pickle(self.account.pickle());
        let Ok(inbound) =
            account.create_inbound_session(SessionConfig::version_1(), pre.identity_key(), &pre)
        else {
            return Ok(Vec::new());
        };
        let Ok(Payload::Hello {
            name,
            record: theirs,
        }) = serde_json::from_slice(&inbound.plaintext)
        else {
            return Ok(Vec::new());
        };
        self.account = account;
        let invite = self.invite.take().unwrap();
        self.contacts.push(Contact {
            record: invite.record,
            name,
            peer: pre.identity_key().to_base64(),
            verified: false,
            owner: true,
            mine: invite.mine,
            writer: invite.mine_writer,
            theirs,
            member: None,
            session: inbound.session,
            sent: 0,
            acked: 0,
            read: 1,
            count: 0,
            queue: BTreeMap::new(),
            outbox: BTreeMap::new(),
        });
        let contact = self.contact(record).unwrap();
        let mut out = vec![
            Effect::Joined,
            ack(contact),
            Effect::Drop {
                record: record.to_owned(),
            },
        ];
        out.extend(peer_reads(contact));
        Ok(out)
    }

    fn receive(&mut self, record: &str, plain: Vec<u8>) -> Result<Vec<Effect>, Error> {
        let contact = self.contact_mut(record).unwrap();
        contact.read += 1;
        let mut out = vec![ack(contact)];
        if let Ok(Payload::Text { body, at }) = serde_json::from_slice(&plain) {
            let message = Message {
                index: contact.count,
                mine: false,
                body,
                at,
                seq: 0,
            };
            contact.count += 1;
            out.push(Effect::Stored {
                contact: record.to_owned(),
                message,
            });
        }
        out.push(Effect::Read {
            record: contact.theirs.clone(),
            subkey: slot(contact.read + 1),
        });
        Ok(out)
    }

    pub fn contact(&self, record: &str) -> Option<&Contact> {
        self.contacts.iter().find(|c| c.record == record)
    }

    pub fn contact_mut(&mut self, record: &str) -> Option<&mut Contact> {
        self.contacts.iter_mut().find(|c| c.record == record)
    }

    pub fn safety(&self, record: &str) -> Option<String> {
        let contact = self.contact(record)?;
        let mut keys = [self.identity(), contact.peer.clone()];
        keys.sort();
        let hash = Sha256::digest(keys.concat().as_bytes());
        let groups: Vec<String> = hash
            .chunks(2)
            .take(12)
            .map(|c| {
                format!(
                    "{:05}",
                    u32::from(u16::from_be_bytes([c[0], c[1]])) % 100_000
                )
            })
            .collect();
        Some(groups.join(" "))
    }

    pub fn catch_up(&self) -> Vec<Effect> {
        let mut out = Vec::new();
        for contact in &self.contacts {
            out.extend(peer_reads(contact));
        }
        if let Some(invite) = &self.invite {
            out.push(Effect::Read {
                record: invite.record.clone(),
                subkey: HELLO,
            });
        }
        out
    }

    pub fn resend(&self) -> Vec<Effect> {
        let mut out = Vec::new();
        for contact in &self.contacts {
            out.push(ack(contact));
            out.extend(contact.outbox.iter().map(|(&seq, data)| {
                let (record, subkey) = place(contact, seq);
                Effect::Write {
                    record,
                    subkey,
                    data: data.clone(),
                }
            }));
        }
        out
    }
}

fn slot(seq: u64) -> u32 {
    1 + ((seq - 1) % SLOTS) as u32
}

fn place(contact: &Contact, seq: u64) -> (String, u32) {
    if seq == 1 && !contact.owner {
        (contact.record.clone(), HELLO)
    } else {
        (contact.mine.clone(), slot(seq))
    }
}

fn ack(contact: &Contact) -> Effect {
    Effect::Write {
        record: contact.mine.clone(),
        subkey: 0,
        data: serde_json::to_vec(&Ack { ack: contact.read }).expect("ack serializes"),
    }
}

fn peer_reads(contact: &Contact) -> Vec<Effect> {
    vec![
        Effect::Read {
            record: contact.theirs.clone(),
            subkey: 0,
        },
        Effect::Read {
            record: contact.theirs.clone(),
            subkey: slot(contact.read + 1),
        },
    ]
}

fn flush(contact: &mut Contact) -> Result<Vec<Effect>, Error> {
    let mut out = Vec::new();
    while let Some((&seq, _)) = contact.queue.first_key_value() {
        if seq - contact.acked > SLOTS {
            break;
        }
        let plain = contact.queue.remove(&seq).unwrap();
        let envelope = Envelope {
            seq,
            olm: contact.session.encrypt(&plain)?,
        };
        let data = serde_json::to_vec(&envelope)?;
        contact.outbox.insert(seq, data.clone());
        let (record, subkey) = place(contact, seq);
        out.push(Effect::Write {
            record,
            subkey,
            data,
        });
    }
    Ok(out)
}

mod pickled_account {
    use super::*;

    pub fn serialize<S: Serializer>(a: &Account, s: S) -> Result<S::Ok, S::Error> {
        a.pickle().serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Account, D::Error> {
        AccountPickle::deserialize(d).map(Account::from_pickle)
    }
}

mod pickled_session {
    use super::*;

    pub fn serialize<S: Serializer>(a: &Session, s: S) -> Result<S::Ok, S::Error> {
        a.pickle().serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Session, D::Error> {
        SessionPickle::deserialize(d).map(Session::from_pickle)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct Net {
        values: HashMap<(String, u32), Vec<u8>>,
        inbox: [Vec<Message>; 2],
        dropped: Vec<String>,
        drop_watch: bool,
    }

    impl Net {
        fn new() -> Self {
            Net {
                values: HashMap::new(),
                inbox: [Vec::new(), Vec::new()],
                dropped: Vec::new(),
                drop_watch: false,
            }
        }

        fn run(&mut self, books: &mut [Book; 2], from: usize, effects: Vec<Effect>) {
            let mut work: Vec<(usize, Effect)> = effects.into_iter().map(|e| (from, e)).collect();
            while let Some((who, effect)) = (!work.is_empty()).then(|| work.remove(0)) {
                match effect {
                    Effect::Write {
                        record,
                        subkey,
                        data,
                    } => {
                        self.values.insert((record.clone(), subkey), data.clone());
                        if !self.drop_watch {
                            let other = 1 - who;
                            let more = books[other].observe(&record, subkey, &data).unwrap();
                            work.extend(more.into_iter().map(|e| (other, e)));
                        }
                    }
                    Effect::Read { record, subkey } => {
                        if let Some(data) = self.values.get(&(record.clone(), subkey)).cloned() {
                            let more = books[who].observe(&record, subkey, &data).unwrap();
                            work.extend(more.into_iter().map(|e| (who, e)));
                        }
                    }
                    Effect::Stored { message, .. } => {
                        if !message.mine {
                            self.inbox[who].push(message);
                        }
                    }
                    Effect::Drop { record } => self.dropped.push(record),
                    Effect::Joined | Effect::Changed => {}
                }
            }
        }
    }

    fn paired() -> ([Book; 2], Net, String) {
        let (books, net, _) = paired_with_code();
        (books, net, "inv".to_owned())
    }

    fn paired_with_code() -> ([Book; 2], Net, String) {
        let mut books = [Book::new("ana"), Book::new("ben")];
        let mut net = Net::new();
        let code = books[0].invite("inv", "inv-owner", "inv-member", "ra", "ra-owner");
        let effects = books[1].join(&code, "rb", "rb-owner").unwrap();
        net.run(&mut books, 1, effects);
        (books, net, code)
    }

    fn texts(net: &Net, who: usize) -> Vec<&str> {
        net.inbox[who].iter().map(|m| m.body.as_str()).collect()
    }

    #[test]
    fn an_invitation_pairs_both_ends_on_one_safety_number() {
        let (books, _, rec) = paired();
        assert_eq!(books[0].contact(&rec).unwrap().name, "ben");
        assert_eq!(books[1].contact(&rec).unwrap().name, "ana");
        assert!(books[0].invite_records().is_empty());
        assert_eq!(books[0].safety(&rec), books[1].safety(&rec));
        assert_eq!(books[0].safety(&rec).unwrap().len(), 12 * 6 - 1);
    }

    #[test]
    fn messages_cross_both_ways_and_are_acked() {
        let (mut books, mut net, rec) = paired();
        let e = books[1].send(&rec, "hi ana", 1).unwrap();
        net.run(&mut books, 1, e);
        let e = books[0].send(&rec, "hi ben", 2).unwrap();
        net.run(&mut books, 0, e);
        let e = books[0].send(&rec, "again", 3).unwrap();
        net.run(&mut books, 0, e);
        assert_eq!(texts(&net, 0), ["hi ana"]);
        assert_eq!(texts(&net, 1), ["hi ben", "again"]);
        assert_eq!(books[0].contact(&rec).unwrap().acked, 2);
        assert_eq!(books[1].contact(&rec).unwrap().acked, 2);
    }

    #[test]
    fn the_ring_waits_for_acks_and_wraps() {
        let (mut books, mut net, rec) = paired();
        net.drop_watch = true;
        let total = SLOTS + 10;
        for i in 0..total {
            let e = books[0].send(&rec, &format!("m{i}"), i).unwrap();
            net.run(&mut books, 0, e);
        }
        assert_eq!(books[0].contact(&rec).unwrap().queue.len(), 10);
        while texts(&net, 1).len() < total as usize {
            let e = books[1].catch_up();
            net.run(&mut books, 1, e);
            let e = books[0].catch_up();
            net.run(&mut books, 0, e);
        }
        let want: Vec<String> = (0..total).map(|i| format!("m{i}")).collect();
        assert_eq!(texts(&net, 1), want);
        assert!(books[0].contact(&rec).unwrap().queue.is_empty());
    }

    #[test]
    fn writes_lost_offline_land_on_resend() {
        let mut books = [Book::new("ana"), Book::new("ben")];
        let mut net = Net::new();
        let code = books[0].invite("inv", "inv-owner", "inv-member", "ra", "ra-owner");
        let _lost = books[1].join(&code, "rb", "rb-owner").unwrap();
        let _lost = books[1].send("inv", "while offline", 1).unwrap();
        assert!(books[0].contact("inv").is_none());
        let e = books[1].resend();
        net.run(&mut books, 1, e);
        assert_eq!(books[0].contact("inv").unwrap().name, "ben");
        assert_eq!(texts(&net, 0), ["while offline"]);
        assert!(books[1].contact("inv").unwrap().outbox.is_empty());
    }

    #[test]
    fn junk_and_replays_change_nothing() {
        let (mut books, mut net, rec) = paired();
        let e = books[0].send(&rec, "once", 1).unwrap();
        let Effect::Write { subkey, data, .. } = &e[0] else {
            panic!()
        };
        let (subkey, data) = (*subkey, data.clone());
        net.run(&mut books, 0, e);
        assert!(books[1].observe("ra", subkey, &data).unwrap().is_empty());
        assert!(books[1]
            .observe("ra", subkey, b"{\"seq\":2}")
            .unwrap()
            .is_empty());
        assert!(books[1]
            .observe("ra", subkey + 1, &data)
            .unwrap()
            .is_empty());
        assert!(books[1].observe("ra", SUBKEYS, &data).unwrap().is_empty());
        assert_eq!(texts(&net, 1), ["once"]);
    }

    #[test]
    fn a_book_survives_a_round_trip_through_json() {
        let (books, mut net, rec) = paired();
        let mut books: [Book; 2] =
            books.map(|b| serde_json::from_str(&serde_json::to_string(&b).unwrap()).unwrap());
        let e = books[1].send(&rec, "after restart", 9).unwrap();
        net.run(&mut books, 1, e);
        assert_eq!(texts(&net, 0), ["after restart"]);
    }

    #[test]
    fn a_used_invitation_cannot_be_joined_twice() {
        let (books, mut net, code) = paired_with_code();
        let [ana, _] = books;
        let mut pair = [ana, Book::new("eve")];
        let effects = pair[1].join(&code, "re", "re-owner").unwrap();
        net.run(&mut pair, 1, effects);
        assert_eq!(pair[0].contacts.len(), 1);
        assert_eq!(pair[0].contacts[0].name, "ben");
    }

    #[test]
    fn each_side_writes_its_own_record_and_both_drop_the_invitation() {
        let (books, net, rec) = paired();
        let (ana, ben) = (
            books[0].contact(&rec).unwrap(),
            books[1].contact(&rec).unwrap(),
        );
        assert_eq!((ana.mine.as_str(), ana.theirs.as_str()), ("ra", "rb"));
        assert_eq!((ben.mine.as_str(), ben.theirs.as_str()), ("rb", "ra"));
        assert_eq!(ana.writer, "ra-owner");
        assert_eq!(ben.writer, "rb-owner");
        assert!(ben.member.is_none());
        assert_eq!(net.dropped, ["inv", "inv"]);
        for book in &books {
            assert!(book.records().iter().all(|(r, _)| r != "inv"));
        }
    }
}
