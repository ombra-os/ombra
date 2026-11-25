//! Control-port bouncer: forwards only the read-only dialect (crate::torctl);
//! no client-supplied byte is ever logged; pre-auth clients are timed out and the session count is capped.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use ombra_boot::torctl;

const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(30);
/// Tor answers its own AUTHENTICATE at once; a silent upstream must not hold the session.
const UPSTREAM_AUTH_TIMEOUT: Duration = Duration::from_secs(5);
/// Back-off after a failed accept (fd exhaustion), so the loop never spins.
const ACCEPT_RETRY: Duration = Duration::from_millis(100);

const USAGE: &str = "\
usage: ombra-torctl-filter [--listen ADDR:PORT] [--upstream ADDR:PORT]
                           [--cookie-file PATH] [--client-cookie-hex HEX]

  --listen            intnet address to accept the desktop on
                      (default 10.55.10.1:9052)
  --upstream          tor's loopback-only control port
                      (default 127.0.0.1:9051)
  --cookie-file       tor's control_auth_cookie, readable by this user
                      (default /var/lib/tor/control_auth_cookie)
  --client-cookie-hex override the shared build cookie (tests)
  -h, --help          this text";

struct Config {
    listen: String,
    upstream: String,
    cookie_file: PathBuf,
    client_cookie_hex: String,
}

#[derive(Clone, Copy)]
struct Limits {
    auth_timeout: Duration,
    /// a client that stops reading is cut off after this long instead of wedging the session's one writer
    write_timeout: Duration,
    idle_timeout: Option<Duration>,
    line_cap: usize,
    max_connections: usize,
}

impl Limits {
    fn production() -> Self {
        Limits {
            auth_timeout: Duration::from_secs(torctl::AUTH_TIMEOUT_SECS),
            write_timeout: CLIENT_WRITE_TIMEOUT,
            idle_timeout: None,
            line_cap: torctl::MAX_LINE_BYTES,
            max_connections: torctl::MAX_CONNECTIONS,
        }
    }
}

/// Counts live sessions so the cap is exact under thread races.
#[derive(Default)]
struct ConnectionPool(AtomicUsize);

impl ConnectionPool {
    fn acquire(&self, cap: usize) -> bool {
        loop {
            let current = self.0.load(Ordering::Relaxed);
            if !torctl::admit_connection(current, cap) {
                return false;
            }
            if self
                .0
                .compare_exchange_weak(current, current + 1, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
            {
                return true;
            }
        }
    }

    fn release(&self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

struct Session {
    pool: Arc<ConnectionPool>,
}

impl Drop for Session {
    fn drop(&mut self) {
        self.pool.release();
    }
}

/// A log line that cannot panic: `eprintln!` panics when stderr is gone, and a panic in a session thread would leave its
/// reply thread and Tor control connection behind.
macro_rules! log {
    ($($arg:tt)*) => {{
        use std::io::Write as _;
        let _ = writeln!(std::io::stderr(), $($arg)*);
    }};
}

/// Local answers a client may queue behind one unanswered Tor reply. Past it the session ends: Tor answers in
/// microseconds, so only a stalled Tor and a client piling up requests get here.
const MAX_PENDING: usize = 256;

fn main() -> ExitCode {
    let mut cfg = Config {
        listen: "10.55.10.1:9052".into(),
        upstream: "127.0.0.1:9051".into(),
        cookie_file: PathBuf::from("/var/lib/tor/control_auth_cookie"),
        client_cookie_hex: torctl::CLIENT_COOKIE_HEX.to_string(),
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut val = || args.next().unwrap_or_else(|| die(USAGE));
        match arg.as_str() {
            "--listen" => cfg.listen = val(),
            "--upstream" => cfg.upstream = val(),
            "--cookie-file" => cfg.cookie_file = PathBuf::from(val()),
            "--client-cookie-hex" => cfg.client_cookie_hex = val(),
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => die(&format!("unknown argument {other}\n\n{USAGE}")),
        }
    }

    let listener = match TcpListener::bind(&cfg.listen) {
        Ok(l) => l,
        Err(e) => die(&format!("bind {}: {e}", cfg.listen)),
    };
    log!(
        "ombra-torctl-filter: listening on {} -> {} (read-only dialect)",
        cfg.listen, cfg.upstream
    );
    let pool = Arc::new(ConnectionPool::default());
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle_incoming(&pool, stream, &cfg, Limits::production()),
            Err(_) => thread::sleep(ACCEPT_RETRY),
        }
    }
    ExitCode::SUCCESS
}

fn die(msg: &str) -> ! {
    log!("ombra-torctl-filter: {msg}");
    std::process::exit(2);
}

/// Cap-check + spawn; shared with the tests that pin the cap.
fn handle_incoming(pool: &Arc<ConnectionPool>, stream: TcpStream, cfg: &Config, limits: Limits) {
    if !pool.acquire(limits.max_connections) {
        let mut stream = stream;
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        let _ = stream.write_all(format!("{}\r\n", torctl::GatewayState::read().busy_line()).as_bytes());
        log!(
            "ombra-torctl-filter: connection refused: session cap {} reached",
            limits.max_connections
        );
        return;
    }
    let session = Session {
        pool: Arc::clone(pool),
    };
    let cfg = Config {
        listen: cfg.listen.clone(),
        upstream: cfg.upstream.clone(),
        cookie_file: cfg.cookie_file.clone(),
        client_cookie_hex: cfg.client_cookie_hex.clone(),
    };
    // a failed spawn drops the closure, and with it the stream and the session's slot
    let spawned = thread::Builder::new()
        .name("torctl-session".into())
        .spawn(move || {
            let _session = session;
            serve(stream, &cfg, &limits);
        });
    if spawned.is_err() {
        log!("ombra-torctl-filter: connection dropped: cannot spawn a session thread");
    }
}

/// One connection: client handshake, upstream cookie auth, then filter client lines up and pass upstream bytes down raw.
fn serve(client: TcpStream, cfg: &Config, limits: &Limits) {
    let peer = client
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "?".into());
    let peer_ip = client.peer_addr().map(|a| a.ip()).ok();
    let mut client = client;
    let _ = client.set_nodelay(true);
    // pre-auth is one total deadline, not per read: refused lines cannot keep a slot alive
    let auth_deadline = Instant::now() + limits.auth_timeout;
    let _ = client.set_read_timeout(Some(limits.auth_timeout));
    // set before any clone, so every handle to the client shares it
    if client
        .set_write_timeout(Some(limits.write_timeout))
        .is_err()
    {
        return;
    }

    let upstream = match TcpStream::connect(&cfg.upstream) {
        Ok(s) => s,
        Err(e) => {
            // Tor is down: the refusal carries the gateway's own account of why (crash tripwire, version check)
            log!("ombra-torctl-filter: tor control unreachable ({e})");
            return refuse_close(client, &torctl::GatewayState::read().unreachable_line());
        }
    };
    let _ = upstream.set_nodelay(true);
    let cookie = match std::fs::read(&cfg.cookie_file) {
        Ok(c) if !c.is_empty() => hex_encode(&c),
        _ => return refuse_close(client, "551 ombra-filter: cannot read tor control cookie"),
    };
    if let Err(e) = upstream_auth(&upstream, &cookie) {
        return refuse_close(
            client,
            &format!("551 ombra-filter: upstream auth failed ({e})"),
        );
    }
    let mut upstream_writer = try_clone(&upstream);

    let mut reader = BufReader::new(try_clone(&client));
    let mut line: Vec<u8> = Vec::new();
    // break = authenticated; return = client gone, stalled, out of time, or failed the cookie
    loop {
        let left = auth_deadline.saturating_duration_since(Instant::now());
        // reads AND writes share the one deadline: a client that reads its answers a byte at a time cannot outlive it
        if left.is_zero()
            || client.set_read_timeout(Some(left)).is_err()
            || client.set_write_timeout(Some(left.min(limits.write_timeout))).is_err()
        {
            return;
        }
        match torctl::read_line_capped(&mut reader, &mut line, limits.line_cap) {
            Err(torctl::LineReadError::TooLong) => {
                return refuse_close(client, "510 ombra-filter: line too long");
            }
            Err(_) => return,
            Ok(_) => {}
        }
        let Some(text) = std::str::from_utf8(&line).ok() else {
            return;
        };
        let cmd = torctl::chomp(text);
        if cmd.is_empty() {
            continue;
        }
        let (verb, _) = verb_split(cmd);
        match verb {
            "QUIT" => {
                let _ = upstream_writer.write_all(b"QUIT\r\n");
                return;
            }
            "PROTOCOLINFO" => {
                if client
                    .write_all(torctl::PROTOCOLINFO_REPLY.as_bytes())
                    .is_err()
                {
                    return;
                }
            }
            "AUTHENTICATE" => {
                if torctl::client_auth_ok(cmd) {
                    // the client never learns the upstream cookie; this 250 is ours, not tor's
                    if client.write_all(b"250 OK\r\n").is_err() {
                        return;
                    }
                    log!("ombra-torctl-filter: {peer} authenticated");
                    break;
                }
                let _ = client.write_all(b"515 ombra-filter: authentication failed\r\n");
                log!("ombra-torctl-filter: {peer} bad cookie");
                return;
            }
            _ => {
                let refused = format!("{}\r\n", torctl::refusal(cmd, false));
                log!("ombra-torctl-filter: {peer} command refused");
                if client.write_all(refused.as_bytes()).is_err() {
                    return;
                }
            }
        }
    }

    let _ = client.set_read_timeout(limits.idle_timeout);
    let _ = client.set_write_timeout(Some(limits.write_timeout));
    // whatever ends this function (a return, or a panic unwinding), both sockets are shut, so the reply thread ends
    // and Tor's control connection is released
    let _guard = ShutdownGuard(try_clone(&upstream), try_clone(&client));
    let mut onion_adds: u32 = 0;
    let out = Arc::new(Mutex::new(ClientOut {
        stream: try_clone(&client),
        pending: VecDeque::new(),
    }));
    let downstream = {
        let out = Arc::clone(&out);
        let upstream = try_clone(&upstream);
        thread::Builder::new()
            .name("torctl-down".into())
            .spawn(move || {
                let mut inp = BufReader::new(upstream);
                let mut filter = torctl::DownstreamFilter::new();
                let mut buf = [0u8; 4096];
                loop {
                    match inp.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let lines = filter.feed_lines(&buf[..n]);
                            if !lines.is_empty() && out_lock(&out).deliver(lines).is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = out_lock(&out).stream.shutdown(std::net::Shutdown::Both);
            })
    };
    let Ok(downstream) = downstream else {
        log!("ombra-torctl-filter: {peer} dropped: cannot spawn the reply thread");
        let _ = upstream_writer.shutdown(std::net::Shutdown::Both);
        let _ = client.shutdown(std::net::Shutdown::Both);
        return;
    };

    // every line is answered in order: forwarded lines by tor, the rest locally, queued behind earlier forwards
    let mut quit = false;
    loop {
        match torctl::read_line_capped(&mut reader, &mut line, limits.line_cap) {
            Err(torctl::LineReadError::TooLong) => {
                let _ = out_lock(&out).local(b"510 ombra-filter: line too long\r\n");
                log!("ombra-torctl-filter: {peer} refused: line too long");
                break;
            }
            Err(_) => break,
            Ok(_) => {}
        }
        let Some(text) = std::str::from_utf8(&line).ok() else {
            break;
        };
        let cmd = torctl::chomp(text);
        if cmd.is_empty() {
            continue;
        }
        let (verb, rest) = verb_split(cmd);
        let forward: Option<String> = if verb == "ADD_ONION" {
            let rewritten = peer_ip
                .filter(|_| onion_adds < torctl::MAX_ADD_ONION)
                .and_then(|ip| torctl::add_onion_rewrite(rest, ip));
            match rewritten {
                Some(f) => {
                    onion_adds += 1;
                    log!("ombra-torctl-filter: {peer} ADD_ONION accepted");
                    Some(f)
                }
                None => {
                    log!("ombra-torctl-filter: {peer} ADD_ONION refused");
                    None
                }
            }
        } else if verb == "SETEVENTS" {
            // always forwarded, possibly bare: tor replaces its whole set, so an old subscription never lingers
            match torctl::setevents_plan(rest) {
                Some(f) => Some(f),
                None => {
                    log!(
                        "ombra-torctl-filter: {peer} command refused: {}",
                        torctl::loggable(cmd)
                    );
                    None
                }
            }
        } else if torctl::is_gateway_state_query(cmd, true) {
            // answered from the gateway's state files; tor never sees the key
            let reply = torctl::GatewayState::read().getinfo_reply();
            if out_lock(&out).local(reply.as_bytes()).is_err() {
                break;
            }
            continue;
        } else if let Some(reply) = torctl::stub_reply(cmd, true) {
            if out_lock(&out).local(reply.as_bytes()).is_err() {
                break;
            }
            continue;
        } else if let Some(rebuilt) = torctl::rebuilt_forward(cmd) {
            Some(rebuilt)
        } else {
            log!(
                "ombra-torctl-filter: {peer} command refused: {}",
                torctl::loggable(cmd)
            );
            None
        };
        let Some(forward) = forward else {
            let refusal = format!("{}\r\n", torctl::refusal(cmd, true));
            if out_lock(&out).local(refusal.as_bytes()).is_err() {
                break;
            }
            continue;
        };
        // the slot is reserved before the bytes leave, so the reply can never overtake it
        if !out_lock(&out).expect_upstream() {
            break;
        }
        if upstream_writer
            .write_all(format!("{forward}\r\n").as_bytes())
            .is_err()
        {
            break;
        }
        if verb == "QUIT" {
            quit = true;
            break;
        }
    }
    if quit {
        // tor answers QUIT and closes; the downstream thread delivers that answer, then closes the client
        let _ = upstream_writer.shutdown(std::net::Shutdown::Write);
    } else {
        let _ = upstream_writer.shutdown(std::net::Shutdown::Both);
    }
    let _ = downstream.join();
    let _ = client.shutdown(std::net::Shutdown::Both);
}

/// The one writer to the client. `pending` holds, in command order, `None` for a line tor still has to answer
/// and `Some(bytes)` for a local answer that must wait behind it.
struct ClientOut {
    stream: TcpStream,
    pending: VecDeque<Option<Vec<u8>>>,
}

impl ClientOut {
    fn expect_upstream(&mut self) -> bool {
        if self.pending.len() >= MAX_PENDING {
            return false;
        }
        self.pending.push_back(None);
        true
    }

    fn local(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if self.pending.is_empty() {
            self.stream.write_all(bytes)
        } else if self.pending.len() >= MAX_PENDING {
            Err(std::io::Error::other("too many requests queued behind an unanswered one"))
        } else {
            self.pending.push_back(Some(bytes.to_vec()));
            Ok(())
        }
    }

    fn deliver(&mut self, lines: Vec<torctl::DownLine>) -> std::io::Result<()> {
        for l in lines {
            self.stream.write_all(&l.bytes)?;
            if l.ends_reply && matches!(self.pending.front(), Some(None)) {
                self.pending.pop_front();
                while let Some(Some(_)) = self.pending.front() {
                    if let Some(Some(bytes)) = self.pending.pop_front() {
                        self.stream.write_all(&bytes)?;
                    }
                }
            }
        }
        Ok(())
    }
}

/// Shuts both sockets of a session when dropped.
struct ShutdownGuard(TcpStream, TcpStream);

impl Drop for ShutdownGuard {
    fn drop(&mut self) {
        let _ = self.0.shutdown(std::net::Shutdown::Both);
        let _ = self.1.shutdown(std::net::Shutdown::Both);
    }
}

fn out_lock(out: &Mutex<ClientOut>) -> std::sync::MutexGuard<'_, ClientOut> {
    out.lock().unwrap_or_else(|p| p.into_inner())
}

fn verb_split(line: &str) -> (&str, &str) {
    match line.split_once(' ') {
        Some((v, rest)) => (v, rest.trim()),
        None => (line.trim(), ""),
    }
}

/// Authenticate to tor upstream with the real control cookie; the read is bounded, then unbounded again for the session.
fn upstream_auth(upstream: &TcpStream, cookie_hex: &str) -> Result<(), String> {
    upstream
        .set_read_timeout(Some(UPSTREAM_AUTH_TIMEOUT))
        .map_err(|e| e.to_string())?;
    let mut w = try_clone(upstream);
    w.write_all(format!("AUTHENTICATE {cookie_hex}\r\n").as_bytes())
        .map_err(|e| e.to_string())?;
    drop(w);
    let mut r = BufReader::new(try_clone(upstream));
    let mut reply = String::new();
    r.read_line(&mut reply).map_err(|e| e.to_string())?;
    // the session's reply thread blocks on upstream for as long as tor stays up
    upstream.set_read_timeout(None).map_err(|e| e.to_string())?;
    if reply.starts_with("250") {
        Ok(())
    } else {
        Err(format!("tor said {}", reply.trim()))
    }
}

fn try_clone(s: &TcpStream) -> TcpStream {
    s.try_clone().expect("tcp try_clone")
}

fn refuse_close(mut client: TcpStream, msg: &str) {
    log!("ombra-torctl-filter: {msg}");
    let _ = client.write_all(format!("{msg}\r\n").as_bytes());
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    /// Stand-in control port: answers the first line 250 OK and holds the socket open.
    fn spawn_fake_upstream() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut line = String::new();
                    let _ = reader.read_line(&mut line);
                    let mut w = stream;
                    let _ = w.write_all(b"250 OK\r\n");
                    thread::sleep(Duration::from_secs(30));
                });
            }
        });
        addr
    }

    fn test_cfg(upstream: SocketAddr) -> (Config, PathBuf) {
        let cookie = std::env::temp_dir().join(format!(
            "ombra-filter-test-{}-{}.cookie",
            std::process::id(),
            upstream.port()
        ));
        std::fs::write(&cookie, b"\xde\xad\xbe\xef").unwrap();
        let cfg = Config {
            listen: String::new(),
            upstream: upstream.to_string(),
            cookie_file: cookie.clone(),
            client_cookie_hex: "deadbeef".into(),
        };
        (cfg, cookie)
    }

    fn spawn_filtered_listener(cfg: Config, limits: Limits) -> SocketAddr {
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = server.local_addr().unwrap();
        thread::spawn(move || {
            let pool = Arc::new(ConnectionPool::default());
            for stream in server.incoming().flatten() {
                handle_incoming(&pool, stream, &cfg, limits);
            }
        });
        addr
    }

    fn read_all(client: &mut TcpStream) -> Vec<u8> {
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut buf = Vec::new();
        let _ = client.read_to_end(&mut buf);
        buf
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn silent_pre_auth_clients_are_dropped_at_the_timeout() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let limits = Limits {
            auth_timeout: Duration::from_millis(250),
            ..Limits::production()
        };
        let addr = spawn_filtered_listener(cfg, limits);
        let mut client = TcpStream::connect(addr).unwrap();
        let start = std::time::Instant::now();
        assert_eq!(
            read_all(&mut client).len(),
            0,
            "a silent client must be closed, never answered"
        );
        let elapsed = start.elapsed();
        assert!(
            elapsed >= Duration::from_millis(200),
            "dropped before the timeout fired: {elapsed:?}"
        );
        assert!(
            elapsed < Duration::from_secs(4),
            "the bound did not apply: {elapsed:?}"
        );
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn production_sessions_stay_open_while_idle() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let addr = spawn_filtered_listener(cfg, Limits::production());
        let mut c = TcpStream::connect(addr).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        c.write_all(b"AUTHENTICATE\r\n").unwrap();
        let mut buf = [0u8; 64];
        let n = c.read(&mut buf).unwrap();
        assert!(contains(&buf[..n], b"250"));
        thread::sleep(Duration::from_millis(600));
        c.set_read_timeout(Some(Duration::from_millis(300)))
            .unwrap();
        match c.read(&mut buf) {
            Ok(0) => panic!("the session was closed for being idle"),
            Ok(_) => {}
            Err(e) => assert!(
                matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ),
                "{e}"
            ),
        }
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn idle_authenticated_sessions_are_closed_and_free_their_slot() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let limits = Limits {
            idle_timeout: Some(Duration::from_millis(250)),
            max_connections: 1,
            ..Limits::production()
        };
        let addr = spawn_filtered_listener(cfg, limits);
        let mut idle = TcpStream::connect(addr).unwrap();
        idle.write_all(b"AUTHENTICATE\r\n").unwrap();
        let start = std::time::Instant::now();
        let reply = read_all(&mut idle);
        assert!(
            contains(&reply, b"250 OK"),
            "{:?}",
            String::from_utf8_lossy(&reply)
        );
        assert!(
            start.elapsed() < Duration::from_secs(4),
            "idle session was not closed"
        );
        thread::sleep(Duration::from_millis(200));
        let mut next = TcpStream::connect(addr).unwrap();
        next.write_all(b"AUTHENTICATE\r\n").unwrap();
        let mut buf = [0u8; 16];
        next.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let n = next.read(&mut buf).unwrap();
        assert!(contains(&buf[..n], b"250"), "slot was not freed");
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn overlong_lines_are_refused_and_closed() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let addr = spawn_filtered_listener(cfg, Limits::production());
        let mut client = TcpStream::connect(addr).unwrap();
        let junk = vec![b'a'; torctl::MAX_LINE_BYTES + 256];
        client.write_all(&junk).unwrap();
        let reply = read_all(&mut client);
        assert!(
            contains(&reply, b"510"),
            "expected the 510 refusal, got {:?}",
            String::from_utf8_lossy(&reply)
        );
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn sessions_beyond_the_cap_are_refused_and_live_ones_survive() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let limits = Limits {
            max_connections: 1,
            ..Limits::production()
        };
        let addr = spawn_filtered_listener(cfg, limits);
        let mut first = TcpStream::connect(addr).unwrap();
        first
            .set_read_timeout(Some(Duration::from_millis(300)))
            .unwrap();
        thread::sleep(Duration::from_millis(300));
        let mut second = TcpStream::connect(addr).unwrap();
        let reply = read_all(&mut second);
        assert!(
            contains(&reply, b"551"),
            "expected the 551 cap refusal, got {:?}",
            String::from_utf8_lossy(&reply)
        );
        let mut one = [0u8; 1];
        assert!(
            first.read(&mut one).is_err(),
            "the admitted session must survive the cap refusal"
        );
        std::fs::remove_file(cookie).ok();
    }

    /// Stand-in control port that answers like tor: auth, a slow GETINFO, and QUIT that closes.
    fn spawn_slow_upstream() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut w = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).is_ok_and(|n| n > 0) {
                        let reply: &[u8] = if line.starts_with("AUTHENTICATE") {
                            b"250 OK\r\n"
                        } else if line.starts_with("GETINFO") {
                            thread::sleep(Duration::from_millis(300));
                            b"250-version=0.4.9.0\r\n250 OK\r\n"
                        } else if line == "SETEVENTS\r\n" {
                            b"250 OK\r\n"
                        } else if line == "SETEVENTS HS_DESC\r\n" {
                            b"250 OK HS_DESC\r\n"
                        } else if line.starts_with("QUIT") {
                            let _ = w.write_all(b"250 closing connection\r\n");
                            return;
                        } else {
                            b"510 unexpected\r\n"
                        };
                        let _ = w.write_all(reply);
                        line.clear();
                    }
                });
            }
        });
        addr
    }

    #[test]
    fn local_answers_wait_behind_earlier_forwarded_commands() {
        let (cfg, cookie) = test_cfg(spawn_slow_upstream());
        let addr = spawn_filtered_listener(cfg, Limits::production());
        let mut c = TcpStream::connect(addr).unwrap();
        c.write_all(
            b"AUTHENTICATE\r\nGETINFO version\r\nSETEVENTS CIRC\r\nSIGNAL NEWNYM\r\nQUIT\r\n",
        )
        .unwrap();
        let got = String::from_utf8(read_all(&mut c)).unwrap();
        assert_eq!(
            got,
            "250 OK\r\n250-version=0.4.9.0\r\n250 OK\r\n250 OK\r\n510 ombra-filter: command not in the read-only dialect\r\n250 closing connection\r\n"
        );
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn every_setevents_reaches_tor_so_its_set_is_replaced() {
        let (cfg, cookie) = test_cfg(spawn_slow_upstream());
        let addr = spawn_filtered_listener(cfg, Limits::production());
        let mut c = TcpStream::connect(addr).unwrap();
        c.write_all(
            b"AUTHENTICATE\r\nGETINFO version\r\nSETEVENTS CIRC HS_DESC\r\nSETEVENTS ORCONN\r\nSETEVENTS SIGNAL CONF_CHANGED\r\nSETEVENTS\r\nQUIT\r\n",
        )
        .unwrap();
        let got = String::from_utf8(read_all(&mut c)).unwrap();
        // the stub-only and bare lines go up bare; the refused one is answered locally, in order
        assert_eq!(
            got,
            "250 OK\r\n250-version=0.4.9.0\r\n250 OK\r\n250 OK HS_DESC\r\n510 ombra-filter: command not in the read-only dialect\r\n250 OK\r\n250 OK\r\n250 closing connection\r\n"
        );
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn refused_lines_cannot_stretch_the_pre_auth_deadline() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let limits = Limits {
            auth_timeout: Duration::from_millis(500),
            ..Limits::production()
        };
        let addr = spawn_filtered_listener(cfg, limits);
        let mut c = TcpStream::connect(addr).unwrap();
        let mut w = c.try_clone().unwrap();
        thread::spawn(move || {
            for _ in 0..40 {
                if w.write_all(b"GETINFO version\r\n").is_err() {
                    return;
                }
                thread::sleep(Duration::from_millis(100));
            }
        });
        let start = Instant::now();
        let reply = read_all(&mut c);
        let elapsed = start.elapsed();
        assert!(contains(&reply, b"authenticate first"));
        assert!(
            elapsed < Duration::from_millis(2500),
            "a chatty pre-auth client outlived the deadline: {elapsed:?}"
        );
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn a_client_that_never_reads_is_cut_off_and_frees_its_slot() {
        let (cfg, cookie) = test_cfg(spawn_fake_upstream());
        let limits = Limits {
            write_timeout: Duration::from_millis(200),
            max_connections: 1,
            ..Limits::production()
        };
        let addr = spawn_filtered_listener(cfg, limits);
        let stuck = TcpStream::connect(addr).unwrap();
        let mut w = stuck.try_clone().unwrap();
        // every PROTOCOLINFO is answered locally (and not logged); never reading them fills the socket buffers
        let writer = thread::spawn(move || {
            let _ = w.write_all(b"AUTHENTICATE\r\n");
            let burst = b"PROTOCOLINFO\r\n".repeat(4096);
            let start = Instant::now();
            while start.elapsed() < Duration::from_secs(20) {
                if w.write_all(&burst).is_err() {
                    return true;
                }
            }
            false
        });
        assert!(writer.join().unwrap(), "the stuck session was never closed");
        let start = Instant::now();
        loop {
            let mut next = TcpStream::connect(addr).unwrap();
            next.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let _ = next.write_all(b"AUTHENTICATE\r\n");
            let mut buf = [0u8; 64];
            let n = next.read(&mut buf).unwrap_or(0);
            if contains(&buf[..n], b"250") {
                break;
            }
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "slot was not freed: {:?}",
                String::from_utf8_lossy(&buf[..n])
            );
            thread::sleep(Duration::from_millis(100));
        }
        drop(stuck);
        std::fs::remove_file(cookie).ok();
    }

    #[test]
    fn a_repeat_authenticate_is_answered_locally() {
        let (cfg, cookie) = test_cfg(spawn_slow_upstream());
        let addr = spawn_filtered_listener(cfg, Limits::production());
        let mut c = TcpStream::connect(addr).unwrap();
        c.write_all(b"AUTHENTICATE\r\nAUTHENTICATE \"x\"\r\nQUIT\r\n")
            .unwrap();
        let got = String::from_utf8(read_all(&mut c)).unwrap();
        assert_eq!(got, "250 OK\r\n250 OK\r\n250 closing connection\r\n");
        std::fs::remove_file(cookie).ok();
    }
}
