//! Read-only Tor control dialect: status GETINFOs and events only, never SIGNAL/SETCONF/ADD_ONION.

use std::io::BufRead;

/// Shared auth value, public by design; the command whitelist is the actual gate.
pub const CLIENT_COOKIE_HEX: &str =
    "618709bfbef278946629b2da38c1e201c37bedfbd0ad6b2dbdc4dc6e53d60ae8";

/// GETINFO keywords the desktop may read; anything else is refused — answers must never carry exit-adjacent data.
pub const GETINFO_ALLOWED: &[&str] = &[
    "version",
    "config-file",
    "config-can-saveconf",
    "status/bootstrap-phase",
    "status/circuit-established",
    "status/enough-dir-info",
    "net/listeners/socks",
];

/// Events the desktop may subscribe to: state telemetry only; anything carrying relay addresses or destinations is refused.
pub const EVENTS_ALLOWED: &[&str] = &[
    "STATUS_CLIENT",
    "STATUS_GENERAL",
    "STATUS_SERVER",
    "CONF_CHANGED",
    "BW",
];

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
        "SETEVENTS" => authed && setevents_allowed(rest),
        _ => false,
    }
}

/// One unknown keyword refuses the whole line — partial answers would leak.
pub fn getinfo_allowed(rest: &str) -> bool {
    !rest.is_empty() && rest.split_whitespace().all(|kw| GETINFO_ALLOWED.contains(&kw))
}

/// Every event name must be whitelisted; bare `SETEVENTS` (all events) is refused.
pub fn setevents_allowed(rest: &str) -> bool {
    !rest.is_empty() && rest.split_whitespace().all(|ev| EVENTS_ALLOWED.contains(&ev))
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
    fn getinfo_requires_only_known_keywords() {
        assert!(getinfo_allowed("version"));
        assert!(getinfo_allowed("version status/bootstrap-phase"));
        assert!(!getinfo_allowed("circuit-status"));
        assert!(!getinfo_allowed("ns/id/0011aa22bb33cc44dd55ee66ff7700aa88bb99cc"));
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
        for ev in ["CIRC", "ORCONN", "GUARD", "NEWDESC", "NS", "ADDRMAP", "CIRC_MINOR"] {
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
        assert_eq!(
            read_line_capped(&mut exact_no_nl, &mut buf, 1024),
            Ok(1024)
        );

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
        assert!(client_auth_ok("AUTHENTICATE 618709BFBEF278946629B2DA38C1E201C37BEDFBD0AD6B2DBDC4DC6E53D60AE8"));
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
