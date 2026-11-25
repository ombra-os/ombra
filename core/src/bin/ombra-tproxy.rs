//! ombra-tproxy — the desktop's transparent proxy (logic and rationale: `ombra_boot::tproxy`).
//! Two loopback listeners, fed by the desktop firewall's redirects: a UDP DNS stub and a TCP port. Every accepted TCP
//! connection becomes one SOCKS5 CONNECT to the gateway's Tor. No configuration files, nothing written, nothing logged
//! about names or destinations.
//!
//! The two sockets come from systemd (ombra-tproxy.socket), which holds the ports for as long as the machine runs: if
//! this program stops, no other program can take them and receive everyone's redirected traffic. `--dns`/`--tcp` bind
//! them here instead, for tests.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4, TcpListener, TcpStream, UdpSocket};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::process::ExitCode;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use ombra_boot::tproxy::{self, NameTable, Target};

const USAGE: &str = "\
ombra-tproxy — transparent proxy for the Ombra desktop

usage: ombra-tproxy [--dns ADDR:PORT] [--tcp ADDR:PORT] [--socks ADDR:PORT]

  --dns     bind the UDP DNS stub here instead of taking it from systemd (127.0.0.1:5399 in ombra-tproxy.socket)
  --tcp     bind the transparent TCP port here instead of taking it from systemd (127.0.0.1:9041)
  --socks   the gateway's Tor SOCKS port                                 default 10.55.10.1:9050
";

/// Connections handed to Tor at once; further ones are refused until one ends. The firewall caps each user below this
/// (desktop nftables.conf), so one user cannot take every place.
const MAX_CONNECTIONS: usize = 1536;
/// After the program has finished sending (or gone away), how long Tor's side may stay silent before the stream ends.
const LINGER_AFTER_CLIENT_EOF: Duration = Duration::from_secs(120);
/// Tor answers a CONNECT when the circuit and the exit's connection are up, which can take a while.
const SOCKS_TIMEOUT: Duration = Duration::from_secs(120);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
struct Config {
    dns: Option<String>,
    tcp: Option<String>,
    socks: SocketAddr,
}

fn parse_args<I: Iterator<Item = String>>(mut args: I) -> Result<Config, String> {
    let mut cfg = Config {
        dns: None,
        tcp: None,
        socks: "10.55.10.1:9050".parse().expect("default socks address"),
    };
    while let Some(a) = args.next() {
        let mut val = || args.next().ok_or_else(|| format!("{a} needs a value"));
        match a.as_str() {
            "--dns" => cfg.dns = Some(val()?),
            "--tcp" => cfg.tcp = Some(val()?),
            "--socks" => cfg.socks = val()?.parse().map_err(|_| "--socks needs ADDR:PORT".to_string())?,
            "-h" | "--help" => return Err(String::new()),
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(cfg)
}

fn main() -> ExitCode {
    let cfg = match parse_args(std::env::args().skip(1)) {
        Ok(c) => c,
        Err(e) if e.is_empty() => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("ombra-tproxy: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let (dns, tcp) = match (&cfg.dns, &cfg.tcp) {
        (Some(d), Some(t)) => match (UdpSocket::bind(d), TcpListener::bind(t)) {
            (Ok(d), Ok(t)) => (d, t),
            _ => {
                eprintln!("ombra-tproxy: cannot bind {d} (udp) and {t} (tcp)");
                return ExitCode::FAILURE;
            }
        },
        (None, None) => match inherited_sockets() {
            Some(pair) => pair,
            None => {
                eprintln!("ombra-tproxy: no sockets from systemd (start ombra-tproxy.socket, or pass --dns and --tcp)");
                return ExitCode::FAILURE;
            }
        },
        _ => {
            eprintln!("ombra-tproxy: --dns and --tcp go together\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    eprintln!("ombra-tproxy: DNS stub and TCP port ready, SOCKS to {}", cfg.socks);
    let started = Instant::now();
    let table = Arc::new(Mutex::new(NameTable::default()));
    {
        let table = Arc::clone(&table);
        if thread::Builder::new()
            .name("dns".into())
            .spawn(move || {
                dns_loop(&dns, &table, started);
                // name resolution is gone: leave, so systemd starts a fresh process on the sockets it still holds
                std::process::exit(1);
            })
            .is_err()
        {
            eprintln!("ombra-tproxy: cannot start the DNS thread");
            return ExitCode::FAILURE;
        }
    }
    let active = Arc::new(AtomicUsize::new(0));
    for conn in tcp.incoming() {
        let Ok(client) = conn else { continue };
        if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            active.fetch_sub(1, Ordering::SeqCst);
            continue; // dropped: the client sees a reset
        }
        let table = Arc::clone(&table);
        let active2 = Arc::clone(&active);
        let socks = cfg.socks;
        let spawned = thread::Builder::new().name("conn".into()).spawn(move || {
            serve(client, &table, socks, started);
            active2.fetch_sub(1, Ordering::SeqCst);
        });
        if spawned.is_err() {
            active.fetch_sub(1, Ordering::SeqCst);
        }
    }
    ExitCode::SUCCESS
}

fn lock(table: &Mutex<NameTable>) -> std::sync::MutexGuard<'_, NameTable> {
    table.lock().unwrap_or_else(|e| e.into_inner())
}

/// The two sockets systemd passes (LISTEN_FDS=2 from ombra-tproxy.socket), told apart by their type.
fn inherited_sockets() -> Option<(UdpSocket, TcpListener)> {
    let pid: u32 = std::env::var("LISTEN_PID").ok()?.parse().ok()?;
    let n: i32 = std::env::var("LISTEN_FDS").ok()?.parse().ok()?;
    if pid != std::process::id() || n != 2 {
        return None;
    }
    let (mut dns, mut tcp) = (None, None);
    for fd in 3..5 {
        let mut kind: libc::c_int = 0;
        let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        // SAFETY: `kind` and `len` are valid for the call and sized as SO_TYPE expects; fd is only inspected.
        let rc = unsafe {
            libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_TYPE, (&mut kind as *mut libc::c_int).cast(), &mut len)
        };
        if rc != 0 {
            return None;
        }
        // SAFETY: systemd handed this process fds 3 and 4 (LISTEN_PID is ours, LISTEN_FDS is 2); each is wrapped once,
        // as the socket type the kernel just reported for it, and owned from here on.
        unsafe {
            match kind {
                libc::SOCK_DGRAM if dns.is_none() => dns = Some(UdpSocket::from_raw_fd(fd)),
                libc::SOCK_STREAM if tcp.is_none() => tcp = Some(TcpListener::from_raw_fd(fd)),
                _ => return None,
            }
        }
    }
    let (dns, tcp) = (dns?, tcp?);
    dns.set_nonblocking(false).ok()?;
    tcp.set_nonblocking(false).ok()?;
    Some((dns, tcp))
}

fn dns_loop(sock: &UdpSocket, table: &Mutex<NameTable>, started: Instant) {
    let mut buf = [0u8; 1500];
    let mut errors = 0u32;
    loop {
        let Ok((n, peer)) = sock.recv_from(&mut buf) else {
            // a socket that only ever fails is not coming back
            errors += 1;
            if errors > 200 {
                return;
            }
            thread::sleep(Duration::from_millis(50));
            continue;
        };
        errors = 0;
        // only this machine asks (the firewall lets nothing else in; this is the second statement of it)
        if !peer.ip().is_loopback() && !is_local_peer(&peer) {
            continue;
        }
        let reply = tproxy::answer(&buf[..n], &mut lock(table), started.elapsed().as_secs());
        if let Some(reply) = reply {
            let _ = sock.send_to(&reply, peer);
        }
    }
}

/// A redirected query keeps the source address of the interface it would have left through (10.55.10.x).
fn is_local_peer(peer: &SocketAddr) -> bool {
    match peer {
        SocketAddr::V4(a) => {
            let o = a.ip().octets();
            o[0] == 10 && o[1] == 55 && o[2] == 10
        }
        SocketAddr::V6(_) => false,
    }
}

/// The address the client dialled before the firewall redirected the connection here (SO_ORIGINAL_DST).
fn original_dst(stream: &TcpStream) -> Option<SocketAddrV4> {
    const SOL_IP: libc::c_int = 0;
    const SO_ORIGINAL_DST: libc::c_int = 80;
    // SAFETY: getsockopt writes at most `len` bytes into `addr`, a properly sized and aligned sockaddr_in that lives
    // for the whole call; the fd is open for as long as `stream` is borrowed.
    let (rc, addr) = unsafe {
        let mut addr: libc::sockaddr_in = std::mem::zeroed();
        let mut len = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
        let rc = libc::getsockopt(
            stream.as_raw_fd(),
            SOL_IP,
            SO_ORIGINAL_DST,
            (&mut addr as *mut libc::sockaddr_in).cast(),
            &mut len,
        );
        (rc, addr)
    };
    if rc != 0 || i32::from(addr.sin_family) != libc::AF_INET {
        return None;
    }
    Some(SocketAddrV4::new(
        Ipv4Addr::from(u32::from_be(addr.sin_addr.s_addr)),
        u16::from_be(addr.sin_port),
    ))
}

fn serve(client: TcpStream, table: &Mutex<NameTable>, socks: SocketAddr, started: Instant) {
    let _ = client.set_nodelay(true);
    let Some(dst) = original_dst(&client) else {
        return;
    };
    // a connection made straight to this port, not redirected: there is nowhere to send it (and no loop to feed)
    if dst.ip().is_loopback() || dst.ip().is_unspecified() {
        return;
    }
    let Some(target) = tproxy::target_for(*dst.ip(), &mut lock(table), started.elapsed().as_secs()) else {
        return;
    };
    let Some(upstream) = open_socks(socks, &target, dst.port()) else {
        return;
    };
    relay(client, upstream);
}

fn open_socks(socks: SocketAddr, target: &Target, port: u16) -> Option<TcpStream> {
    let mut s = TcpStream::connect_timeout(&socks, CONNECT_TIMEOUT).ok()?;
    let _ = s.set_nodelay(true);
    s.set_read_timeout(Some(SOCKS_TIMEOUT)).ok()?;
    s.set_write_timeout(Some(CONNECT_TIMEOUT)).ok()?;
    s.write_all(&tproxy::SOCKS_GREETING).ok()?;
    let mut two = [0u8; 2];
    s.read_exact(&mut two).ok()?;
    if two != tproxy::SOCKS_GREETING_OK {
        return None;
    }
    s.write_all(&tproxy::socks_connect(target, port)).ok()?;
    let mut head = [0u8; 4];
    s.read_exact(&mut head).ok()?;
    let mut rest = tproxy::socks_reply_head(head).ok()?;
    if head[3] == 3 {
        let mut len = [0u8; 1];
        s.read_exact(&mut len).ok()?;
        rest = usize::from(len[0]) + 2;
    }
    let mut skip = [0u8; 258];
    s.read_exact(&mut skip[..rest]).ok()?;
    s.set_read_timeout(None).ok()?;
    s.set_write_timeout(None).ok()?;
    Some(s)
}

/// Copy both ways. Tor ends a stream when its client side closes, so a program's half-close is NOT passed on: when the
/// program stops sending, Tor's side gets `LINGER_AFTER_CLIENT_EOF` of silence at most to finish its answer. When Tor's
/// side ends, both directions end at once, so no program can keep a place here by never closing.
fn relay(client: TcpStream, upstream: TcpStream) {
    let (Ok(c_read), Ok(u_write), Ok(u_ctl)) = (client.try_clone(), upstream.try_clone(), upstream.try_clone()) else {
        return;
    };
    let up = thread::Builder::new().name("relay-up".into()).spawn(move || {
        copy(c_read, u_write);
        // the program is done sending: Tor's side may still be answering, but not forever
        let _ = u_ctl.set_read_timeout(Some(LINGER_AFTER_CLIENT_EOF));
    });
    let Ok(c_ctl) = client.try_clone() else { return };
    copy(upstream, client);
    // Tor's side is finished (or timed out): stop reading from the program too, which ends the other thread
    let _ = c_ctl.shutdown(Shutdown::Both);
    if let Ok(h) = up {
        let _ = h.join();
    }
}

fn copy(mut from: TcpStream, mut to: TcpStream) {
    let mut buf = [0u8; 16 * 1024];
    loop {
        match from.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Config, String> {
        parse_args(list.iter().map(|s| s.to_string()))
    }

    #[test]
    fn defaults_and_overrides() {
        let c = args(&[]).unwrap();
        assert!(c.dns.is_none() && c.tcp.is_none(), "by default the sockets come from systemd");
        assert_eq!(c.socks.to_string(), "10.55.10.1:9050");
        let c = args(&["--dns", "127.0.0.1:1", "--tcp", "127.0.0.1:2", "--socks", "127.0.0.1:3"]).unwrap();
        assert_eq!((c.dns.as_deref(), c.tcp.as_deref(), c.socks.port()), (Some("127.0.0.1:1"), Some("127.0.0.1:2"), 3));
        assert!(args(&["--socks"]).is_err());
        assert!(args(&["--socks", "gateway"]).is_err());
        assert!(args(&["--bogus"]).is_err());
        assert_eq!(args(&["--help"]).unwrap_err(), "");
    }

    /// A stand-in for Tor's SOCKS port: checks the greeting, records the CONNECT request, answers success, then echoes.
    fn fake_socks() -> (SocketAddr, std::sync::mpsc::Receiver<Vec<u8>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            for s in l.incoming() {
                let mut s = s.unwrap();
                let tx = tx.clone();
                thread::spawn(move || {
                    let mut g = [0u8; 3];
                    s.read_exact(&mut g).unwrap();
                    assert_eq!(g, tproxy::SOCKS_GREETING);
                    s.write_all(&[5, 0]).unwrap();
                    let mut h = [0u8; 4];
                    s.read_exact(&mut h).unwrap();
                    let mut req = h.to_vec();
                    let more = match h[3] {
                        1 => 6,
                        3 => {
                            let mut n = [0u8; 1];
                            s.read_exact(&mut n).unwrap();
                            req.push(n[0]);
                            usize::from(n[0]) + 2
                        }
                        _ => panic!("unexpected address type"),
                    };
                    let mut rest = vec![0u8; more];
                    s.read_exact(&mut rest).unwrap();
                    req.extend_from_slice(&rest);
                    tx.send(req).unwrap();
                    s.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
                    let mut buf = [0u8; 256];
                    while let Ok(n) = s.read(&mut buf) {
                        if n == 0 {
                            break;
                        }
                        s.write_all(&buf[..n]).unwrap();
                    }
                });
            }
        });
        (addr, rx)
    }

    #[test]
    fn a_name_goes_to_tor_as_a_name_and_bytes_flow_both_ways() {
        let (socks, rx) = fake_socks();
        let mut up = open_socks(socks, &Target::Name("example.com".into()), 22).expect("socks handshake");
        assert_eq!(rx.recv().unwrap(), [&[5u8, 1, 0, 3, 11][..], b"example.com", &[0, 22]].concat());
        up.write_all(b"hello").unwrap();
        let mut back = [0u8; 5];
        up.read_exact(&mut back).unwrap();
        assert_eq!(&back, b"hello");
    }

    #[test]
    fn a_literal_address_goes_to_tor_as_an_address() {
        let (socks, rx) = fake_socks();
        let _up = open_socks(socks, &Target::Addr(Ipv4Addr::new(1, 2, 3, 4)), 443).expect("socks handshake");
        assert_eq!(rx.recv().unwrap(), vec![5, 1, 0, 1, 1, 2, 3, 4, 1, 187]);
    }

    #[test]
    fn a_refusing_proxy_ends_the_connection() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut g = [0u8; 3];
            s.read_exact(&mut g).unwrap();
            s.write_all(&[5, 0]).unwrap();
            let mut req = [0u8; 10];
            s.read_exact(&mut req).unwrap();
            s.write_all(&[5, 4, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap(); // host unreachable
        });
        assert!(open_socks(addr, &Target::Addr(Ipv4Addr::new(1, 2, 3, 4)), 80).is_none());
    }

    #[test]
    fn the_relay_passes_data_and_ends_both_ways_when_tors_side_ends() {
        // a stand-in for Tor that answers, then closes its side first
        let tor = TcpListener::bind("127.0.0.1:0").unwrap();
        let tor_addr = tor.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = tor.accept().unwrap();
            let mut b = [0u8; 4];
            s.read_exact(&mut b).unwrap();
            s.write_all(b"pong").unwrap();
        });
        let front = TcpListener::bind("127.0.0.1:0").unwrap();
        let front_addr = front.local_addr().unwrap();
        let done = thread::spawn(move || {
            let (client, _) = front.accept().unwrap();
            relay(client, TcpStream::connect(tor_addr).unwrap());
        });
        let mut c = TcpStream::connect(front_addr).unwrap();
        c.write_all(b"ping").unwrap();
        let mut back = [0u8; 4];
        c.read_exact(&mut back).unwrap();
        assert_eq!(&back, b"pong");
        // the program never closes; the relay still ends, because Tor's side did
        let mut rest = Vec::new();
        c.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        c.read_to_end(&mut rest).unwrap();
        assert!(rest.is_empty());
        done.join().unwrap();
    }

    #[test]
    fn a_programs_half_close_is_not_passed_to_tor() {
        // Tor ends the stream when its client closes; a program that sends, half-closes and waits must still get its answer
        let tor = TcpListener::bind("127.0.0.1:0").unwrap();
        let tor_addr = tor.local_addr().unwrap();
        thread::spawn(move || {
            let (mut s, _) = tor.accept().unwrap();
            let mut b = [0u8; 4];
            s.read_exact(&mut b).unwrap();
            // if the half-close had been forwarded, this read would return 0 at once
            s.set_read_timeout(Some(Duration::from_millis(400))).unwrap();
            let mut probe = [0u8; 1];
            let early_eof = matches!(s.read(&mut probe), Ok(0));
            s.write_all(if early_eof { b"EOF!" } else { b"late" }).unwrap();
        });
        let front = TcpListener::bind("127.0.0.1:0").unwrap();
        let front_addr = front.local_addr().unwrap();
        thread::spawn(move || {
            let (client, _) = front.accept().unwrap();
            relay(client, TcpStream::connect(tor_addr).unwrap());
        });
        let mut c = TcpStream::connect(front_addr).unwrap();
        c.write_all(b"ping").unwrap();
        c.shutdown(Shutdown::Write).unwrap();
        let mut back = Vec::new();
        c.read_to_end(&mut back).unwrap();
        assert_eq!(back, b"late");
    }

    #[test]
    fn a_connection_that_was_not_redirected_has_no_original_destination_to_follow() {
        // on Linux a plain loopback connection reports its own address, which `serve` refuses; elsewhere the option
        // does not exist and the lookup fails. Either way nothing is proxied.
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let _c = TcpStream::connect(addr).unwrap();
        let (s, _) = l.accept().unwrap();
        if let Some(d) = original_dst(&s) {
            assert!(d.ip().is_loopback());
        }
    }
}
