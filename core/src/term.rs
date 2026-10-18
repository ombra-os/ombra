//! tty plumbing: alternate screen + full clear + hidden cursor on entry, restored on EVERY exit path (including panics).

use std::fs;
use std::io::{self, Write};
use std::process;

use crossterm::cursor::{Hide, Show};
use crossterm::ExecutableCommand;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen};

/// Liveness marker for ombra-askpass-fallback.service (holds our pid).
pub const ASKPASS_LIVE_MARKER: &str = "/run/ombra/askpass-live";

/// The Linux console's 16 palette slots, in the Ombra dusk colors.
const LINUX_PALETTE: [&str; 16] = [
    "0b0c11", "f0716b", "56d68a", "f2c260", "5f6bb8", "b48fff", "8fd6ff", "c9c8c3",
    "666973", "f0716b", "56d68a", "f2c260", "8f9bff", "b48fff", "8fd6ff", "f4f3ef",
];

/// Reprograms the console palette (ESC ] P n rrggbb); a no-op anywhere but the Linux VT.
pub fn apply_console_palette(w: &mut dyn Write) -> io::Result<()> {
    if std::env::var("TERM").map_or(true, |t| t != "linux") {
        return Ok(());
    }
    for (i, c) in LINUX_PALETTE.iter().enumerate() {
        write!(w, "\x1b]P{i:X}{c}")?;
    }
    w.flush()
}

/// Live console grid via TIOCGWINSZ; a host window resize changes it under a drawn TUI.
pub fn console_grid(fd: std::os::unix::io::RawFd) -> Option<(u16, u16)> {
    if let Some(g) = crate::fb::pixel_grid() {
        return Some(g);
    }
    let mut ws = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: ws outlives the call; the kernel only writes it.
    let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) };
    if rc < 0 || ws.ws_row == 0 || ws.ws_col == 0 {
        return None;
    }
    Some((ws.ws_row, ws.ws_col))
}

/// tty1, then /dev/tty, then stdout (dev-box fallback).
pub fn open_writer() -> io::Result<Box<dyn Write>> {
    if let Ok(f) = fs::OpenOptions::new().write(true).open("/dev/tty1") {
        return Ok(Box::new(f));
    }
    if let Ok(f) = fs::OpenOptions::new().write(true).open("/dev/tty") {
        return Ok(Box::new(f));
    }
    Ok(Box::new(io::stdout()))
}

/// A REAL tty or nothing — keyscript stdout is the key channel and must never receive drawing output.
pub fn open_writer_tty() -> Option<Box<dyn Write>> {
    if let Ok(f) = fs::OpenOptions::new().write(true).open("/dev/tty1") {
        return Some(Box::new(f));
    }
    fs::OpenOptions::new().write(true).open("/dev/tty").ok().map(|f| Box::new(f) as Box<dyn Write>)
}

/// Read-write boot-tty handle; raw mode set on this handle's OWN fd (not crossterm's controlling-tty lookup); Drop restores termios.
pub struct TtyHandle {
    file: fs::File,
    saved: Option<libc::termios>,
}

impl TtyHandle {
    pub fn open() -> Option<TtyHandle> {
        use std::os::unix::fs::OpenOptionsExt as _;
        for path in ["/dev/tty1", "/dev/tty"] {
            if let Ok(f) = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(0o400000) // O_NOCTTY: never steal a controlling tty
                .open(path)
            {
                let mut h = TtyHandle { file: f, saved: None };
                h.set_raw();
                return Some(h);
            }
        }
        None
    }

    /// The raw fd of the console we draw on (font ioctls must target the painted VT).
    pub fn raw_fd(&self) -> std::os::unix::io::RawFd {
        use std::os::unix::io::AsRawFd as _;
        self.file.as_raw_fd()
    }

    fn set_raw(&mut self) {
        use std::os::unix::io::AsRawFd as _;
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(self.file.as_raw_fd(), &mut t) == 0 {
                self.saved = Some(t);
                let mut raw = t;
                libc::cfmakeraw(&mut raw);
                libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &raw);
            }
        }
    }

    /// A FRESH nonblocking read fd — not a dup: a dup shares status flags, and O_NONBLOCK would EAGAIN every draw.
    pub fn open_reader(&self) -> Option<std::fs::File> {
        use std::os::unix::fs::OpenOptionsExt as _;
        for path in ["/dev/tty1", "/dev/tty"] {
            if let Ok(f) = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | 0o400000) // O_NONBLOCK + O_NOCTTY
                .open(path)
            {
                return Some(f);
            }
        }
        None
    }

    /// (rows, cols) via cursor-position report; 200ms budget, 80x25 fallback.
    pub fn measure(&mut self) -> (u16, u16) {
        const FALLBACK: (u16, u16) = (25, 80);
        use std::io::Write as _;
        if self.file.write_all(b"\x1b[999;999H\x1b[6n").is_err() {
            return FALLBACK;
        }
        let _ = self.file.flush();
        // raw ttys are VMIN=1: flip O_NONBLOCK for the probe window only, restore after
        use std::os::unix::io::AsRawFd as _;
        let fd = self.file.as_raw_fd();
        if set_nonblocking(fd, true).is_none() {
            return FALLBACK;
        }
        let size = cursor_size(&mut self.file, PROBE_BUDGET);
        set_nonblocking(fd, false);
        size
    }
}

pub const PROBE_BUDGET: std::time::Duration = std::time::Duration::from_millis(200);

/// Returns the previous flags so the caller can restore them.
fn set_nonblocking(fd: i32, on: bool) -> Option<i32> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            return None;
        }
        let next = if on {
            flags | libc::O_NONBLOCK
        } else {
            flags & !libc::O_NONBLOCK
        };
        if libc::fcntl(fd, libc::F_SETFL, next) < 0 {
            return None;
        }
        Some(flags)
    }
}

/// Collect the ESC[<r>;<c>R reply; silence or garbage costs only `budget`.
fn cursor_size(r: &mut dyn io::Read, budget: std::time::Duration) -> (u16, u16) {
    const FALLBACK: (u16, u16) = (25, 80);
    use std::time::{Duration, Instant};
    let start = Instant::now();
    let mut buf: Vec<u8> = Vec::with_capacity(16);
    let mut chunk = [0u8; 8];
    while start.elapsed() < budget {
        match r.read(&mut chunk) {
            Ok(0) => return FALLBACK,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if let Some(size) = parse_cursor_report(&buf) {
                    return size;
                }
                if buf.len() > 32 {
                    return FALLBACK;
                }
            }
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock
                    || e.kind() == io::ErrorKind::Interrupted =>
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return FALLBACK,
        }
    }
    FALLBACK
}

pub fn parse_cursor_report(buf: &[u8]) -> Option<(u16, u16)> {
    let s = std::str::from_utf8(buf).ok()?;
    let start = s.find("\x1b[")?;
    let rest = &s[start + 2..];
    let end = rest.find('R')?;
    let body = &rest[..end];
    let (r, c) = body.split_once(';')?;
    let rows: u16 = r.trim().parse().ok()?;
    let cols: u16 = c.trim().parse().ok()?;
    if rows > 0 && cols > 0 {
        Some((rows, cols))
    } else {
        None
    }
}

impl Drop for TtyHandle {
    fn drop(&mut self) {
        if let Some(t) = self.saved.take() {
            use std::os::unix::io::AsRawFd as _;
            unsafe {
                libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &t);
            }
        }
    }
}

impl Write for TtyHandle {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

pub struct RawGuard;

impl RawGuard {
    pub fn new() -> io::Result<Self> {
        enable_raw_mode()?;
        Ok(RawGuard)
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
    }
}

/// Alternate screen, full clear, cursor hidden.
pub fn enter_screen(w: &mut dyn Write) -> io::Result<()> {
    w.execute(EnterAlternateScreen)?;
    w.execute(Clear(ClearType::All))?;
    w.execute(Hide)?;
    Ok(())
}

pub fn leave_screen(w: &mut dyn Write) -> io::Result<()> {
    w.execute(LeaveAlternateScreen)?;
    w.execute(Clear(ClearType::All))?;
    w.execute(Show)?;
    Ok(())
}

/// Restore the console on panic; chains to the previous hook.
pub fn install_panic_hook() {
    install_panic_hook_with(|| {
        if let Ok(mut w) = open_writer() {
            let _ = leave_screen(w.as_mut());
        }
        let _ = disable_raw_mode();
    });
}

pub fn install_panic_hook_with(restore: impl Fn() + Send + Sync + 'static) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore();
        previous(info);
    }));
}

/// Creates the liveness marker; removes it on any drop (best-effort).
pub struct MarkerGuard {
    path: &'static str,
}

impl MarkerGuard {
    pub fn new(path: &'static str) -> Self {
        if let Some(p) = std::path::Path::new(path).parent() {
            let _ = fs::create_dir_all(p);
        }
        let _ = fs::write(path, format!("{}\n", process::id()));
        MarkerGuard { path }
    }
}

impl Drop for MarkerGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enter_screen_sends_alt_clear_hide_in_order() {
        let mut w: Vec<u8> = Vec::new();
        enter_screen(&mut w).unwrap();
        let s = String::from_utf8(w).unwrap();
        let alt = s.find("\x1b[?1049h").expect("alternate screen enter");
        let clear = s.find("\x1b[2J").expect("full clear");
        let hide = s.find("\x1b[?25l").expect("cursor hide");
        assert!(alt < clear && clear < hide, "sequence was: {s:?}");
    }

    #[test]
    fn leave_screen_sends_alt_off_clear_show_in_order() {
        let mut w: Vec<u8> = Vec::new();
        leave_screen(&mut w).unwrap();
        let s = String::from_utf8(w).unwrap();
        let off = s.find("\x1b[?1049l").expect("alternate screen leave");
        let clear = s.find("\x1b[2J").expect("full clear");
        let show = s.find("\x1b[?25h").expect("cursor show");
        assert!(off < clear && clear < show, "sequence was: {s:?}");
    }

    #[test]
    fn cursor_report_parses_real_console_sizes() {
        assert_eq!(parse_cursor_report(b"\x1b[50;160R"), Some((50, 160)));
        assert_eq!(parse_cursor_report(b"\x1b[25;80R"), Some((25, 80)));
        assert_eq!(parse_cursor_report(b"\x1b[30;100Rgarbage"), Some((30, 100)));
        assert_eq!(parse_cursor_report(b"\x1b[0;0R"), None);
        assert_eq!(parse_cursor_report(b"garbage"), None);
        assert_eq!(parse_cursor_report(b""), None);
    }

    #[test]
    fn size_probe_silence_costs_the_budget_never_a_hang() {
        let (mut r, _w) = pipe_pair();
        use std::os::unix::io::AsRawFd as _;
        set_nonblocking(r.as_raw_fd(), true).expect("nonblocking reader");
        let start = std::time::Instant::now();
        let size = cursor_size(&mut r, std::time::Duration::from_millis(150));
        assert_eq!(size, (25, 80));
        assert!(start.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn size_probe_parses_a_late_console_reply() {
        let (mut r, mut w) = pipe_pair();
        use std::os::unix::io::AsRawFd as _;
        set_nonblocking(r.as_raw_fd(), true).expect("nonblocking reader");
        let writer = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(30));
            use std::io::Write as _;
            w.write_all(b"\x1b[48;128R").unwrap();
        });
        assert_eq!(cursor_size(&mut r, std::time::Duration::from_secs(2)), (48, 128));
        writer.join().unwrap();
    }

    #[test]
    fn nonblocking_flip_restores_the_previous_flags() {
        let (_r, w) = pipe_pair();
        use std::os::unix::io::AsRawFd as _;
        let fd = w.as_raw_fd();
        let before = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        let saved = set_nonblocking(fd, true).expect("F_GETFL/F_SETFL");
        assert_eq!(saved, before);
        let during = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        assert_ne!(during & libc::O_NONBLOCK, 0, "probe window is nonblocking");
        set_nonblocking(fd, false);
        let after = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        assert_eq!(after & libc::O_NONBLOCK, 0, "blocking semantics restored");
        assert_eq!(after, before);
    }

    fn pipe_pair() -> (std::fs::File, std::fs::File) {
        use std::os::unix::io::FromRawFd as _;
        let mut fds = [0i32; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe");
        unsafe { (std::fs::File::from_raw_fd(fds[0]), std::fs::File::from_raw_fd(fds[1])) }
    }

    #[test]
    fn panic_hook_restores_then_chains_to_the_previous_hook() {
        use std::sync::{atomic::{AtomicBool, Ordering}, Arc};

        let restored = Arc::new(AtomicBool::new(false));
        let chained = Arc::new(AtomicBool::new(false));

        let chained_for_prev = chained.clone();
        std::panic::set_hook(Box::new(move |_| {
            chained_for_prev.store(true, Ordering::SeqCst);
        }));
        let restored_for_hook = restored.clone();
        install_panic_hook_with(move || {
            restored_for_hook.store(true, Ordering::SeqCst);
        });

        let _ = std::panic::catch_unwind(|| panic!("boom"));
        assert!(restored.load(Ordering::SeqCst), "console was not restored");
        assert!(chained.load(Ordering::SeqCst), "previous hook was dropped");
    }
}
