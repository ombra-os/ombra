//! Read-only Tor control dialect: status GETINFOs and events only, never SIGNAL/SETCONF/ADD_ONION.

use std::io::BufRead;

/// Shared auth value, public by design; the command whitelist is the actual gate.
pub const CLIENT_COOKIE_HEX: &str =
    "618709bfbef278946629b2da38c1e201c37bedfbd0ad6b2dbdc4dc6e53d60ae8";

/// GETINFO keywords the desktop may read; anything else is refused — answers must never carry exit-adjacent data.
pub const GETINFO_ALLOWED: &[&str] = &[
    "version",
    "onions/current",
    "config-file",
    "config-can-saveconf",
    "status/bootstrap-phase",
    "status/circuit-established",
    "status/enough-dir-info",
    "net/listeners/socks",
];

/// GETCONF names the desktop may read: OnionShare asks whether Tor is in single-hop (non-anonymous) mode.
pub const GETCONF_ALLOWED: &[&str] = &["hiddenservicesinglehopmode", "__owningcontrollerprocess"];

const FAKE_HSDIR: &str = "$0000000000000000000000000000000000000000~redacted";

fn is_service_id(id: &str) -> bool {
    id.len() == 56 && id.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

/// Filters what Tor sends down to the desktop, line by line: learns the ids of the onion services this connection created,
/// lets only their HS_DESC events through (relay identities replaced), and drops every event type that was not subscribed.
#[derive(Default)]
pub struct DownstreamFilter {
    owned: Vec<String>,
    partial: Vec<u8>,
}

impl DownstreamFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<u8> {
        self.partial.extend_from_slice(data);
        let mut out = Vec::new();
        while let Some(end) = self.partial.iter().position(|&b| b == b'\n') {
            let raw: Vec<u8> = self.partial.drain(..=end).collect();
            let line = String::from_utf8_lossy(&raw);
            if let Some(kept) = self.line(line.trim_end_matches(['\r', '\n'])) {
                out.extend_from_slice(kept.as_bytes());
                out.extend_from_slice(b"\r\n");
            }
        }
        if self.partial.len() > 65_536 {
            self.partial.clear();
        }
        out
    }

    fn line(&mut self, line: &str) -> Option<String> {
        if let Some(id) = line
            .strip_prefix("250-ServiceID=")
            .or_else(|| line.strip_prefix("250 ServiceID="))
        {
            if is_service_id(id) && self.owned.len() < 64 && !self.owned.iter().any(|o| o == id) {
                self.owned.push(id.to_string());
            }
            return Some(line.to_string());
        }
        let Some(rest) = line.strip_prefix("650") else {
            return Some(line.to_string());
        };
        let rest = rest.trim_start_matches(['-', '+', ' ']);
        let mut words = rest.split_whitespace();
        match words.next() {
            Some("HS_DESC") => {
                let action = words.next()?;
                let addr = words.next()?;
                if !self.owned.iter().any(|o| o == addr)
                    || !action.bytes().all(|b| b.is_ascii_uppercase() || b == b'_')
                {
                    return None;
                }
                let auth = words
                    .next()
                    .filter(|a| a.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
                    .unwrap_or("UNKNOWN");
                let reason = words
                    .find_map(|w| w.strip_prefix("REASON="))
                    .filter(|r| r.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'));
                let dir = if action == "CREATED" {
                    "UNKNOWN"
                } else {
                    FAKE_HSDIR
                };
                let mut out = format!("650 HS_DESC {action} {addr} {auth} {dir}");
                if let Some(r) = reason {
                    out.push_str(&format!(" REASON={r}"));
                }
                Some(out)
            }
            Some("STATUS_SERVER" | "STATUS_CLIENT" | "STATUS_GENERAL" | "CONF_CHANGED" | "BW") => {
                Some(line.to_string())
            }
            _ => None,
        }
    }
}

/// A SETEVENTS line made only of known events: the stubbed ones are dropped (the client is told they are set), the rest are forwarded.
/// `Some(None)` = answer 250 OK locally; `Some(Some(line))` = send this line upstream; `None` = refuse.
pub fn setevents_plan(rest: &str) -> Option<Option<String>> {
    let events: Vec<&str> = rest.split_whitespace().collect();
    if events.is_empty()
        || !events
            .iter()
            .all(|e| EVENTS_ALLOWED.contains(e) || EVENTS_STUBBED.contains(e))
    {
        return None;
    }
    let kept: Vec<&str> = events
        .into_iter()
        .filter(|e| EVENTS_ALLOWED.contains(e))
        .collect();
    Some(if kept.is_empty() {
        None
    } else {
        Some(format!("SETEVENTS {}", kept.join(" ")))
    })
}

/// What may be written to the log about a refused line: the verb, plus the keyword for the read-only verbs.
/// Arguments (addresses, keys, ports) never reach the log.
pub fn loggable(line: &str) -> String {
    let mut words = line.split_whitespace();
    let verb: String = words
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .take(24)
        .collect();
    match (verb.as_str(), words.next()) {
        ("SETEVENTS", first) => {
            let names: Vec<String> = first
                .into_iter()
                .chain(words)
                .map(|w| {
                    w.chars()
                        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
                        .take(24)
                        .collect()
                })
                .take(8)
                .collect();
            format!("{verb} {}", names.join(" "))
        }
        ("GETINFO" | "GETCONF", Some(kw)) => {
            let kw: String = kw
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_'))
                .take(40)
                .collect();
            format!("{verb} {kw}")
        }
        _ => verb,
    }
}

/// Answer to PROTOCOLINFO, given by the filter itself: the real reply names a cookie file the desktop cannot read, which makes
/// stem-based clients (OnionShare) give up. The filter authenticates clients by its command whitelist, so NULL is offered.
pub const PROTOCOLINFO_REPLY: &str =
    "250-PROTOCOLINFO 1\r\n250-AUTH METHODS=NULL\r\n250-VERSION Tor=\"0.4.9.0\"\r\n250 OK\r\n";

/// First and last TCP port the desktop may publish through an onion service (OnionShare's range).
pub const ONION_PORT_MIN: u16 = 17600;
pub const ONION_PORT_MAX: u16 = 17659;

/// Most ADD_ONION commands one control connection may issue: services die with the connection, so this bounds a runaway client.
pub const MAX_ADD_ONION: u32 = 8;

/// Events the desktop may subscribe to: state telemetry only; anything carrying relay addresses or destinations is refused.
pub const EVENTS_ALLOWED: &[&str] = &[
    "HS_DESC",
    "STATUS_CLIENT",
    "STATUS_GENERAL",
    "STATUS_SERVER",
    "CONF_CHANGED",
    "BW",
];

/// Events Tor Browser's control client asks for at startup; answered locally, never subscribed upstream, so no circuit or stream data can flow.
pub const EVENTS_STUBBED: &[&str] = &["CIRC", "STREAM", "SIGNAL"];

/// Local answer for commands the browser needs to see succeed but whose real data must never reach the desktop.
pub fn stub_reply(line: &str, authed: bool) -> Option<&'static str> {
    if !authed {
        return None;
    }
    let (verb, rest) = verb_of(line);
    match verb {
        "SETEVENTS"
            if !rest.is_empty()
                && rest
                    .split_whitespace()
                    .all(|ev| EVENTS_STUBBED.contains(&ev)) =>
        {
            Some("250 OK\r\n")
        }
        "GETINFO" if rest == "circuit-status" => Some("250-circuit-status=\r\n250 OK\r\n"),
        _ => None,
    }
}

fn is_b64_key(blob: &str) -> bool {
    (20..=100).contains(&blob.len())
        && blob
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
}

fn is_client_auth_v3(key: &str) -> bool {
    key.len() == 52 && key.bytes().all(|b| matches!(b, b'A'..=b'Z' | b'2'..=b'7'))
}

/// The one ADD_ONION shape OnionShare needs, rewritten so Tor connects back to the asking desktop on a fixed port range.
/// Anything else (detached services, non-anonymous mode, other ports or targets, RSA keys) returns None.
pub fn add_onion_rewrite(rest: &str, client: std::net::IpAddr) -> Option<String> {
    let mut parts = rest.split_whitespace();
    let key = parts.next()?;
    let key_ok = key == "NEW:ED25519-V3" || key.strip_prefix("ED25519-V3:").is_some_and(is_b64_key);
    if !key_ok {
        return None;
    }
    let mut flags: Option<String> = None;
    let mut port: Option<String> = None;
    let mut auths: Vec<&str> = Vec::new();
    for token in parts {
        if let Some(list) = token.strip_prefix("Flags=") {
            if flags.is_some() || list.is_empty() {
                return None;
            }
            let mut seen: Vec<&str> = Vec::new();
            for f in list.split(',') {
                if !matches!(f, "V3Auth" | "DiscardPK" | "MaxStreamsCloseCircuit")
                    || seen.contains(&f)
                {
                    return None;
                }
                seen.push(f);
            }
            flags = Some(list.to_string());
        } else if let Some(spec) = token.strip_prefix("Port=") {
            if port.is_some() {
                return None;
            }
            let (virt, target) = spec.split_once(',')?;
            let target_port: u16 = target.parse().ok()?;
            let ok = match virt {
                "80" => (ONION_PORT_MIN..=ONION_PORT_MAX).contains(&target_port),
                "1" => target_port == 1,
                _ => false,
            };
            if !ok || target.len() > 5 || target.starts_with('0') {
                return None;
            }
            port = Some(format!("Port={virt},{client}:{target_port}"));
        } else if let Some(key) = token.strip_prefix("ClientAuthV3=") {
            if !is_client_auth_v3(key) || auths.len() >= 8 {
                return None;
            }
            auths.push(key);
        } else {
            return None;
        }
    }
    let mut out = format!("ADD_ONION {key}");
    if let Some(f) = flags {
        out.push_str(&format!(" Flags={f}"));
    }
    out.push(' ');
    out.push_str(&port?);
    for a in auths {
        out.push_str(&format!(" ClientAuthV3={a}"));
    }
    Some(out)
}

/// A pre-auth client holds a thread and an upstream slot; this long is all it gets.
pub const AUTH_TIMEOUT_SECS: u64 = 10;

/// Longest client line buffered before refusing and closing.
pub const MAX_LINE_BYTES: usize = 1024;

/// Concurrent connections admitted before refusing the rest.
pub const MAX_CONNECTIONS: usize = 16;

/// Strip the trailing CRLF/LF a control-port line arrives with.
pub fn chomp(line: &str) -> &str {
    line.strip_suffix('\n')
        .map_or(line, |l| l.strip_suffix('\r').unwrap_or(l))
}

fn verb_of(line: &str) -> (&str, &str) {
    match line.split_once(' ') {
        Some((v, rest)) => (v, rest.trim()),
        None => (line.trim(), ""),
    }
}

/// `authed` gates the pre-auth surface: only PROTOCOLINFO, AUTHENTICATE and QUIT exist before AUTHENTICATE succeeds.
pub fn command_allowed(line: &str, authed: bool) -> bool {
    let (verb, rest) = verb_of(line);
    match verb {
        "QUIT" | "PROTOCOLINFO" => true,
        "AUTHENTICATE" => true,
        "GETINFO" => authed && getinfo_allowed(rest),
        "GETCONF" => authed && getconf_allowed(rest),
        "DEL_ONION" => authed && del_onion_allowed(rest),
        "SETEVENTS" => authed && setevents_allowed(rest),
        _ => false,
    }
}

/// One unknown keyword refuses the whole line — partial answers would leak.
pub fn getinfo_allowed(rest: &str) -> bool {
    !rest.is_empty()
        && rest
            .split_whitespace()
            .all(|kw| GETINFO_ALLOWED.contains(&kw))
}

pub fn getconf_allowed(rest: &str) -> bool {
    !rest.is_empty()
        && rest
            .split_whitespace()
            .all(|kw| GETCONF_ALLOWED.iter().any(|a| a.eq_ignore_ascii_case(kw)))
}

/// A v3 onion service id: 56 base32 characters, nothing else.
pub fn del_onion_allowed(rest: &str) -> bool {
    rest.len() == 56 && rest.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

/// Every event name must be whitelisted; bare `SETEVENTS` (all events) is refused.
pub fn setevents_allowed(rest: &str) -> bool {
    !rest.is_empty()
        && rest
            .split_whitespace()
            .all(|ev| EVENTS_ALLOWED.contains(&ev))
}

/// Accepts the shared auth value (hex, any case) or an empty token (NULL auth); the whitelist stays the gate.
pub fn client_auth_ok(line: &str) -> bool {
    let (_, rest) = verb_of(line);
    let token = rest.trim_matches('"');
    token.is_empty() || token.eq_ignore_ascii_case(CLIENT_COOKIE_HEX)
}

/// Whether one more connection fits under a cap.
pub fn admit_connection(active: usize, cap: usize) -> bool {
    active < cap
}

/// Why a capped line read ended.
#[derive(Debug, PartialEq, Eq)]
pub enum LineReadError {
    TooLong,
    Eof,
    Io,
}

/// Unlike `BufRead::read_line`, a newline-less stream is cut off at `cap` instead of growing forever.
pub fn read_line_capped<R: BufRead + ?Sized>(
    reader: &mut R,
    buf: &mut Vec<u8>,
    cap: usize,
) -> Result<usize, LineReadError> {
    use std::io::ErrorKind;
    buf.clear();
    loop {
        let (chunk_len, line_len) = {
            let available = match reader.fill_buf() {
                Ok(a) => a,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return Err(LineReadError::Io),
            };
            if available.is_empty() {
                return if buf.is_empty() {
                    Err(LineReadError::Eof)
                } else {
                    Ok(buf.len())
                };
            }
            match available.iter().position(|&b| b == b'\n') {
                Some(i) => {
                    if buf.len() + i + 1 > cap {
                        return Err(LineReadError::TooLong);
                    }
                    buf.extend_from_slice(&available[..=i]);
                    (i + 1, Some(buf.len()))
                }
                None => {
                    if buf.len() + available.len() > cap {
                        return Err(LineReadError::TooLong);
                    }
                    buf.extend_from_slice(available);
                    (available.len(), None)
                }
            }
        };
        reader.consume(chunk_len);
        if let Some(len) = line_len {
            return Ok(len);
        }
    }
}

/// Reason strings for refusal lines; the client sees these verbatim.
pub fn refusal(line: &str, authed: bool) -> &'static str {
    let (verb, _) = verb_of(line);
    if !authed && !matches!(verb, "AUTHENTICATE" | "PROTOCOLINFO" | "QUIT") {
        "510 ombra-filter: authenticate first"
    } else {
        "510 ombra-filter: command not in the read-only dialect"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chomp_strips_lf_and_crlf() {
        assert_eq!(chomp("QUIT\n"), "QUIT");
        assert_eq!(chomp("QUIT\r\n"), "QUIT");
        assert_eq!(chomp("QUIT"), "QUIT");
    }

    #[test]
    fn pre_auth_only_the_handshake_verbs() {
        assert!(command_allowed("PROTOCOLINFO 1", false));
        assert!(command_allowed("AUTHENTICATE deadbeef", false));
        assert!(command_allowed("QUIT", false));
        assert!(!command_allowed("GETINFO version", false));
        assert!(!command_allowed("SIGNAL HALT", false));
    }

    #[test]
    fn post_auth_read_only_dialect() {
        assert!(command_allowed("GETINFO version", true));
        assert!(command_allowed(
            "GETINFO status/bootstrap-phase status/circuit-established",
            true
        ));
        assert!(command_allowed("SETEVENTS STATUS_CLIENT BW", true));
        assert!(command_allowed("QUIT", true));
    }

    #[test]
    fn dangerous_verbs_never_pass() {
        for line in [
            "SIGNAL HALT",
            "SETCONF SocksPort=9050",
            "RESETCONF SocksPort",
            "SAVECONF",
            "ADD_ONION",
            "DEL_ONION",
            "ATTACHSTREAM 1 2",
            "CLOSECIRCUIT 1",
            "HSFETCH x",
            "RESOLVE example.com",
            "MAPADDRESS a=b",
            "+POSTDESCRIPTOR",
        ] {
            assert!(!command_allowed(line, true), "{line} must be refused");
        }
    }

    #[test]
    fn stubs_answer_locally_and_only_for_known_lines() {
        assert_eq!(
            stub_reply("SETEVENTS CIRC STREAM", true),
            Some("250 OK\r\n")
        );
        assert_eq!(
            stub_reply("GETINFO circuit-status", true),
            Some("250-circuit-status=\r\n250 OK\r\n")
        );
        assert_eq!(stub_reply("SETEVENTS CIRC STREAM", false), None);
        assert_eq!(stub_reply("SETEVENTS CIRC ORCONN", true), None);
        assert_eq!(stub_reply("SETEVENTS", true), None);
        assert_eq!(stub_reply("GETINFO circuit-status ns/all", true), None);
        assert_eq!(stub_reply("GETINFO stream-status", true), None);
    }

    fn ip() -> std::net::IpAddr {
        "10.55.10.100".parse().unwrap()
    }

    const AUTH: &str = "PCY5OWYK7U5UBTPFC2M73DI7ULGDQLG3MKI5SGZ6Z6YGFJYFGEFQ";

    #[test]
    fn onionshare_services_are_rewritten_to_point_back_at_the_desktop() {
        assert_eq!(AUTH.len(), 52);
        assert_eq!(
            add_onion_rewrite(&format!("NEW:ED25519-V3 Flags=V3Auth Port=80,17646 ClientAuthV3={AUTH}"), ip()).as_deref(),
            Some(format!("ADD_ONION NEW:ED25519-V3 Flags=V3Auth Port=80,10.55.10.100:17646 ClientAuthV3={AUTH}").as_str())
        );
        assert_eq!(
            add_onion_rewrite("NEW:ED25519-V3 Port=80,17600", ip()).as_deref(),
            Some("ADD_ONION NEW:ED25519-V3 Port=80,10.55.10.100:17600")
        );
        assert_eq!(
            add_onion_rewrite("NEW:ED25519-V3 Flags=V3Auth Port=1,1", ip()).as_deref(),
            Some("ADD_ONION NEW:ED25519-V3 Flags=V3Auth Port=1,10.55.10.100:1")
        );
        assert_eq!(
            add_onion_rewrite("ED25519-V3:aOhCmBUtE2e/GFLuIOvZnNP8v/VdPgECoZ9YP19IJltc/A6xj+2np8FG0ithqIyf6gJBgE9tZftR02s6mmg0mA== Port=80,17659", ip()).as_deref(),
            Some("ADD_ONION ED25519-V3:aOhCmBUtE2e/GFLuIOvZnNP8v/VdPgECoZ9YP19IJltc/A6xj+2np8FG0ithqIyf6gJBgE9tZftR02s6mmg0mA== Port=80,10.55.10.100:17659")
        );
    }

    #[test]
    fn everything_else_about_onion_services_is_refused() {
        for rest in [
            "NEW:BEST Port=80,17600",
            "NEW:RSA1024 Port=80,17600",
            "RSA1024:abcdefghijklmnopqrst Port=80,17600",
            "NEW:ED25519-V3 Flags=Detach Port=80,17600",
            "NEW:ED25519-V3 Flags=NonAnonymous Port=80,17600",
            "NEW:ED25519-V3 Flags=BasicAuth Port=80,17600",
            "NEW:ED25519-V3 Flags=V3Auth,V3Auth Port=80,17600",
            "NEW:ED25519-V3 Port=80,17599",
            "NEW:ED25519-V3 Port=80,17660",
            "NEW:ED25519-V3 Port=80,22",
            "NEW:ED25519-V3 Port=80,017600",
            "NEW:ED25519-V3 Port=443,17600",
            "NEW:ED25519-V3 Port=80,10.0.0.9:17600",
            "NEW:ED25519-V3 Port=80,127.0.0.1:17600",
            "NEW:ED25519-V3 Port=80",
            "NEW:ED25519-V3 Port=1,2",
            "NEW:ED25519-V3 Port=80,17600 Port=80,17601",
            "NEW:ED25519-V3",
            "NEW:ED25519-V3 Port=80,17600 ClientAuthV3=short",
            "NEW:ED25519-V3 Port=80,17600 Extra=1",
            "NEW:ED25519-V3 Port=80,17600\nSIGNAL HALT",
            "",
        ] {
            assert_eq!(
                add_onion_rewrite(rest, ip()),
                None,
                "{rest:?} must be refused"
            );
        }
    }

    #[test]
    fn hs_desc_events_reach_the_desktop_only_for_its_own_services_and_without_relay_identities() {
        let id = "a".repeat(55) + "b";
        let other = "c".repeat(56);
        let mut f = DownstreamFilter::new();
        let out = f.feed(format!("250-ServiceID={id}\r\n250 OK\r\n").as_bytes());
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("250-ServiceID={id}\r\n250 OK\r\n")
        );
        let out = f.feed(
            format!("650 HS_DESC UPLOADED {id} UNKNOWN $3655BA69BDB86299057FDE2FF1A788003BE1043D~whitehouse reuFJS HSDIR_INDEX=BF61\r\n").as_bytes(),
        );
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("650 HS_DESC UPLOADED {id} UNKNOWN $0000000000000000000000000000000000000000~redacted\r\n")
        );
        let out = f.feed(format!("650 HS_DESC CREATED {id} UNKNOWN UNKNOWN descid\r\n").as_bytes());
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("650 HS_DESC CREATED {id} UNKNOWN UNKNOWN\r\n")
        );
        let out = f.feed(
            format!("650 HS_DESC FAILED {id} UNKNOWN $AAAA~x desc REASON=UPLOAD_REJECTED\r\n")
                .as_bytes(),
        );
        assert!(String::from_utf8(out)
            .unwrap()
            .ends_with("REASON=UPLOAD_REJECTED\r\n"));
        assert!(f
            .feed(format!("650 HS_DESC REQUESTED {other} NO_AUTH $A~b\r\n").as_bytes())
            .is_empty());
        assert!(f.feed(b"650 CIRC 5 BUILT $AAAA~x\r\n").is_empty());
        assert!(f
            .feed(b"650 ADDRMAP example.com 1.2.3.4 NEVER\r\n")
            .is_empty());
        assert_eq!(f.feed(b"650 BW 1 2\r\n"), b"650 BW 1 2\r\n");
    }

    #[test]
    fn downstream_lines_split_across_reads_are_reassembled() {
        let mut f = DownstreamFilter::new();
        assert!(f.feed(b"250-version=0.4").is_empty());
        assert_eq!(
            f.feed(b".9.11\r\n250 OK\r\n"),
            b"250-version=0.4.9.11\r\n250 OK\r\n"
        );
        assert_eq!(f.feed(b"510 nope\n"), b"510 nope\r\n");
    }

    #[test]
    fn mixed_event_subscriptions_forward_only_the_allowed_events() {
        assert_eq!(
            setevents_plan("SIGNAL CONF_CHANGED STATUS_SERVER"),
            Some(Some("SETEVENTS CONF_CHANGED STATUS_SERVER".to_string()))
        );
        assert_eq!(setevents_plan("SIGNAL CIRC"), Some(None));
        assert_eq!(
            setevents_plan("SIGNAL HS_DESC"),
            Some(Some("SETEVENTS HS_DESC".to_string()))
        );
        assert_eq!(setevents_plan("BW"), Some(Some("SETEVENTS BW".to_string())));
        assert_eq!(setevents_plan("SIGNAL ORCONN"), None);
        assert_eq!(setevents_plan("ADDRMAP"), None);
        assert_eq!(setevents_plan(""), None);
    }

    #[test]
    fn the_log_line_for_a_refused_command_carries_no_arguments() {
        assert_eq!(
            loggable("GETINFO circuit-status extra"),
            "GETINFO circuit-status"
        );
        assert_eq!(loggable("SETCONF ControlPort=1234"), "SETCONF");
        assert_eq!(loggable("ADD_ONION NEW:ED25519-V3 Port=80,1"), "ADD_ONION");
        assert_eq!(loggable(""), "");
        assert_eq!(loggable("GETINFO a\u{7}b"), "GETINFO ab");
    }

    #[test]
    fn protocolinfo_offers_null_auth_and_is_well_formed() {
        assert!(PROTOCOLINFO_REPLY.starts_with("250-PROTOCOLINFO 1\r\n"));
        assert!(PROTOCOLINFO_REPLY.contains("AUTH METHODS=NULL"));
        assert!(!PROTOCOLINFO_REPLY.contains("COOKIE"));
        assert!(PROTOCOLINFO_REPLY.ends_with("250 OK\r\n"));
        assert!(client_auth_ok("AUTHENTICATE"));
    }

    #[test]
    fn del_onion_takes_only_a_v3_service_id_and_getconf_only_the_named_setting() {
        let id = "a".repeat(56);
        assert!(command_allowed(&format!("DEL_ONION {id}"), true));
        assert!(!command_allowed(&format!("DEL_ONION {id}"), false));
        assert!(!command_allowed("DEL_ONION short", true));
        assert!(!command_allowed(
            &format!("DEL_ONION {}A", "a".repeat(55)),
            true
        ));
        assert!(command_allowed("GETCONF HiddenServiceSingleHopMode", true));
        assert!(!command_allowed("GETCONF SocksPort", true));
        assert!(!command_allowed("GETCONF", true));
        assert!(command_allowed("GETINFO onions/current", true));
        assert!(!command_allowed("GETINFO onions/detached", true));
        assert_eq!(stub_reply("SETEVENTS HS_DESC", true), None);
        assert_eq!(
            stub_reply("SETEVENTS SIGNAL CIRC", true),
            Some("250 OK\r\n")
        );
    }

    #[test]
    fn getinfo_requires_only_known_keywords() {
        assert!(getinfo_allowed("version"));
        assert!(getinfo_allowed("version status/bootstrap-phase"));
        assert!(!getinfo_allowed("circuit-status"));
        assert!(!getinfo_allowed(
            "ns/id/0011aa22bb33cc44dd55ee66ff7700aa88bb99cc"
        ));
        assert!(!getinfo_allowed("ns/name/foo"));
        assert!(!getinfo_allowed("stream-status"));
        assert!(!getinfo_allowed("addr-mappings/all"));
        assert!(!getinfo_allowed("ip-to-country/1.2.3.4"));
        assert!(!getinfo_allowed("version addr-mappings/all"));
        assert!(!getinfo_allowed(""));
    }

    #[test]
    fn setevents_requires_only_known_events() {
        assert!(setevents_allowed("STATUS_CLIENT"));
        assert!(setevents_allowed("STATUS_CLIENT CONF_CHANGED BW"));
        assert!(!setevents_allowed(""));
        assert!(!setevents_allowed("DEBUG"));
        assert!(!setevents_allowed("STATUS_CLIENT EXTRAOCTANE"));
    }

    #[test]
    fn stream_and_clients_seen_are_off_the_dialect() {
        assert!(!setevents_allowed("STREAM"));
        assert!(!setevents_allowed("CLIENTS_SEEN"));
        assert!(!setevents_allowed("BW STREAM"));
        for ev in [
            "CIRC",
            "ORCONN",
            "GUARD",
            "NEWDESC",
            "NS",
            "ADDRMAP",
            "CIRC_MINOR",
        ] {
            assert!(!setevents_allowed(ev), "{ev} carries relay identity");
            assert!(!setevents_allowed(&format!("STATUS_CLIENT {ev}")));
        }
    }

    #[test]
    fn socks_listener_discovery_stays_control_discovery_is_refused() {
        assert!(getinfo_allowed("net/listeners/socks"));
        assert!(!getinfo_allowed("net/listeners/control"));
    }

    #[test]
    fn line_cap_admits_exact_refuses_over() {
        let mut buf = Vec::new();
        let mut r = std::io::Cursor::new(b"QUIT\n".to_vec());
        assert_eq!(read_line_capped(&mut r, &mut buf, 1024), Ok(5));
        assert_eq!(buf, b"QUIT\n");

        let long: Vec<u8> = vec![b'a'; 1100];
        let mut over = std::io::Cursor::new(long.clone());
        assert_eq!(
            read_line_capped(&mut over, &mut buf, 1024),
            Err(LineReadError::TooLong)
        );

        let mut exact_no_nl = std::io::Cursor::new(long[..1024].to_vec());
        assert_eq!(read_line_capped(&mut exact_no_nl, &mut buf, 1024), Ok(1024));

        let mut one_over = std::io::Cursor::new(long[..1025].to_vec());
        assert_eq!(
            read_line_capped(&mut one_over, &mut buf, 1024),
            Err(LineReadError::TooLong)
        );
    }

    #[test]
    fn connection_cap_admits_under_refuses_at() {
        assert!(admit_connection(0, MAX_CONNECTIONS));
        assert!(admit_connection(MAX_CONNECTIONS - 1, MAX_CONNECTIONS));
        assert!(!admit_connection(MAX_CONNECTIONS, MAX_CONNECTIONS));
        assert!(!admit_connection(1, 1));
    }

    #[test]
    fn client_auth_accepts_build_value_any_case_or_null() {
        assert!(client_auth_ok(
            "AUTHENTICATE 618709BFBEF278946629B2DA38C1E201C37BEDFBD0AD6B2DBDC4DC6E53D60AE8"
        ));
        assert!(client_auth_ok(&format!(
            "AUTHENTICATE {}",
            CLIENT_COOKIE_HEX
        )));
        assert!(client_auth_ok("AUTHENTICATE"));
        assert!(client_auth_ok("AUTHENTICATE \"\""));
        assert!(!client_auth_ok("AUTHENTICATE deadbeef"));
    }

    #[test]
    fn refusal_names_the_reason() {
        assert!(refusal("GETINFO version", false).contains("authenticate first"));
        assert!(refusal("SIGNAL HALT", true).contains("read-only dialect"));
    }

    #[test]
    fn the_shared_cookie_is_well_formed_hex() {
        assert_eq!(CLIENT_COOKIE_HEX.len(), 64);
        assert!(CLIENT_COOKIE_HEX.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
