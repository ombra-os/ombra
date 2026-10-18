//! Control-port bouncer: forwards only the read-only dialect (crate::torctl);
//! no client-supplied byte is ever logged; pre-auth clients are timed out and the session count is capped.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use ombra_boot::torctl;

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
    idle_timeout: Option<Duration>,
    line_cap: usize,
    max_connections: usize,
}

impl Limits {
    fn production() -> Self {
        Limits {
            auth_timeout: Duration::from_secs(torctl::AUTH_TIMEOUT_SECS),
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

fn main() -> ExitCode {
    let mut cfg = Config {
        listen: "10.55.10.1:9052".into(),
        upstream: "127.0.0.1:9051".into(),
        cookie_file: PathBuf::from("/var/lib/tor/control_auth_cookie"),
        client_cookie_hex: torctl::CLIENT_COOKIE_HEX.to_string(),
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut val = || args.next().unwrap_or_else(|| die(&USAGE));
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
    eprintln!(
        "ombra-torctl-filter: listening on {} -> {} (read-only dialect)",
        cfg.listen, cfg.upstream
    );
    let pool = Arc::new(ConnectionPool::default());
    for stream in listener.incoming().flatten() {
        handle_incoming(&pool, stream, &cfg, Limits::production());
    }
    ExitCode::SUCCESS
}

fn die(msg: &str) -> ! {
    eprintln!("ombra-torctl-filter: {msg}");
    std::process::exit(2);
}

/// Cap-check + spawn; shared with the tests that pin the cap.
fn handle_incoming(pool: &Arc<ConnectionPool>, stream: TcpStream, cfg: &Config, limits: Limits) {
    if !pool.acquire(limits.max_connections) {
        let mut stream = stream;
        let _ = stream.write_all(b"551 ombra-filter: too many connections\r\n");
        eprintln!(
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
    thread::spawn(move || {
        let _session = session;
        serve(stream, &cfg, &limits);
    });
}

/// One connection: client handshake, upstream cookie auth, then filter client lines up and pass upstream bytes down raw.
fn serve(client: TcpStream, cfg: &Config, limits: &Limits) {
    let peer = client
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "?".into());
    let mut client = client;
    let _ = client.set_nodelay(true);
    // pre-auth reads are bounded; the session lifts the bound once the cookie lands
    let _ = client.set_read_timeout(Some(limits.auth_timeout));

    let upstream = match TcpStream::connect(&cfg.upstream) {
        Ok(s) => s,
        Err(e) => return refuse_close(client, &format!("551 ombra-filter: tor control unreachable ({e})")),
    };
    let _ = upstream.set_nodelay(true);
    let cookie = match std::fs::read(&cfg.cookie_file) {
        Ok(c) if !c.is_empty() => hex_encode(&c),
        _ => return refuse_close(client, "551 ombra-filter: cannot read tor control cookie"),
    };
    if let Err(e) = upstream_auth(&upstream, &cookie) {
        return refuse_close(client, &format!("551 ombra-filter: upstream auth failed ({e})"));
    }
    let mut upstream_writer = try_clone(&upstream);

    let mut reader = BufReader::new(try_clone(&client));
    let mut line: Vec<u8> = Vec::new();
        // break = authenticated; return = client gone, stalled, or failed the cookie
    loop {
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
                let _ = upstream_writer.write_all(&line);
                return;
            }
            "PROTOCOLINFO" => {
                let _ = upstream_writer.write_all(&line);
            }
            "AUTHENTICATE" => {
                if torctl::client_auth_ok(cmd) {
                    // the client never learns the upstream cookie; this 250 is ours, not tor's
                    let _ = client.write_all(b"250 OK\r\n");
                    eprintln!("ombra-torctl-filter: {peer} authenticated");
                    break;
                }
                let _ = client.write_all(b"515 ombra-filter: authentication failed\r\n");
                eprintln!("ombra-torctl-filter: {peer} bad cookie");
                return;
            }
            _ => {
                let _ = client.write_all(format!("{}\r\n", torctl::refusal(cmd, false)).as_bytes());
                eprintln!("ombra-torctl-filter: {peer} command refused");
            }
        }
    }

    let _ = client.set_read_timeout(limits.idle_timeout);
    let to_client = try_clone(&client);
    thread::spawn(move || {
        let mut inp = BufReader::new(try_clone(&upstream));
        let mut out = to_client;
        let mut buf = [0u8; 4096];
        loop {
            match inp.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
    });

    loop {
        match torctl::read_line_capped(&mut reader, &mut line, limits.line_cap) {
            Err(torctl::LineReadError::TooLong) => {
                let _ = client.write_all(b"510 ombra-filter: line too long\r\n");
                eprintln!("ombra-torctl-filter: {peer} refused: line too long");
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
        let (verb, _) = verb_split(cmd);
        if !torctl::command_allowed(cmd, true) {
            let _ = client.write_all(format!("{}\r\n", torctl::refusal(cmd, true)).as_bytes());
            eprintln!("ombra-torctl-filter: {peer} command refused");
            continue;
        }
        if upstream_writer.write_all(&line).is_err() {
            break;
        }
        if verb == "QUIT" {
            break;
        }
    }
    let _ = upstream_writer.shutdown(std::net::Shutdown::Both);
    let _ = client.shutdown(std::net::Shutdown::Both);
}

fn verb_split(line: &str) -> (&str, &str) {
    match line.split_once(' ') {
        Some((v, rest)) => (v, rest.trim()),
        None => (line.trim(), ""),
    }
}

/// Authenticate to tor upstream with the real control cookie.
fn upstream_auth(upstream: &TcpStream, cookie_hex: &str) -> Result<(), String> {
    let mut w = try_clone(upstream);
    w.write_all(format!("AUTHENTICATE {cookie_hex}\r\n").as_bytes())
        .map_err(|e| e.to_string())?;
    drop(w);
    let mut r = BufReader::new(try_clone(upstream));
    let mut reply = String::new();
    r.read_line(&mut reply).map_err(|e| e.to_string())?;
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
    eprintln!("ombra-torctl-filter: {msg}");
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
        c.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
        match c.read(&mut buf) {
            Ok(0) => panic!("the session was closed for being idle"),
            Ok(_) => {}
            Err(e) => assert!(
                matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut),
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
        assert!(contains(&reply, b"250 OK"), "{:?}", String::from_utf8_lossy(&reply));
        assert!(start.elapsed() < Duration::from_secs(4), "idle session was not closed");
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
}
