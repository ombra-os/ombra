//! ombra-tproxy — lets programs that know nothing about proxies work on the desktop. A local DNS stub answers every
//! name with a placeholder address and remembers which name it stands for; the desktop firewall redirects outgoing TCP
//! here; the connection is handed to the gateway's Tor as a SOCKS5 `CONNECT hostname:port`.
//!
//! Tor's own automap did this job inside the Tor daemon until 1.2.2, where a desktop could flood it (TROVE-2026-036).
//! Here the table lives in a memory-safe program on the untrusted side, and no bug here can reach the network, because
//! the desktop's only route is the gateway's SOCKS port. What the table must still guarantee is between programs on
//! this machine: one program must not be able to change where another program's placeholder leads, nor learn what
//! others looked up. Hence random addresses, no reuse while a name is in use, refusal instead of eviction, and no
//! reverse lookups (see `NameTable`).
//!
//! This module is the logic (name table, DNS answers, SOCKS framing); the sockets are in `bin/ombra-tproxy.rs`.

use std::collections::HashMap;
use std::net::Ipv4Addr;

/// Placeholders come from 10.64.0.0/10 (about four million addresses). Nothing routes to it, the desktop firewall lets
/// nothing but the gateway out anyway, and it contains 10.66.0.0/16, where older status probes expect an onion name.
pub const POOL_BASE: u32 = 0x0a40_0000;
pub const POOL_BITS: u32 = 22;
pub const POOL_SIZE: u32 = 1 << POOL_BITS;
/// How long a client may cache an answer.
pub const ANSWER_TTL: u32 = 60;
/// When the table is full, a name that has not been asked for or connected to for this long is forgotten to make
/// room. Forgetting is safe on its own: its placeholder then stands for nothing, and a connection to it is refused.
pub const FORGET_IDLE_SECS: u64 = 300;
/// A forgotten placeholder is not given to ANOTHER name until this long after it was forgotten (and not before every
/// address in the pool has been used once): whoever still holds it gets a refusal in the meantime, never another host.
pub const REUSE_AFTER_SECS: u64 = 3600;
/// Names remembered at once. Past it, names idle for FORGET_IDLE_SECS are forgotten; if none is, a new name is
/// refused (the stub answers "server failure"). A flood costs new lookups while it lasts and a few minutes after; it
/// never moves a placeholder someone still holds.
pub const MAX_NAMES: usize = 100_000;
/// Forgotten placeholders remembered for later reuse; older ones beyond this are simply never reused.
const MAX_GRAVEYARD: usize = 1_000_000;
/// And the bytes those names may take, whatever their count.
pub const MAX_NAME_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_NAME_LEN: usize = 253;
pub const MAX_DNS_PACKET: usize = 512;

// ---- names ----

/// Suffixes that only mean something on a local network or are reserved: they are not sent to a Tor exit.
const LOCAL_ONLY_SUFFIXES: &[&str] = &[
    "local", "localdomain", "lan", "internal", "intranet", "home", "corp", "private", "invalid", "test", "arpa",
];

/// A hostname as it may be handed to Tor: lowercase, dot-separated labels of letters, digits, `-` and `_`, at least
/// two labels, no empty label, no label starting or ending with `-`, at most 253 bytes, not a local-only or reserved
/// suffix, not an address written as a name. The trailing dot is dropped.
pub fn normalize_name(raw: &str) -> Option<String> {
    let name = raw.strip_suffix('.').unwrap_or(raw).to_ascii_lowercase();
    if name.is_empty() || name.len() > MAX_NAME_LEN || !name.contains('.') {
        return None;
    }
    for label in name.split('.') {
        let b = label.as_bytes();
        if b.is_empty() || b.len() > 63 || b[0] == b'-' || b[b.len() - 1] == b'-' {
            return None;
        }
        if !b
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-' || *c == b'_')
        {
            return None;
        }
    }
    let last = name.rsplit('.').next().unwrap_or("");
    // an all-digit last label is an address in some spelling (1.2.3.4, 010.1.2.3), never a hostname
    if LOCAL_ONLY_SUFFIXES.contains(&last) || last.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some(name)
}

pub fn in_pool(addr: Ipv4Addr) -> bool {
    u32::from(addr) & !(POOL_SIZE - 1) == POOL_BASE
}

fn slot_addr(slot: u32) -> Ipv4Addr {
    Ipv4Addr::from(POOL_BASE | (slot & (POOL_SIZE - 1)))
}

fn addr_slot(addr: Ipv4Addr) -> Option<u32> {
    in_pool(addr).then(|| u32::from(addr) & (POOL_SIZE - 1))
}

/// Never handed out: the network and broadcast addresses, and 10.66.0.1, which the gateway's own resolver uses.
fn reserved_slot(slot: u32) -> bool {
    slot == 0 || slot == POOL_SIZE - 1 || slot_addr(slot) == Ipv4Addr::new(10, 66, 0, 1)
}

struct Entry {
    name: String,
    /// Seconds (caller's clock) of the last lookup of, or connection to, this name.
    last_used: u64,
}

/// Name ↔ placeholder address.
///
/// The rule that matters: a placeholder never changes meaning while anyone may still hold it. Addresses are picked at
/// random among those never used since this process started, so nobody can aim at one or guess the next. A name idle
/// for `FORGET_IDLE_SECS` may be forgotten when room is needed, which only ever turns its placeholder into a refusal.
/// An address is given to another name only once every address in the pool has been used AND it was forgotten at least
/// `REUSE_AFTER_SECS` ago. When the table is full of names still in use, a new name is refused.
pub struct NameTable {
    by_name: HashMap<String, u32>,
    by_slot: HashMap<u32, Entry>,
    /// One bit per pool address: handed out at least once since start.
    used: Vec<u64>,
    used_count: u32,
    /// Oldest first, with the `last_used` seen when queued; a refreshed entry is re-queued when it reaches the front.
    age: std::collections::VecDeque<(u32, u64)>,
    /// Forgotten placeholders with the time they were forgotten, oldest first.
    graveyard: std::collections::VecDeque<(u32, u64)>,
    name_bytes: usize,
    max_names: usize,
    rng: u64,
}

impl Default for NameTable {
    fn default() -> Self {
        NameTable::with_limits(MAX_NAMES)
    }
}

impl NameTable {
    pub fn with_limits(max_names: usize) -> NameTable {
        // seeded from the OS through the standard library's hasher keys: unpredictable to other processes
        use std::hash::{BuildHasher, Hasher};
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u64(0x6f_6d62_7261);
        NameTable {
            by_name: HashMap::new(),
            by_slot: HashMap::new(),
            used: vec![0u64; (POOL_SIZE as usize) / 64],
            used_count: 0,
            age: std::collections::VecDeque::new(),
            graveyard: std::collections::VecDeque::new(),
            name_bytes: 0,
            max_names,
            rng: h.finish() | 1,
        }
    }

    fn next_random(&mut self) -> u32 {
        // xorshift64*: only the choice among unused addresses rides on it
        let mut x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        (x.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 40) as u32 & (POOL_SIZE - 1)
    }

    fn is_used(&self, slot: u32) -> bool {
        self.used[(slot / 64) as usize] & (1u64 << (slot % 64)) != 0
    }

    fn remove(&mut self, slot: u32) {
        if let Some(e) = self.by_slot.remove(&slot) {
            self.name_bytes = self.name_bytes.saturating_sub(e.name.len());
            self.by_name.remove(&e.name);
        }
    }

    /// Forgets names unused for FORGET_IDLE_SECS, oldest first, until there is room for one more (`need` bytes).
    fn make_room(&mut self, now: u64, need: usize) {
        while self.by_slot.len() >= self.max_names || self.name_bytes + need > MAX_NAME_BYTES {
            let Some(&(slot, stamp)) = self.age.front() else { return };
            let live = self.by_slot.get(&slot).map(|e| e.last_used);
            match live {
                None => {
                    self.age.pop_front();
                }
                Some(last) if last != stamp => {
                    // used again since it was queued: back of the line with its new time
                    self.age.pop_front();
                    self.age.push_back((slot, last));
                }
                Some(last) if now.saturating_sub(last) >= FORGET_IDLE_SECS => {
                    self.age.pop_front();
                    self.remove(slot);
                    if self.graveyard.len() >= MAX_GRAVEYARD {
                        self.graveyard.pop_front();
                    }
                    self.graveyard.push_back((slot, now));
                }
                // the oldest name is still in use, so every name is
                Some(_) => return,
            }
        }
    }

    /// The placeholder for `name` (already normalized) at time `now` (seconds on any steady clock), allocating one if it
    /// has none. `None` = the table is full of names still in use: refuse, never evict.
    pub fn address_for(&mut self, name: &str, now: u64) -> Option<Ipv4Addr> {
        if let Some(&slot) = self.by_name.get(name) {
            if let Some(e) = self.by_slot.get_mut(&slot) {
                e.last_used = now;
            }
            return Some(slot_addr(slot));
        }
        self.make_room(now, name.len());
        if self.by_slot.len() >= self.max_names || self.name_bytes + name.len() > MAX_NAME_BYTES {
            return None;
        }
        let fresh_left = POOL_SIZE - 3 > self.used_count;
        let slot = if fresh_left {
            // a never-used address, at random; the pool is at most a few percent used unless it has been flooded for a
            // long time
            let mut pick = None;
            for _ in 0..64 {
                let s = self.next_random();
                if !reserved_slot(s) && !self.is_used(s) {
                    pick = Some(s);
                    break;
                }
            }
            pick.or_else(|| (0..POOL_SIZE).find(|&s| !reserved_slot(s) && !self.is_used(s)))?
        } else {
            // every address has been used once: only one forgotten long enough ago may stand for another name
            match self.graveyard.front() {
                Some(&(slot, freed)) if now.saturating_sub(freed) >= REUSE_AFTER_SECS => {
                    self.graveyard.pop_front();
                    slot
                }
                _ => return None,
            }
        };
        if !self.is_used(slot) {
            self.used[(slot / 64) as usize] |= 1u64 << (slot % 64);
            self.used_count += 1;
        }
        self.name_bytes += name.len();
        self.by_slot.insert(
            slot,
            Entry {
                name: name.to_string(),
                last_used: now,
            },
        );
        self.by_name.insert(name.to_string(), slot);
        self.age.push_back((slot, now));
        Some(slot_addr(slot))
    }

    /// The name a placeholder stands for, marking it used at `now` (a connection keeps it alive like a lookup does).
    pub fn name_for(&mut self, addr: Ipv4Addr, now: u64) -> Option<String> {
        let e = self.by_slot.get_mut(&addr_slot(addr)?)?;
        e.last_used = now;
        Some(e.name.clone())
    }

    pub fn len(&self) -> usize {
        self.by_slot.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_slot.is_empty()
    }
}

// ---- DNS ----

const TYPE_A: u16 = 1;
const CLASS_IN: u16 = 1;
const RCODE_NOERROR: u8 = 0;
const RCODE_FORMERR: u8 = 1;
const RCODE_SERVFAIL: u8 = 2;
const RCODE_NXDOMAIN: u8 = 3;
const RCODE_NOTIMP: u8 = 4;

struct Question {
    /// Dotted, as sent (not yet normalized).
    name: String,
    qtype: u16,
    qclass: u16,
    /// Offset just past the question section.
    end: usize,
}

/// The first question of a query. `None` for anything that is not one plain, uncompressed question in a query packet.
fn parse_question(pkt: &[u8]) -> Option<Question> {
    if pkt.len() < 12 || pkt.len() > MAX_DNS_PACKET {
        return None;
    }
    let flags = u16::from_be_bytes([pkt[2], pkt[3]]);
    let qdcount = u16::from_be_bytes([pkt[4], pkt[5]]);
    // a query (QR clear), opcode 0, exactly one question
    if flags & 0x8000 != 0 || (flags >> 11) & 0xf != 0 || qdcount != 1 {
        return None;
    }
    let mut i = 12;
    let mut name = String::new();
    loop {
        let len = *pkt.get(i)? as usize;
        i += 1;
        if len == 0 {
            break;
        }
        // no compression pointers in a question, and no label over 63 bytes
        if len > 63 {
            return None;
        }
        let label = pkt.get(i..i + len)?;
        i += len;
        if !label.iter().all(|c| c.is_ascii_graphic() && *c != b'.') {
            return None;
        }
        if !name.is_empty() {
            name.push('.');
        }
        name.push_str(std::str::from_utf8(label).ok()?);
        if name.len() > MAX_NAME_LEN {
            return None;
        }
    }
    let rest = pkt.get(i..i + 4)?;
    Some(Question {
        name,
        qtype: u16::from_be_bytes([rest[0], rest[1]]),
        qclass: u16::from_be_bytes([rest[2], rest[3]]),
        end: i + 4,
    })
}

#[cfg(test)]
fn encode_name(name: &str, out: &mut Vec<u8>) {
    for label in name.split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
}

/// The answer to one DNS query at time `now`, or `None` to stay silent (not a query we understand at all).
///   A for a hostname      one A record with its placeholder ("server failure" when the table is full)
///   A for `localhost`     127.0.0.1
///   any other type        an empty answer (so a client asking AAAA first goes on to ask A)
///   a name that is not a hostname for Tor (one label, odd characters, an address, a local-only or reserved suffix,
///   every reverse-lookup name)   no such name
/// Reverse lookups are never answered: they would let any program list the names every other program resolved.
pub fn answer(pkt: &[u8], table: &mut NameTable, now: u64) -> Option<Vec<u8>> {
    if pkt.len() < 12 {
        return None;
    }
    let reply = |rcode: u8, question_end: usize, rdata: Option<(u16, Vec<u8>)>| -> Vec<u8> {
        let mut out = Vec::with_capacity(question_end + 32);
        out.extend_from_slice(&pkt[0..2]);
        // QR, RD as asked, RA; never AA, never truncated
        let rd = pkt[2] & 0x01;
        out.push(0x80 | rd);
        out.push(0x80 | rcode);
        out.extend_from_slice(&[0, 1]);
        out.extend_from_slice(&[0, u8::from(rdata.is_some())]);
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&pkt[12..question_end]);
        if let Some((rtype, data)) = rdata {
            // the owner name is a pointer to the question
            out.extend_from_slice(&[0xc0, 12]);
            out.extend_from_slice(&rtype.to_be_bytes());
            out.extend_from_slice(&CLASS_IN.to_be_bytes());
            out.extend_from_slice(&ANSWER_TTL.to_be_bytes());
            out.extend_from_slice(&(data.len() as u16).to_be_bytes());
            out.extend_from_slice(&data);
        }
        out
    };
    let Some(q) = parse_question(pkt) else {
        // a response, or more than one question: silence. Anything else that has a header gets a format error.
        let flags = u16::from_be_bytes([pkt[2], pkt[3]]);
        if flags & 0x8000 != 0 || pkt.len() > MAX_DNS_PACKET {
            return None;
        }
        let mut out = pkt[0..2].to_vec();
        out.extend_from_slice(&[0x80, 0x80 | RCODE_FORMERR, 0, 0, 0, 0, 0, 0, 0, 0]);
        return Some(out);
    };
    if q.qclass != CLASS_IN {
        return Some(reply(RCODE_NOTIMP, q.end, None));
    }
    if q.name.eq_ignore_ascii_case("localhost") || q.name.to_ascii_lowercase().ends_with(".localhost") {
        return Some(match q.qtype {
            TYPE_A => reply(RCODE_NOERROR, q.end, Some((TYPE_A, vec![127, 0, 0, 1]))),
            _ => reply(RCODE_NOERROR, q.end, None),
        });
    }
    let Some(name) = normalize_name(&q.name) else {
        return Some(reply(RCODE_NXDOMAIN, q.end, None));
    };
    Some(match q.qtype {
        TYPE_A => match table.address_for(&name, now) {
            Some(addr) => reply(RCODE_NOERROR, q.end, Some((TYPE_A, addr.octets().to_vec()))),
            None => reply(RCODE_SERVFAIL, q.end, None),
        },
        _ => reply(RCODE_NOERROR, q.end, None),
    })
}

// ---- SOCKS5 towards the gateway ----

/// Where a redirected connection really wants to go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Name(String),
    Addr(Ipv4Addr),
}

/// A connection the firewall redirected here was made to `original`. A placeholder means the name it stands for (or
/// nothing, if it stands for none: refused, never guessed); any other address is passed on as it is and Tor decides.
pub fn target_for(original: Ipv4Addr, table: &mut NameTable, now: u64) -> Option<Target> {
    if in_pool(original) {
        table.name_for(original, now).map(Target::Name)
    } else {
        Some(Target::Addr(original))
    }
}

/// Greeting: version 5, one method, "no authentication".
pub const SOCKS_GREETING: [u8; 3] = [5, 1, 0];
/// The only acceptable answer to it.
pub const SOCKS_GREETING_OK: [u8; 2] = [5, 0];

/// `CONNECT target:port`. A name goes as a name: Tor resolves it at the exit, and an onion name stays an onion name.
pub fn socks_connect(target: &Target, port: u16) -> Vec<u8> {
    let mut out = vec![5, 1, 0];
    match target {
        Target::Name(name) => {
            out.push(3);
            out.push(name.len() as u8);
            out.extend_from_slice(name.as_bytes());
        }
        Target::Addr(addr) => {
            out.push(1);
            out.extend_from_slice(&addr.octets());
        }
    }
    out.extend_from_slice(&port.to_be_bytes());
    out
}

/// Reads the first four bytes of a SOCKS5 reply: `Ok(n)` = success, with `n` more bytes of bound address to discard;
/// `Err(code)` = the proxy refused (its reply code, or 0xff for a reply that is not SOCKS5).
pub fn socks_reply_head(head: [u8; 4]) -> Result<usize, u8> {
    if head[0] != 5 {
        return Err(0xff);
    }
    if head[1] != 0 {
        return Err(head[1]);
    }
    match head[3] {
        1 => Ok(4 + 2),
        4 => Ok(16 + 2),
        // a domain: one length byte follows, which the caller reads first
        3 => Ok(0),
        _ => Err(0xff),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(name: &str, qtype: u16) -> Vec<u8> {
        let mut p = vec![0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        encode_name(name, &mut p);
        p.extend_from_slice(&qtype.to_be_bytes());
        p.extend_from_slice(&CLASS_IN.to_be_bytes());
        p
    }

    fn rcode(reply: &[u8]) -> u8 {
        reply[3] & 0x0f
    }

    fn ancount(reply: &[u8]) -> u16 {
        u16::from_be_bytes([reply[6], reply[7]])
    }

    fn a_record(reply: &[u8]) -> Ipv4Addr {
        let n = reply.len();
        Ipv4Addr::new(reply[n - 4], reply[n - 3], reply[n - 2], reply[n - 1])
    }

    #[test]
    fn names_are_normalized_or_refused() {
        assert_eq!(normalize_name("Example.COM."), Some("example.com".into()));
        assert_eq!(normalize_name("a-b.c_d.example"), Some("a-b.c_d.example".into()));
        let onion = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion";
        assert_eq!(normalize_name(onion), Some(onion.into()));
        for bad in [
            "", ".", "localhost", "a..b", ".a.b", "-a.example", "a-.example", "a b.example", "a/b.example",
            "exa\u{e9}mple.com", "1.2.3.4", "010.055.010.001", "host.1", "a.b\0", "a.b\r\n", "a.b;c",
        ] {
            assert_eq!(normalize_name(bad), None, "{bad:?}");
        }
        assert_eq!(normalize_name(&format!("{}.com", "a".repeat(64))), None);
        assert_eq!(normalize_name(&format!("{}.com", "a.".repeat(130))), None);
    }

    #[test]
    fn local_only_and_reserved_names_never_reach_tor() {
        for bad in [
            "printer.local", "nas.lan", "host.corp.internal", "x.home.arpa", "box.localdomain", "a.invalid", "a.test",
            "wiki.corp", "router.home", "4.0.66.10.in-addr.arpa", "1.0.0.0.ip6.arpa", "PRINTER.LOCAL.",
        ] {
            assert_eq!(normalize_name(bad), None, "{bad:?}");
        }
        // a public name that merely contains such a word is fine
        assert!(normalize_name("local.example.com").is_some());
        assert!(normalize_name("test.example.org").is_some());
    }

    #[test]
    fn a_name_keeps_its_placeholder_and_the_placeholder_names_it() {
        let mut t = NameTable::default();
        let a = t.address_for("example.com", 0).unwrap();
        assert!(in_pool(a));
        assert_eq!(t.address_for("example.com", 5), Some(a));
        let b = t.address_for("example.org", 5).unwrap();
        assert_ne!(a, b);
        assert_eq!(t.name_for(a, 6).as_deref(), Some("example.com"));
        assert_eq!(t.name_for(b, 6).as_deref(), Some("example.org"));
        assert_eq!(t.name_for(Ipv4Addr::new(93, 184, 216, 34), 6), None);
        assert!(in_pool(Ipv4Addr::new(10, 64, 0, 0)) && in_pool(Ipv4Addr::new(10, 127, 255, 255)));
        assert!(!in_pool(Ipv4Addr::new(10, 63, 255, 255)) && !in_pool(Ipv4Addr::new(10, 128, 0, 0)));
        assert!(!in_pool(Ipv4Addr::new(10, 55, 10, 1)), "the gateway is not a placeholder");
    }

    #[test]
    fn placeholders_are_not_sequential_and_skip_the_reserved_addresses() {
        let mut t = NameTable::default();
        let mut addrs: Vec<u32> = (0..2000)
            .map(|i| u32::from(t.address_for(&format!("n{i}.example"), 0).unwrap()))
            .collect();
        // never the gateway resolver's own placeholder, nor the ends of the pool
        for a in &addrs {
            assert_ne!(Ipv4Addr::from(*a), Ipv4Addr::new(10, 66, 0, 1));
            assert!(*a != POOL_BASE && *a != POOL_BASE + POOL_SIZE - 1);
        }
        // spread over the pool: neighbours in allocation order are almost never neighbours in address
        let adjacent = addrs.windows(2).filter(|w| w[0].abs_diff(w[1]) == 1).count();
        assert!(adjacent < 5, "{adjacent} adjacent allocations");
        addrs.sort_unstable();
        addrs.dedup();
        assert_eq!(addrs.len(), 2000, "every name has its own address");
        // and two tables do not hand out the same sequence
        let mut u = NameTable::default();
        let first: Vec<_> = (0..8).map(|i| t.address_for(&format!("x{i}.example"), 0)).collect();
        let other: Vec<_> = (0..8).map(|i| u.address_for(&format!("x{i}.example"), 0)).collect();
        assert_ne!(first, other);
    }

    #[test]
    fn a_flood_is_refused_and_never_moves_a_placeholder_someone_holds() {
        let mut t = NameTable::with_limits(50);
        let victim = t.address_for("bank.example", 0).unwrap();
        for i in 0..49 {
            assert!(t.address_for(&format!("f{i}.example"), 0).is_some());
        }
        // full of names just used: every further name is refused, however many are tried
        for i in 0..100_000 {
            assert_eq!(t.address_for(&format!("flood{i}.example"), 10), None);
        }
        assert_eq!(t.len(), 50);
        assert_eq!(t.name_for(victim, 10).as_deref(), Some("bank.example"));
        assert_eq!(t.address_for("bank.example", 20), Some(victim));
    }

    #[test]
    fn a_long_flood_only_pushes_out_idle_names_and_a_used_one_never_moves() {
        let mut t = NameTable::with_limits(50);
        let victim = t.address_for("bank.example", 0).unwrap();
        // a flood that goes on for an hour, 20 new names a second; the victim uses its name once a minute
        let mut seen = std::collections::HashSet::new();
        for sec in 0..3600u64 {
            if sec % 60 == 0 {
                assert_eq!(t.name_for(victim, sec).as_deref(), Some("bank.example"), "at {sec}s");
            }
            for k in 0..20 {
                if let Some(a) = t.address_for(&format!("flood{sec}-{k}.example"), sec) {
                    assert_ne!(a, victim, "the victim's address was handed to a flood name");
                    assert!(seen.insert(a), "an address was handed out twice within the hour");
                }
            }
            assert!(t.len() <= 50);
        }
        assert_eq!(t.address_for("bank.example", 3600), Some(victim));
    }

    #[test]
    fn an_idle_name_is_forgotten_for_room_and_its_address_then_leads_nowhere() {
        let mut t = NameTable::with_limits(3);
        let a = t.address_for("a.example", 0).unwrap();
        let b = t.address_for("b.example", 0).unwrap();
        let c = t.address_for("c.example", 0).unwrap();
        // b is used again late; a and c go idle
        assert_eq!(t.name_for(b, FORGET_IDLE_SECS - 1).as_deref(), Some("b.example"));
        // nothing idle long enough yet: still full
        assert_eq!(t.address_for("d.example", FORGET_IDLE_SECS - 1), None);
        // then the idle ones make room, one at a time; b stays
        let d = t.address_for("d.example", FORGET_IDLE_SECS + 1).unwrap();
        assert_eq!(t.name_for(b, FORGET_IDLE_SECS + 1).as_deref(), Some("b.example"));
        assert_eq!(t.name_for(a, FORGET_IDLE_SECS + 2), None, "a stale holder is refused, not sent elsewhere");
        assert_eq!(t.name_for(c, FORGET_IDLE_SECS + 2).as_deref(), Some("c.example"), "only as many as needed are forgotten");
        assert!(d != a && d != b && d != c, "the new name got an address never used before");
        // a forgotten name that is asked for again gets a NEW address; its old one is not revived for anyone
        let a2 = t.address_for("a.example", FORGET_IDLE_SECS * 3).unwrap();
        assert_ne!(a2, a);
    }

    #[test]
    fn the_byte_budget_bounds_memory_whatever_the_name_count() {
        let mut t = NameTable::default();
        let long = |i: usize| format!("{}.{:06}.example", "a".repeat(63), i);
        let mut n = 0usize;
        while t.address_for(&long(n), 0).is_some() {
            n += 1;
            assert!(n <= MAX_NAMES, "the count cap must hold too");
        }
        assert!(t.name_bytes <= MAX_NAME_BYTES);
        assert!(n >= 1000);
    }

    #[test]
    fn a_query_gets_one_a_record_in_the_pool() {
        let mut t = NameTable::default();
        let r = answer(&query("Example.com", TYPE_A), &mut t, 0).unwrap();
        assert_eq!(&r[0..2], &[0xab, 0xcd]);
        assert_eq!(r[2] & 0x80, 0x80, "a response");
        assert_eq!(rcode(&r), RCODE_NOERROR);
        assert_eq!(ancount(&r), 1);
        let addr = a_record(&r);
        assert!(in_pool(addr));
        assert_eq!(t.name_for(addr, 0).as_deref(), Some("example.com"));
        assert_eq!(a_record(&answer(&query("example.com", TYPE_A), &mut t, 1).unwrap()), addr);
        // an onion name is a name like any other here
        let onion = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion";
        assert!(in_pool(a_record(&answer(&query(onion, TYPE_A), &mut t, 1).unwrap())));
    }

    #[test]
    fn a_full_table_answers_server_failure() {
        let mut t = NameTable::with_limits(1);
        assert_eq!(rcode(&answer(&query("a.example", TYPE_A), &mut t, 0).unwrap()), RCODE_NOERROR);
        let r = answer(&query("b.example", TYPE_A), &mut t, 0).unwrap();
        assert_eq!(rcode(&r), RCODE_SERVFAIL);
        assert_eq!(ancount(&r), 0);
    }

    #[test]
    fn other_types_get_an_empty_answer_and_allocate_nothing() {
        let mut t = NameTable::default();
        for qtype in [28u16, 15, 16, 33, 255, 65] {
            let r = answer(&query("example.com", qtype), &mut t, 0).unwrap();
            assert_eq!(rcode(&r), RCODE_NOERROR, "type {qtype}");
            assert_eq!(ancount(&r), 0, "type {qtype}");
        }
        assert!(t.is_empty());
    }

    #[test]
    fn reverse_lookups_reveal_nothing() {
        let mut t = NameTable::default();
        let addr = t.address_for("secret-site.example", 0).unwrap();
        let o = addr.octets();
        let rev = format!("{}.{}.{}.{}.in-addr.arpa", o[3], o[2], o[1], o[0]);
        for qtype in [12u16, 1, 255] {
            let r = answer(&query(&rev, qtype), &mut t, 0).unwrap();
            assert_eq!(rcode(&r), RCODE_NXDOMAIN, "type {qtype}");
            assert_eq!(ancount(&r), 0);
            assert!(!r.windows(6).any(|w| w == b"secret"));
        }
        assert_eq!(t.len(), 1);
    }

    #[test]
    fn things_that_are_not_hostnames_do_not_exist() {
        let mut t = NameTable::default();
        for name in ["intranet", "1.2.3.4", "a b.example", "bad;name.example", "printer.local"] {
            let mut p = vec![0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
            // hand-encoded so odd bytes survive
            for label in name.split('.') {
                p.push(label.len() as u8);
                p.extend_from_slice(label.as_bytes());
            }
            p.extend_from_slice(&[0, 0, 1, 0, 1]);
            match answer(&p, &mut t, 0) {
                Some(r) => assert_eq!(rcode(&r), if name.contains(' ') { RCODE_FORMERR } else { RCODE_NXDOMAIN }, "{name}"),
                None => panic!("{name}: no reply"),
            }
        }
        assert!(t.is_empty());
        let r = answer(&query("localhost", TYPE_A), &mut t, 0).unwrap();
        assert_eq!(a_record(&r), Ipv4Addr::LOCALHOST);
        assert!(t.is_empty());
    }

    #[test]
    fn malformed_packets_never_panic_and_never_allocate() {
        let mut t = NameTable::default();
        let good = query("example.com", TYPE_A);
        // every truncation of a good query
        for n in 0..good.len() {
            let _ = answer(&good[..n], &mut t, 0);
        }
        assert!(t.is_empty());
        // a response is ignored, not answered (no reflection)
        let mut resp = good.clone();
        resp[2] |= 0x80;
        assert_eq!(answer(&resp, &mut t, 0), None);
        // two questions, a compression pointer in the question, an oversized packet
        let mut two = good.clone();
        two[5] = 2;
        assert_eq!(rcode(&answer(&two, &mut t, 0).unwrap()), RCODE_FORMERR);
        let ptr = vec![0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 0x0c, 0, 1, 0, 1];
        assert_eq!(rcode(&answer(&ptr, &mut t, 0).unwrap()), RCODE_FORMERR);
        let mut big = good.clone();
        big.resize(MAX_DNS_PACKET + 1, 0);
        assert_eq!(answer(&big, &mut t, 0), None);
        // arbitrary bytes
        let mut x: u32 = 0x1234_5678;
        for _ in 0..2000 {
            let mut p = vec![0u8; (x % 80) as usize];
            for b in p.iter_mut() {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                *b = (x >> 24) as u8;
            }
            if let Some(r) = answer(&p, &mut t, 0) {
                assert!(r.len() <= MAX_DNS_PACKET + 64);
            }
        }
    }

    #[test]
    fn a_redirected_connection_maps_back_to_its_name_or_passes_as_an_address() {
        let mut t = NameTable::default();
        let a = t.address_for("example.com", 0).unwrap();
        assert_eq!(target_for(a, &mut t, 1), Some(Target::Name("example.com".into())));
        // a placeholder nobody asked for: refuse, never guess
        let unused = (2..).map(slot_addr).find(|x| *x != a).unwrap();
        assert_eq!(target_for(unused, &mut t, 1), None);
        assert_eq!(target_for(Ipv4Addr::new(10, 66, 0, 1), &mut t, 1), None);
        let lit = Ipv4Addr::new(93, 184, 216, 34);
        assert_eq!(target_for(lit, &mut t, 1), Some(Target::Addr(lit)));
    }

    #[test]
    fn socks_requests_and_replies() {
        assert_eq!(
            socks_connect(&Target::Name("example.com".into()), 22),
            [&[5u8, 1, 0, 3, 11][..], b"example.com", &[0, 22]].concat()
        );
        assert_eq!(
            socks_connect(&Target::Addr(Ipv4Addr::new(1, 2, 3, 4)), 443),
            vec![5, 1, 0, 1, 1, 2, 3, 4, 1, 187]
        );
        assert_eq!(socks_reply_head([5, 0, 0, 1]), Ok(6));
        assert_eq!(socks_reply_head([5, 0, 0, 4]), Ok(18));
        assert_eq!(socks_reply_head([5, 0, 0, 3]), Ok(0));
        assert_eq!(socks_reply_head([5, 4, 0, 1]), Err(4));
        assert_eq!(socks_reply_head([4, 0, 0, 1]), Err(0xff));
        assert_eq!(socks_reply_head([5, 0, 0, 9]), Err(0xff));
    }
}
