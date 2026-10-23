//! systemd ask-password protocol client: KEY=VALUE `.ask` files answered over a unix socket or a legacy fifo line.

use std::fs;
use std::io::Write;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use zeroize::Zeroize;

pub const ASK_PASSWORD_DIR: &str = "/run/systemd/ask-password";

/// Bound so a dead listener cannot hang the agent.
pub const ANSWER_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskRequest {
    pub path: PathBuf,
    pub id: String,
    pub message: String,
    pub socket: PathBuf,
}

impl AskRequest {
    /// systemd-cryptsetup's volume request: `Id=cryptsetup:...` or its "passphrase for disk" message.
    pub fn is_disk_unlock(&self) -> bool {
        self.id.starts_with("cryptsetup:")
            || self
                .message
                .to_ascii_lowercase()
                .contains("passphrase for disk")
    }
}

/// Returns None when there is no `Socket=` line (unanswerable).
pub fn parse_ask(text: &str, path: &Path) -> Option<AskRequest> {
    let mut socket = None;
    let mut message = None;
    let mut name = None;
    let mut id = None;
    for line in text.lines() {
        let line = line.trim_end();
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "Socket" => socket = Some(PathBuf::from(value)),
                "Message" => message = Some(value.to_string()),
                "Name" => name = Some(value.to_string()),
                "Id" => id = Some(value.to_string()),
                _ => {} // NotAfter=, PID=, ... not needed here
            }
        }
    }
    let socket = socket?;
    let id = id.or_else(|| path.file_stem()?.to_str().map(str::to_string))?;
    let message = message.or(name).unwrap_or_default();
    Some(AskRequest {
        path: path.to_path_buf(),
        id,
        message,
        socket,
    })
}

/// All answerable requests in `dir`, oldest first; a missing directory is an empty set.
pub fn scan(dir: &Path) -> Result<Vec<AskRequest>> {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("scanning {}", dir.display())),
    };
    let mut out = Vec::new();
    for entry in entries {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        if path.extension().map(|e| e == "ask").unwrap_or(false) {
            if let Ok(text) = fs::read_to_string(&path) {
                if let Some(req) = parse_ask(&text, &path) {
                    out.push(req);
                }
            }
        }
    }
    out.sort_by(|a, b| a.path.file_name().cmp(&b.path.file_name()));
    Ok(out)
}

pub fn write_answer(socket: &Path, password: &[u8]) -> Result<()> {
    let meta =
        fs::metadata(socket).with_context(|| format!("answer channel {}", socket.display()))?;
    let to_socket = meta.file_type().is_socket();
    let mut frame = packet_for_channel(to_socket, password);
    let sent = write_channel_bounded(socket, to_socket, &frame);
    // frame holds the passphrase; scrub it
    frame.zeroize();
    sent
}

/// Exact bytes a channel expects: socket `'+' + password + '\0'`, fifo `password + '\n'` (systemd's listener drops anything else).
fn packet_for_channel(to_socket: bool, password: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(password.len() + 2);
    if to_socket {
        frame.push(b'+');
        frame.extend_from_slice(password);
        frame.push(0);
    } else {
        frame.extend_from_slice(password);
        frame.push(b'\n');
    }
    frame
}

/// Bounded: a fifo with no reader or a full socket queue must not hang the agent.
fn write_channel_bounded(path: &Path, to_socket: bool, frame: &[u8]) -> Result<()> {
    let target = path.to_path_buf();
    let payload = frame.to_vec();
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("askpass-answer".into())
        .spawn(move || {
            let res = (|| -> std::io::Result<()> {
                if to_socket {
                    let sock = UnixDatagram::unbound()?;
                    sock.send_to(&payload, &target)?;
                } else {
                    let mut f = fs::OpenOptions::new().write(true).open(&target)?;
                    f.write_all(&payload)?;
                    f.flush()?;
                }
                Ok(())
            })();
            let _ = tx.send(res);
        })
        .map_err(|e| anyhow!("spawning answer writer: {e}"))?;
    match rx.recv_timeout(ANSWER_TIMEOUT) {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(anyhow!("answer to {}: {e}", path.display())),
        Err(_) => bail!("no listener took the answer from {}", path.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn tempdir(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("ombra-askpass-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    const FIXTURE: &str = "\
Name=Please enter disk passphrase
Message=Please enter passphrase for disk ombra (nvme0n1p3)!
Socket=/run/systemd/ask-password/sck.29217
NotAfter=0
PID=412
";

    #[test]
    fn parses_real_format_ask_file() {
        let path = PathBuf::from("/run/systemd/ask-password/u0000000101.ask");
        let req = parse_ask(FIXTURE, &path).expect("parses");
        assert_eq!(
            req.socket,
            PathBuf::from("/run/systemd/ask-password/sck.29217")
        );
        assert_eq!(
            req.message,
            "Please enter passphrase for disk ombra (nvme0n1p3)!"
        );
        assert_eq!(req.id, "u0000000101");
        assert_eq!(req.path, path);
    }

    #[test]
    fn id_line_wins_over_stem_and_no_socket_means_unanswerable() {
        let with_id = "Id=disk-1\nSocket=/run/sck.1\n";
        let p = Path::new("/run/systemd/ask-password/u7.ask");
        let req = parse_ask(with_id, p).unwrap();
        assert_eq!(req.id, "disk-1");

        assert!(parse_ask("Message=no channel here\n", p).is_none());
    }

    #[test]
    fn only_the_volume_request_counts_as_a_disk_unlock() {
        let p = Path::new("/run/systemd/ask-password/ask.X.ask");
        let disk = parse_ask(FIXTURE, p).unwrap();
        assert!(disk.is_disk_unlock());
        let by_id = parse_ask(
            "Id=cryptsetup:/dev/sda3\nMessage=Enter key\nSocket=/run/s\n",
            p,
        )
        .unwrap();
        assert!(by_id.is_disk_unlock());
        let other =
            parse_ask("Id=sudo:1\nMessage=Password for admin:\nSocket=/run/s\n", p).unwrap();
        assert!(!other.is_disk_unlock());
        let bare = parse_ask("Socket=/run/s\n", p).unwrap();
        assert!(!bare.is_disk_unlock());
    }

    #[test]
    fn scan_sorts_oldest_first_and_ignores_non_ask_files() {
        let dir = tempdir("scan");
        fs::write(dir.join("u0000000002.ask"), "Socket=/run/sck.b\n").unwrap();
        fs::write(dir.join("u0000000001.ask"), "Socket=/run/sck.a\n").unwrap();
        fs::write(dir.join("README"), "not a request").unwrap();
        let reqs = scan(&dir).unwrap();
        assert_eq!(reqs.len(), 2);
        assert_eq!(reqs[0].socket, PathBuf::from("/run/sck.a"));
        assert_eq!(reqs[1].socket, PathBuf::from("/run/sck.b"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_missing_directory_is_empty() {
        let dir = tempdir("missing");
        fs::remove_dir_all(&dir).unwrap();
        assert!(scan(&dir).unwrap().is_empty());
    }

    #[test]
    fn answer_is_the_plus_framed_datagram_to_a_socket_channel() {
        // AF_UNIX paths are capped (~104B on macOS): keep this under /tmp.
        let dir =
            PathBuf::from("/tmp").join(format!("ombra-askpass-test-sock-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let sock_path = dir.join("sck.9");
        let listener = UnixDatagram::bind(&sock_path).unwrap();

        write_answer(&sock_path, b"my-secret").unwrap();
        let mut buf = [0u8; 128];
        let n = listener.recv(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"+my-secret\0");
        assert_eq!(buf[0], b'+');
        assert_eq!(buf[n - 1], 0);
        assert!(!buf[..n].contains(&b'\n'));

        write_answer(&sock_path, b"").unwrap();
        let n = listener.recv(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"+\0");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Legacy fifo channel keeps the line protocol (password + '\n').
    #[test]
    fn answer_reaches_a_fifo_reader_exactly_one_line() {
        let dir = tempdir("fifo");
        let fifo = dir.join("sck.1");
        assert!(std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .expect("mkfifo")
            .success());

        let rpath = fifo.clone();
        let reader = std::thread::spawn(move || {
            let mut f = fs::File::open(&rpath).unwrap();
            let mut got = String::new();
            f.read_to_string(&mut got).unwrap();
            got
        });
        // let the reader open its end first
        std::thread::sleep(std::time::Duration::from_millis(50));
        write_answer(&fifo, b"my-secret").unwrap();
        assert_eq!(reader.join().unwrap(), "my-secret\n");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn fifo_with_no_listener_times_out_instead_of_hanging() {
        let dir = tempdir("nolistener");
        let fifo = dir.join("sck.2");
        assert!(std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success());
        let res = write_answer(&fifo, b"nobody-there");
        assert!(res.is_err(), "expected a timeout error, got {res:?}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn socket_packets_are_plus_framed_and_fifo_packets_are_lines() {
        assert_eq!(packet_for_channel(true, b"abc"), b"+abc\0".to_vec());
        assert_eq!(packet_for_channel(false, b"abc"), b"abc\n".to_vec());
        assert_eq!(packet_for_channel(true, b""), b"+\0".to_vec());
        assert_eq!(packet_for_channel(false, b""), b"\n".to_vec());
    }
}
