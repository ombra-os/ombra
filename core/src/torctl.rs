//! Restricted Tor control dialect: status GETINFOs and scrubbed status events, plus one write (ADD_ONION for
//! OnionShare, rewritten to the desktop and a fixed port range). Never SIGNAL, SETCONF or arbitrary targets.

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
/// lets only their HS_DESC events through (relay identities replaced), and drops every async event type outside a fixed
/// pass list (HS_DESC, scrubbed STATUS_*, BW), whatever the client subscribed to.
#[derive(Default)]
pub struct DownstreamFilter {
    owned: Vec<String>,
    partial: Vec<u8>,
    /// Inside a `NNN+` data block: `Some(kept)` says whether its lines pass, until the closing ".".
    in_data: Option<bool>,
    /// An over-long line was dropped mid-way: everything up to its newline goes with it.
    discarding: bool,
}

/// One filtered line on its way to the desktop. `ends_reply` marks the final line of a synchronous reply
/// (`NNN ` with NNN other than 650), so the session can release local answers queued behind it.
#[derive(Debug, PartialEq, Eq)]
pub struct DownLine {
    pub bytes: Vec<u8>,
    pub ends_reply: bool,
}

impl DownstreamFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<u8> {
        self.feed_lines(data)
            .into_iter()
            .flat_map(|l| l.bytes)
            .collect()
    }

    pub fn feed_lines(&mut self, data: &[u8]) -> Vec<DownLine> {
        self.partial.extend_from_slice(data);
        let mut out = Vec::new();
        while let Some(end) = self.partial.iter().position(|&b| b == b'\n') {
            let raw: Vec<u8> = self.partial.drain(..=end).collect();
            if self.discarding {
                // the tail of an overflowed line is never a line of its own
                self.discarding = false;
                continue;
            }
            let line = String::from_utf8_lossy(&raw);
            if let Some((kept, ends_reply)) = self.classify(line.trim_end_matches(['\r', '\n'])) {
                let mut bytes = kept.into_bytes();
                bytes.extend_from_slice(b"\r\n");
                out.push(DownLine { bytes, ends_reply });
            }
        }
        if self.discarding {
            self.partial.clear();
        } else if self.partial.len() > 65_536 {
            self.partial.clear();
            self.discarding = true;
        }
        out
    }

    fn classify(&mut self, line: &str) -> Option<(String, bool)> {
        if let Some(keep) = self.in_data {
            if line == "." {
                self.in_data = None;
            }
            return keep.then(|| (line.to_string(), false));
        }
        let b = line.as_bytes();
        let coded = b.len() >= 4 && b[..3].iter().all(u8::is_ascii_digit);
        let kept = self.line(line);
        if coded && b[3] == b'+' {
            self.in_data = Some(kept.is_some());
        }
        let ends_reply = coded && b[3] == b' ' && &b[..3] != b"650";
        kept.map(|k| (k, ends_reply))
    }

    fn line(&mut self, line: &str) -> Option<String> {
        for prefix in ["250-status/bootstrap-phase=", "250 status/bootstrap-phase="] {
            if let Some(rest) = line.strip_prefix(prefix) {
                return Some(format!("{prefix}{}", scrub_status_args(rest)));
            }
        }
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
            Some(ev @ ("STATUS_SERVER" | "STATUS_CLIENT" | "STATUS_GENERAL")) => {
                let tail = rest.trim_start().strip_prefix(ev).unwrap_or("");
                if status_is_bug(tail) {
                    return None;
                }
                Some(
                    format!("650 {ev} {}", scrub_status_args(tail))
                        .trim_end()
                        .to_string(),
                )
            }
            // single-line only: a multi-line event (CONF_CHANGED) would reach the client cut to its first line
            Some("BW") => Some(line.to_string()),
            _ => None,
        }
    }
}

/// Status-event arguments the desktop may see. Everything else is dropped, notably HOSTADDR/HOSTID (the guard a
/// bootstrap problem names), SOURCE (the relay behind a CLOCK_SKEW), ADDRESS (an EXTERNAL_ADDRESS is the user's
/// public IP) and HOSTNAME (a destination).
pub const STATUS_KEYS_ALLOWED: &[&str] = &[
    "PROGRESS",
    "TAG",
    "SUMMARY",
    "WARNING",
    "REASON",
    "COUNT",
    "RECOMMENDATION",
    "SKEW",
    "CURRENT",
    "RECOMMENDED",
];

/// Keeps the bare words (severity, action) and the allowed KEY=value pairs of a status line; quote-aware, so a
/// SUMMARY="Connecting to a relay" stays one token.
pub fn scrub_status_args(args: &str) -> String {
    let mut tokens: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for c in args.chars() {
        if escaped {
            cur.push(c);
            escaped = false;
        } else if c == '\\' && quoted {
            cur.push(c);
            escaped = true;
        } else if c == '"' {
            cur.push(c);
            quoted = !quoted;
        } else if c.is_whitespace() && !quoted {
            if !cur.is_empty() {
                tokens.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() {
        tokens.push(cur);
    }
    tokens
        .into_iter()
        .filter(|t| match t.split_once('=') {
            Some((k, v)) => STATUS_KEYS_ALLOWED.contains(&k) && status_value_ok(k, v),
            None => t
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b == b'_' || b.is_ascii_digit()),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether the value of an allowed status key has the shape that key has in Tor's own status events. The key name
/// alone is not enough: Tor reports its internal "BUG" log lines as `REASON="<the log text>"`, and that text can name
/// the entry guard or carry a backtrace with the addresses the Tor process is loaded at.
pub fn status_value_ok(key: &str, value: &str) -> bool {
    let word = |v: &str, max: usize| {
        !v.is_empty() && v.len() <= max && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
    };
    let digits = |v: &str, max: usize| !v.is_empty() && v.len() <= max && v.bytes().all(|b| b.is_ascii_digit());
    let unquoted = |v: &str| -> Option<String> {
        let inner = v.strip_prefix('"')?.strip_suffix('"')?;
        (!inner.contains(['"', '\\'])).then(|| inner.to_string())
    };
    match key {
        "PROGRESS" | "COUNT" => digits(value, 6),
        "SKEW" => digits(value.strip_prefix('-').unwrap_or(value), 12),
        "TAG" | "REASON" | "RECOMMENDATION" => word(value, 48),
        // a version, or a quoted list of versions
        "CURRENT" | "RECOMMENDED" => {
            let v = unquoted(value).unwrap_or_else(|| value.to_string());
            !v.is_empty()
                && v.len() <= 1024
                && !value.contains('\\')
                && v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b',' | b' '))
        }
        // a short English phrase: letters, spaces and light punctuation. No digits, so no address, fingerprint, port
        // or memory address fits
        "SUMMARY" | "WARNING" => unquoted(value).is_some_and(|v| {
            !v.is_empty()
                && v.len() <= 120
                && v.bytes()
                    .all(|b| b.is_ascii_alphabetic() || matches!(b, b' ' | b'.' | b',' | b':' | b'\'' | b'-' | b'(' | b')'))
        }),
        _ => false,
    }
}

/// A status line whose action word is BUG is Tor reporting one of its own internal errors; none of it is for the desktop.
pub fn status_is_bug(args: &str) -> bool {
    args.split_whitespace().nth(1) == Some("BUG")
}

/// A SETEVENTS line made only of known events, as the line to send upstream: the stubbed ones are dropped (the client is
/// told they are set), the rest are forwarded. Tor replaces its whole set on every SETEVENTS, so the line always goes up,
/// a bare `SETEVENTS` (unsubscribe all) included. `None` = refuse.
pub fn setevents_plan(rest: &str) -> Option<String> {
    let events: Vec<&str> = rest.split_whitespace().collect();
    if !events
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
        "SETEVENTS".to_string()
    } else {
        format!("SETEVENTS {}", kept.join(" "))
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
    "BW",
];

/// Events clients ask for that are accepted but never subscribed upstream: Tor Browser's CIRC/STREAM/SIGNAL (no circuit or
/// stream data can flow) and stem's CONF_CHANGED (multi-line, which the line filter cannot pass whole).
pub const EVENTS_STUBBED: &[&str] = &["CIRC", "STREAM", "SIGNAL", "CONF_CHANGED"];

/// Local answer for commands the browser needs to see succeed but whose real data must never reach the desktop.
pub fn stub_reply(line: &str, authed: bool) -> Option<&'static str> {
    if !authed {
        return None;
    }
    let (verb, rest) = verb_of(line);
    match verb {
        "GETINFO" if rest == "circuit-status" => Some("250-circuit-status=\r\n250 OK\r\n"),
        // a repeat AUTHENTICATE or PROTOCOLINFO after the handshake is answered here, never forwarded with client bytes
        "AUTHENTICATE" => Some("250 OK\r\n"),
        "PROTOCOLINFO" => Some(PROTOCOLINFO_REPLY),
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
    // no control bytes anywhere: split_whitespace would otherwise swallow a stray CR or tab
    if rest.bytes().any(|b| b.is_ascii_control()) {
        return None;
    }
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
            // digits only: u16's parser also takes a leading '+'
            if !target.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
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
        } else {
            let key = token.strip_prefix("ClientAuthV3=")?;
            if !is_client_auth_v3(key) || auths.len() >= 8 {
                return None;
            }
            auths.push(key);
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
    // printable ASCII only: no control byte and no non-ASCII character is part of any command this dialect knows
    if !line.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return false;
    }
    let (verb, rest) = verb_of(line);
    match verb {
        "QUIT" => rest.is_empty(),
        "PROTOCOLINFO" => true,
        "AUTHENTICATE" => true,
        "GETINFO" => authed && getinfo_allowed(rest),
        "GETCONF" => authed && getconf_allowed(rest),
        "DEL_ONION" => authed && del_onion_allowed(rest),
        "SETEVENTS" => authed && setevents_allowed(rest),
        _ => false,
    }
}

/// The line that goes to Tor for an allowed GETINFO, GETCONF, DEL_ONION or QUIT: rebuilt from its verb and tokens, so
/// Tor never parses the client's own bytes (its tokenizer and this one need not agree on what separates words).
/// `None` for any other verb, or a line that is not allowed.
pub fn rebuilt_forward(line: &str) -> Option<String> {
    if !command_allowed(line, true) {
        return None;
    }
    let (verb, rest) = verb_of(line);
    match verb {
        "GETINFO" | "GETCONF" => Some(format!("{verb} {}", rest.split_whitespace().collect::<Vec<_>>().join(" "))),
        "DEL_ONION" => Some(format!("DEL_ONION {}", rest.trim())),
        "QUIT" => Some("QUIT".to_string()),
        _ => None,
    }
}

/// One unknown keyword refuses the whole line — partial answers would leak.
pub fn getinfo_allowed(rest: &str) -> bool {
    rest.split_whitespace().next().is_some()
        && rest
            .split_whitespace()
            .all(|kw| GETINFO_ALLOWED.contains(&kw))
}

pub fn getconf_allowed(rest: &str) -> bool {
    rest.split_whitespace().next().is_some()
        && rest
            .split_whitespace()
            .all(|kw| GETCONF_ALLOWED.iter().any(|a| a.eq_ignore_ascii_case(kw)))
}

/// A v3 onion service id: 56 base32 characters, nothing else.
pub fn del_onion_allowed(rest: &str) -> bool {
    rest.len() == 56 && rest.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7'))
}

/// Every event name must be whitelisted; bare `SETEVENTS` (unsubscribe all, as tor reads it) passes.
pub fn setevents_allowed(rest: &str) -> bool {
    rest.split_whitespace()
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

/// Where the gateway's own scripts leave Tor's health: the crash tripwire (`ombra-tor-tripwire`) and the daily version
/// check (`ombra-tor-freshness`). Root writes, everyone reads; cleared by a gateway restart.
pub const GATEWAY_STATE_DIR: &str = "/run/ombra";
/// The one GETINFO key the filter answers about the gateway itself. Tor never sees it.
pub const GATEWAY_STATE_KEY: &str = "ombra/gateway-state";

/// What the desktop may know about the gateway's Tor: how often it died unexpectedly in this boot, whether its
/// system-call filter killed it, and whether Debian has a newer Tor. Three small values, rebuilt here from the state
/// files; no byte of a file is ever passed through.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct GatewayState {
    /// Unexpected deaths this boot, capped at 9.
    pub crashes: u8,
    pub killed: bool,
    pub update: bool,
}

impl GatewayState {
    /// `crashes` is the text of the counter file, `killed` whether the kill marker exists, `update` the text of the
    /// version-check file. Anything unreadable or malformed counts as nothing to report.
    pub fn from_files(crashes: Option<&str>, killed: bool, update: Option<&str>) -> GatewayState {
        let crashes = crashes
            .map(str::trim)
            .filter(|t| !t.is_empty() && t.len() <= 6 && t.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|t| t.parse::<u32>().ok())
            .map_or(0, |n| n.min(9) as u8);
        let update = update.and_then(|t| t.lines().next()).map(str::trim) == Some("available");
        GatewayState {
            crashes,
            killed,
            update,
        }
    }

    pub fn read() -> GatewayState {
        let dir = std::path::Path::new(GATEWAY_STATE_DIR);
        let text = |name: &str| std::fs::read_to_string(dir.join(name)).ok();
        GatewayState::from_files(
            text("tor-crashes").as_deref(),
            dir.join("tor-killed").exists(),
            text("tor-update").as_deref(),
        )
    }

    /// `crashes:N,killed:B,update:B` — digits, lowercase letters, colons and commas only.
    pub fn token(self) -> String {
        format!(
            "crashes:{},killed:{},update:{}",
            self.crashes,
            u8::from(self.killed),
            u8::from(self.update)
        )
    }

    /// The reverse of `token`, for the desktop side; `None` for anything that is not exactly that shape.
    pub fn parse_token(token: &str) -> Option<GatewayState> {
        let mut parts = token.split(',');
        let field = |part: Option<&str>, name: &str| -> Option<u8> {
            let v = part?.strip_prefix(name)?.strip_prefix(':')?;
            (v.len() == 1 && v.as_bytes()[0].is_ascii_digit()).then(|| v.as_bytes()[0] - b'0')
        };
        let crashes = field(parts.next(), "crashes")?;
        let killed = field(parts.next(), "killed")?;
        let update = field(parts.next(), "update")?;
        if parts.next().is_some() || killed > 1 || update > 1 {
            return None;
        }
        Some(GatewayState {
            crashes,
            killed: killed == 1,
            update: update == 1,
        })
    }

    /// The local answer to `GETINFO ombra/gateway-state`.
    pub fn getinfo_reply(self) -> String {
        format!("250-{GATEWAY_STATE_KEY}={}\r\n250 OK\r\n", self.token())
    }

    /// The line a client gets when every session slot is taken: the state still rides along, so the desktop's notice
    /// about Tor does not depend on a free slot.
    pub fn busy_line(self) -> String {
        format!(
            "551 ombra-filter: too many connections gateway-state={}",
            self.token()
        )
    }

    /// The line a client gets when Tor's control port cannot be reached: Tor is down, and this is the only moment the
    /// desktop can learn why, so the state rides on the refusal.
    pub fn unreachable_line(self) -> String {
        format!(
            "551 ombra-filter: tor control unreachable gateway-state={}",
            self.token()
        )
    }
}

/// `GETINFO ombra/gateway-state`, alone on the line and after authentication.
pub fn is_gateway_state_query(line: &str, authed: bool) -> bool {
    let (verb, rest) = verb_of(line);
    authed && verb == "GETINFO" && rest == GATEWAY_STATE_KEY
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
    fn gateway_state_is_rebuilt_from_the_files_never_passed_through() {
        let none = GatewayState::from_files(None, false, None);
        assert_eq!(none, GatewayState::default());
        assert_eq!(none.token(), "crashes:0,killed:0,update:0");
        let s = GatewayState::from_files(Some("1\n"), false, Some("available\n"));
        assert_eq!(s.token(), "crashes:1,killed:0,update:1");
        assert_eq!(GatewayState::from_files(Some("2"), true, Some("current")).token(), "crashes:2,killed:1,update:0");
        // a huge or hostile counter is capped or ignored; file text never reaches the reply
        assert_eq!(GatewayState::from_files(Some("400"), false, None).crashes, 9);
        for bad in ["", " ", "-1", "1 2", "1\r\n250 OK", "9999999", "one", "1,killed:1"] {
            assert_eq!(GatewayState::from_files(Some(bad), false, None).crashes, 0, "{bad:?}");
        }
        for bad in ["", "AVAILABLE", "available now", "current\navailable", "250 OK"] {
            assert!(!GatewayState::from_files(None, false, Some(bad)).update, "{bad:?}");
        }
    }

    #[test]
    fn gateway_state_token_round_trips_and_rejects_other_shapes() {
        for (c, k, u) in [(0, false, false), (1, false, true), (9, true, true), (2, true, false)] {
            let s = GatewayState { crashes: c, killed: k, update: u };
            assert_eq!(GatewayState::parse_token(&s.token()), Some(s));
            assert!(s.token().bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b':' || b == b','));
        }
        for bad in [
            "", "crashes:1", "crashes:1,killed:0", "crashes:10,killed:0,update:0", "crashes:1,killed:2,update:0",
            "crashes:1,killed:0,update:0,extra:1", "killed:0,crashes:1,update:0", "crashes:a,killed:0,update:0",
            "crashes:1,killed:0,update:0 ", "CRASHES:1,killed:0,update:0",
        ] {
            assert_eq!(GatewayState::parse_token(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn gateway_state_query_is_exact_and_needs_authentication() {
        assert!(is_gateway_state_query("GETINFO ombra/gateway-state", true));
        assert!(!is_gateway_state_query("GETINFO ombra/gateway-state", false));
        assert!(!is_gateway_state_query("GETINFO ombra/gateway-state version", true));
        assert!(!is_gateway_state_query("GETINFO version ombra/gateway-state", true));
        assert!(!is_gateway_state_query("GETCONF ombra/gateway-state", true));
        // it is answered here and never forwarded: Tor does not know the key, and the allowlist does not carry it
        assert!(!command_allowed("GETINFO ombra/gateway-state", true));
        let s = GatewayState { crashes: 1, killed: false, update: true };
        assert_eq!(s.getinfo_reply(), "250-ombra/gateway-state=crashes:1,killed:0,update:1\r\n250 OK\r\n");
        assert_eq!(
            s.unreachable_line(),
            "551 ombra-filter: tor control unreachable gateway-state=crashes:1,killed:0,update:1"
        );
    }

    #[test]
    fn tors_internal_bug_reports_never_reach_the_desktop() {
        let mut f = DownstreamFilter::new();
        // a backtrace frame: the addresses the Tor process is loaded at
        let bt = "650 STATUS_GENERAL WARN BUG REASON=\"    /usr/bin/tor(+0x1a2b) [0x55d0c0de1a2b]\"\r\n";
        assert!(f.feed_lines(bt.as_bytes()).is_empty());
        // a guard named in a BUG notice
        let guard = "650 STATUS_GENERAL NOTICE BUG REASON=\"Unexpectedly high successes counts (10.0/9.0) for guard $ABCDEF0123456789ABCDEF0123456789ABCDEF01~nick ($ABCD...)\"\r\n";
        assert!(f.feed_lines(guard.as_bytes()).is_empty());
        // and even outside a BUG line, a REASON that is not one word is dropped from the line
        let odd = scrub_status_args("WARN SOMETHING REASON=\"text with 0x55d0 and $FP~nick\" COUNT=3");
        assert_eq!(odd, "WARN SOMETHING COUNT=3");
    }

    #[test]
    fn status_values_must_have_their_keys_shape() {
        // what Tor really sends passes unchanged
        let boot = "NOTICE BOOTSTRAP PROGRESS=14 TAG=handshake SUMMARY=\"Handshaking with a relay\"";
        assert_eq!(scrub_status_args(boot), boot);
        let warn = "WARN BOOTSTRAP PROGRESS=10 TAG=conn_done SUMMARY=\"Connected to a relay\" WARNING=\"No route to host\" REASON=NOROUTE COUNT=4 RECOMMENDATION=warn";
        assert_eq!(scrub_status_args(warn), warn);
        assert_eq!(scrub_status_args("NOTICE CLOCK_SKEW SKEW=-3600"), "NOTICE CLOCK_SKEW SKEW=-3600");
        let ver = "WARN DANGEROUS_VERSION CURRENT=0.4.9.11 REASON=OBSOLETE RECOMMENDED=\"0.4.9.15,0.4.9.16\"";
        assert_eq!(scrub_status_args(ver), ver);
        for (k, v, ok) in [
            ("PROGRESS", "100", true), ("PROGRESS", "1e9", false), ("PROGRESS", "", false), ("COUNT", "1234567", false),
            ("SKEW", "--1", false), ("SKEW", "12", true),
            ("REASON", "NOROUTE", true), ("REASON", "\"NOROUTE\"", false), ("REASON", "a b", false), ("TAG", "conn-done", false),
            ("SUMMARY", "Done", false), ("SUMMARY", "\"Done\"", true), ("SUMMARY", "\"relay at 1.2.3.4\"", false),
            ("WARNING", "\"$FP~nick\"", false), ("WARNING", "\"[0x55d0]\"", false), ("WARNING", "\"a\\\"b\"", false),
            ("CURRENT", "0.4.9.15", true), ("CURRENT", "0.4.9.15 (git-abc)", false), ("RECOMMENDED", "\"0.4.9.15, 0.5.1.2-alpha\"", true),
            ("HOSTADDR", "1.2.3.4", false),
        ] {
            assert_eq!(status_value_ok(k, v), ok, "{k}={v}");
        }
        let long = format!("\"{}\"", "a".repeat(121));
        assert!(!status_value_ok("SUMMARY", &long));
    }

    #[test]
    fn forwarded_commands_are_rebuilt_never_the_clients_bytes() {
        assert_eq!(rebuilt_forward("GETINFO version").as_deref(), Some("GETINFO version"));
        assert_eq!(
            rebuilt_forward("GETINFO  status/bootstrap-phase   status/circuit-established ").as_deref(),
            Some("GETINFO status/bootstrap-phase status/circuit-established")
        );
        assert_eq!(rebuilt_forward("GETCONF HiddenServiceSingleHopMode").as_deref(), Some("GETCONF HiddenServiceSingleHopMode"));
        let id = "a".repeat(56);
        assert_eq!(rebuilt_forward(&format!("DEL_ONION {id}")), Some(format!("DEL_ONION {id}")));
        assert_eq!(rebuilt_forward("QUIT").as_deref(), Some("QUIT"));
        // QUIT carries nothing; no control byte or non-ASCII character is in any allowed line
        assert!(!command_allowed("QUIT now", true));
        assert!(!command_allowed("QUIT \u{0}", true));
        for bad in ["GETINFO version\rnet/listeners/socks", "GETINFO version\u{a0}onions/current", "GETINFO versi\u{f6}n", "QUIT\t"] {
            assert!(!command_allowed(bad, true), "{bad:?}");
            assert_eq!(rebuilt_forward(bad), None, "{bad:?}");
        }
        assert_eq!(rebuilt_forward("SETCONF x=1"), None);
        assert_eq!(rebuilt_forward("GETINFO address"), None);
    }

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
            stub_reply("GETINFO circuit-status", true),
            Some("250-circuit-status=\r\n250 OK\r\n")
        );
        // SETEVENTS is never answered locally: tor must see each one to replace its set
        assert_eq!(stub_reply("SETEVENTS CIRC STREAM", true), None);
        assert_eq!(stub_reply("SETEVENTS", true), None);
        assert_eq!(stub_reply("GETINFO circuit-status ns/all", true), None);
        assert_eq!(stub_reply("GETINFO stream-status", true), None);
        assert_eq!(stub_reply("AUTHENTICATE", true), Some("250 OK\r\n"));
        assert_eq!(stub_reply("PROTOCOLINFO 1", true), Some(PROTOCOLINFO_REPLY));
        assert_eq!(stub_reply("AUTHENTICATE", false), None);
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
            setevents_plan("SIGNAL CONF_CHANGED STATUS_SERVER").as_deref(),
            Some("SETEVENTS STATUS_SERVER")
        );
        assert_eq!(
            setevents_plan("SIGNAL HS_DESC").as_deref(),
            Some("SETEVENTS HS_DESC")
        );
        assert_eq!(setevents_plan("BW").as_deref(), Some("SETEVENTS BW"));
        assert_eq!(setevents_plan("SIGNAL ORCONN"), None);
        assert_eq!(setevents_plan("ADDRMAP"), None);
        assert_eq!(setevents_plan("BW DEBUG"), None);
    }

    #[test]
    fn every_setevents_replaces_the_upstream_set() {
        // stubbed-only and bare lines still go up, empty, so an earlier subscription is dropped
        assert_eq!(setevents_plan("SIGNAL CIRC").as_deref(), Some("SETEVENTS"));
        assert_eq!(setevents_plan("CONF_CHANGED").as_deref(), Some("SETEVENTS"));
        assert_eq!(setevents_plan("").as_deref(), Some("SETEVENTS"));
        assert_eq!(setevents_plan("   ").as_deref(), Some("SETEVENTS"));
        assert!(command_allowed("SETEVENTS", true));
        assert!(!command_allowed("SETEVENTS", false));
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
        assert!(setevents_allowed("STATUS_CLIENT BW"));
        assert!(setevents_allowed(""));
        assert!(!setevents_allowed("STATUS_CLIENT CONF_CHANGED"));
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

    #[test]
    fn status_events_lose_every_address_and_destination() {
        let mut f = DownstreamFilter::new();
        let out = f.feed(b"650 STATUS_CLIENT WARN BOOTSTRAP PROGRESS=10 TAG=conn_done SUMMARY=\"Connected to a relay\" WARNING=\"Connection refused\" REASON=CONNECTREFUSED COUNT=3 RECOMMENDATION=ignore HOSTID=\"$AAAA\" HOSTADDR=\"198.51.100.7:443\"\r\n");
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text, "650 STATUS_CLIENT WARN BOOTSTRAP PROGRESS=10 TAG=conn_done SUMMARY=\"Connected to a relay\" WARNING=\"Connection refused\" REASON=CONNECTREFUSED COUNT=3 RECOMMENDATION=ignore\r\n");
        let out =
            f.feed(b"650 STATUS_GENERAL WARN CLOCK_SKEW SKEW=-3600 SOURCE=OR:198.51.100.7:443\r\n");
        assert_eq!(out, b"650 STATUS_GENERAL WARN CLOCK_SKEW SKEW=-3600\r\n");
        let out = f.feed(
            b"650 STATUS_SERVER NOTICE EXTERNAL_ADDRESS ADDRESS=203.0.113.9 METHOD=DIRSERV\r\n",
        );
        assert_eq!(out, b"650 STATUS_SERVER NOTICE EXTERNAL_ADDRESS\r\n");
        let out =
            f.feed(b"650 STATUS_CLIENT WARN SOCKS_BAD_HOSTNAME HOSTNAME=\"secret.example\"\r\n");
        assert_eq!(out, b"650 STATUS_CLIENT WARN SOCKS_BAD_HOSTNAME\r\n");
        let out = f.feed(b"250-status/bootstrap-phase=WARN BOOTSTRAP PROGRESS=5 TAG=conn HOSTADDR=\"198.51.100.7:443\"\r\n");
        assert_eq!(
            out,
            b"250-status/bootstrap-phase=WARN BOOTSTRAP PROGRESS=5 TAG=conn\r\n"
        );
    }

    #[test]
    fn multi_line_conf_changed_events_are_dropped_whole() {
        let mut f = DownstreamFilter::new();
        assert!(f
            .feed_lines(b"650-CONF_CHANGED\r\n650-SocksPort=9050\r\n650 OK\r\n")
            .is_empty());
        // the stream stays in sync: the next reply passes and still ends its command
        let lines = f.feed_lines(b"250 OK\r\n");
        assert_eq!(lines.len(), 1);
        assert!(lines[0].ends_reply);
    }

    #[test]
    fn verbs_are_matched_exactly_and_lowercase_is_refused() {
        for line in [
            "getinfo version",
            "Getinfo version",
            "setevents BW",
            "authenticate",
            "add_onion NEW:ED25519-V3 Port=80,17600",
            "del_onion aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "getconf HiddenServiceSingleHopMode",
        ] {
            assert!(!command_allowed(line, true), "{line:?} must be refused");
            assert_eq!(stub_reply(line, true), None, "{line:?}");
        }
    }

    #[test]
    fn tab_and_vertical_tab_are_not_verb_separators() {
        for line in [
            "GETINFO\tversion",
            "GETINFO\x0bversion",
            "SETEVENTS\tBW",
            "SETEVENTS\x0bBW",
            "GETCONF\tHiddenServiceSingleHopMode",
            "QUIT\tnow",
            "AUTHENTICATE\tdeadbeef",
        ] {
            assert!(!command_allowed(line, true), "{line:?} must be refused");
            assert_eq!(stub_reply(line, true), None, "{line:?}");
        }
        // inside the arguments they split, so a refused key cannot hide behind one
        assert!(!command_allowed("GETINFO version\tcircuit-status", true));
        assert!(!command_allowed("GETINFO version\x0bns/all", true));
        assert!(!command_allowed("SETEVENTS BW\tCIRC_MINOR", true));
        assert_eq!(setevents_plan("BW\x0bORCONN"), None);
    }

    #[test]
    fn a_carriage_return_mid_line_cannot_smuggle_a_second_command() {
        assert_eq!(
            chomp("GETINFO version\rSIGNAL HALT\r\n"),
            "GETINFO version\rSIGNAL HALT"
        );
        assert!(!command_allowed("GETINFO version\rSIGNAL HALT", true));
        assert!(!command_allowed("GETINFO version\rns/all", true));
        assert!(!command_allowed("SIGNAL\rGETINFO version", true));
        assert!(!command_allowed("DEL_ONION aaaa\rSIGNAL HALT", true));
        assert_eq!(setevents_plan("BW\rSIGNAL HALT"), None);
        assert_eq!(
            add_onion_rewrite("NEW:ED25519-V3 Port=80,17600\rSIGNAL HALT", ip()),
            None
        );
    }

    #[test]
    fn an_embedded_nul_is_refused() {
        for line in [
            "GETINFO version\0",
            "GETINFO\0version",
            "GETINFO version\0circuit-status",
            "SETEVENTS BW\0",
            "GETCONF HiddenServiceSingleHopMode\0",
            "QUIT\0",
            "\0GETINFO version",
        ] {
            assert!(!command_allowed(line, true), "{line:?} must be refused");
        }
        assert_eq!(setevents_plan("BW\0"), None);
        assert!(!del_onion_allowed(&format!("{}\0", "a".repeat(55))));
        assert_eq!(
            add_onion_rewrite("NEW:ED25519-V3 Port=80,17600\0", ip()),
            None
        );
        assert_eq!(
            add_onion_rewrite("NEW:ED25519-V3\0 Port=80,17600", ip()),
            None
        );
    }

    #[test]
    fn plus_prefixed_multi_line_verbs_are_refused() {
        for line in [
            "+GETINFO version",
            "+SETEVENTS BW",
            "+GETCONF HiddenServiceSingleHopMode",
            "+QUIT",
            "+PROTOCOLINFO 1",
            "+AUTHENTICATE",
            "+ADD_ONION NEW:ED25519-V3 Port=80,17600",
            "+DEL_ONION aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            assert!(!command_allowed(line, true), "{line:?} must be refused");
            assert!(!command_allowed(line, false), "{line:?} must be refused");
            assert_eq!(stub_reply(line, true), None, "{line:?}");
        }
    }

    #[test]
    fn a_no_break_space_never_joins_or_hides_getinfo_keys() {
        assert!(!command_allowed(
            "GETINFO version\u{a0}circuit-status",
            true
        ));
        assert!(!command_allowed("GETINFO\u{a0}version", true));
        assert!(!getinfo_allowed("version\u{a0}ns/all"));
        assert!(!getinfo_allowed("\u{a0}"));
        assert!(!getconf_allowed(
            "HiddenServiceSingleHopMode\u{a0}SocksPort"
        ));
        assert_eq!(setevents_plan("BW\u{a0}ORCONN"), None);
    }

    #[test]
    fn an_upstream_line_over_64k_is_dropped_whole() {
        let mut f = DownstreamFilter::new();
        let mut big = b"650 CIRC 1 BUILT ".to_vec();
        big.extend(std::iter::repeat_n(b'A', 70_000));
        let mut out = Vec::new();
        for chunk in big.chunks(4096) {
            out.extend(f.feed_lines(chunk));
        }
        out.extend(f.feed_lines(b" $ABCD~relay 198.51.100.7\r\n"));
        assert!(
            out.is_empty(),
            "the tail of an overflowed line leaked: {:?}",
            out.iter()
                .map(|l| String::from_utf8_lossy(&l.bytes)
                    .chars()
                    .take(80)
                    .collect::<String>())
                .collect::<Vec<_>>()
        );
        // and the stream resynchronizes on the next whole line
        assert_eq!(f.feed(b"250 OK\r\n"), b"250 OK\r\n");
    }

    #[test]
    fn signed_or_padded_onion_ports_are_refused() {
        for rest in [
            "NEW:ED25519-V3 Port=80,+17600",
            "NEW:ED25519-V3 Port=80,+1760",
            "NEW:ED25519-V3 Port=+80,17600",
            "NEW:ED25519-V3 Port=80,-17600",
            "NEW:ED25519-V3 Port=80, 17600",
            "NEW:ED25519-V3 Port=+1,1",
            "NEW:ED25519-V3 Port=80,0x44c0",
            "NEW:ED25519-V3 Port=80,17600.0",
        ] {
            assert_eq!(
                add_onion_rewrite(rest, ip()),
                None,
                "{rest:?} must be refused"
            );
        }
    }

    #[test]
    fn add_onion_tokens_are_strict() {
        for rest in ["NEW:ED25519-V3 Port=1,+1", "NEW:ED25519-V3 Port=80,17600\r"] {
            let got = add_onion_rewrite(rest, ip());
            assert_eq!(got, None, "{rest:?} must be refused, got {got:?}");
        }
    }

    #[test]
    fn reply_ends_are_marked_and_data_blocks_are_not_mistaken_for_them() {
        let mut f = DownstreamFilter::new();
        let lines =
            f.feed_lines(b"250+config-text=\r\n250 not an end\r\n.\r\n250 OK\r\n650 BW 1 2\r\n");
        let ends: Vec<bool> = lines.iter().map(|l| l.ends_reply).collect();
        assert_eq!(ends, vec![false, false, false, true, false]);
        // a dropped event's data block is dropped with it
        let lines = f.feed_lines(b"650+NS\r\nr relay 1.2.3.4\r\n.\r\n250 OK\r\n");
        assert_eq!(lines.len(), 1);
        assert!(lines[0].ends_reply);
    }
}
