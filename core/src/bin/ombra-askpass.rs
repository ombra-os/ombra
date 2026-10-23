//! ombra-askpass — the branded disk-unlock face. `--keyscript [prompt]`:
//! the cryptroot transport; the passphrase goes to stdout as EXACT bytes, no trailing newline.

use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use crossterm::event::KeyEvent;
use crossterm::terminal::disable_raw_mode;
use ratatui::backend::CrosstermBackend;
use ratatui::{Frame, Terminal};

use ombra_boot::askpass::{self, AskRequest};
use ombra_boot::fb::{self, UiBackend};
use ombra_boot::input::{byte_to_key, FieldEvent, KeyReader, SecretBuf, SecretField, Severity};
use ombra_boot::keyscript;
use ombra_boot::term;
use ombra_boot::{art, theme, BUILD_PASSPHRASE};

/// A quiet window this long after an answer means the disk opened.
const GRACE: Duration = Duration::from_secs(2);
/// An unconsumed build-key answer falls through to the manual unlock.
const BUILD_TRY_TIMEOUT: Duration = Duration::from_secs(15);
const POLL: Duration = Duration::from_millis(80);
enum Mode {
    Splash,
    Unlock,
}

struct Agent {
    mode: Mode,
    /// Single entry — an unlock never re-confirms.
    field: SecretField,
    pending: Option<SecretBuf>,
    build_tried: Option<PathBuf>,
    build_since: Instant,
    answered: Option<(PathBuf, Instant)>,
    retry: Option<String>,
    feedback: Option<&'static str>,
    pulse: usize,
    /// Caret blink phase; only painted while the field is empty.
    caret_phase: bool,
}

impl Agent {
    fn new() -> Self {
        Agent {
            mode: Mode::Splash,
            field: SecretField::new("passphrase"),
            pending: None,
            build_tried: None,
            build_since: Instant::now(),
            answered: None,
            retry: None,
            feedback: None,
            pulse: 0,
            caret_phase: true,
        }
    }
}

/// True only on cryptsetup's definitive "no key matches" (exit 2); anything else keeps the build-key offer.
fn build_key_is_dead() -> bool {
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let Some(source) = std::env::var_os("CRYPTTAB_SOURCE").and_then(|s| s.into_string().ok())
    else {
        return false;
    };
    let device = match source.strip_prefix("UUID=") {
        Some(uuid) => format!("/dev/disk/by-uuid/{uuid}"),
        None => source,
    };
    if !std::path::Path::new(&device).exists() {
        return false;
    }
    let Ok(mut child) = Command::new("cryptsetup")
        .args(["open", "--test-passphrase", "--key-file", "-", &device])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(BUILD_PASSPHRASE.as_bytes());
    }
    matches!(child.wait().map(|s| s.code()), Ok(Some(2)))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let keyscript_mode =
        keyscript::is_keyscript_invocation(&args, std::env::var_os("CRYPTTAB_NAME").is_some());
    // keyscript stdout IS the key channel: the panic restore must never touch it
    if keyscript_mode {
        term::install_panic_hook_with(|| {
            if let Some(mut w) = term::open_writer_tty() {
                let _ = term::leave_screen(w.as_mut());
            }
            let _ = disable_raw_mode();
        });
    } else {
        term::install_panic_hook();
    }
    if keyscript_mode {
        return match keyscript_main(&args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("ombra-askpass (keyscript): {e:#}");
                ExitCode::FAILURE
            }
        };
    }
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ombra-askpass: {e:#}");
            draw_fatal(&e);
            ExitCode::FAILURE
        }
    }
}

// ---- agent mode ----

fn run() -> Result<()> {
    let _marker = term::MarkerGuard::new(term::ASKPASS_LIVE_MARKER);

    // the console is taken only while a request exists
    let mut agent = Agent::new();
    let mut screen: Option<Terminal<UiBackend>> = None;
    let mut screen_fd: Option<std::os::unix::io::RawFd> = None;
    let mut grid: Option<(u16, u16)> = None;
    let mut reader: Option<KeyReader<std::fs::File>> = None;
    let mut last_scan = Instant::now();
    let mut last_caret = Instant::now();

    loop {
        // batch drain: byte-at-a-time would cap typing at the poll rate
        if let (Some(keys), true) = (reader.as_mut(), screen.is_some()) {
            match keys.drain_available() {
                Ok(pressed) => {
                    // typing re-arms the blink
                    last_caret = Instant::now();
                    agent.caret_phase = true;
                    agent.field.set_caret(true);
                    for k in pressed {
                        on_key(&mut agent, k);
                    }
                }
                Err(_) => {} // dead reader: back to the poll cadence
            }
        }

        if last_scan.elapsed() >= POLL {
            last_scan = Instant::now();
            let mut requests = askpass::scan(Path::new(askpass::ASK_PASSWORD_DIR))?;
            requests.retain(AskRequest::is_disk_unlock);
            if screen.is_none() && !requests.is_empty() {
                let tty = term::TtyHandle::open().context("opening the boot tty")?;
                let fd = tty.raw_fd();
                let keys = KeyReader::from_tty(&tty);
                let (backend, (rows, cols)) = fb::open_backend(tty, "ombra-askpass")
                    .context("drawing backend on the boot tty")?;
                screen_fd = Some(fd);
                grid = Some((rows, cols));
                let area = ratatui::layout::Rect::new(0, 0, cols, rows);
                let mut t = Terminal::with_options(
                    backend,
                    ratatui::TerminalOptions {
                        viewport: ratatui::Viewport::Fixed(area),
                    },
                )
                .context("terminal backend on the boot tty")?;
                t.clear().context("clearing the console")?;
                reader = Some(keys);
                screen = Some(t);
            }
            // a Fusion resize changes the console grid under the fixed viewport
            if let (Some(terminal), Some(fd)) = (screen.as_mut(), screen_fd) {
                if let Some((rows, cols)) = term::console_grid(fd) {
                    if Some((rows, cols)) != grid {
                        grid = Some((rows, cols));
                        let live = ratatui::layout::Rect::new(0, 0, cols, rows);
                        terminal.resize(live).context("resizing")?;
                    }
                }
            }
            // caret blink, on its own timer
            if screen.is_some()
                && last_caret.elapsed() >= Duration::from_millis(theme::CARET_BLINK_MS)
            {
                agent.caret_phase = !agent.caret_phase;
                agent.field.set_caret(agent.caret_phase);
                last_caret = Instant::now();
                if let Some(terminal) = screen.as_mut() {
                    terminal
                        .draw(|f| draw(f, &agent))
                        .context("drawing the unlock screen")?;
                }
            }
            if let Some(terminal) = screen.as_mut() {
                terminal
                    .draw(|f| draw(f, &agent))
                    .context("drawing the decrypt screen")?;
            }
            match step(&mut agent, &requests)? {
                StepOutcome::Continue => {}
                StepOutcome::Unlocked => {
                    if let Some(mut terminal) = screen.take() {
                        term::leave_screen(terminal.backend_mut()).ok();
                    }
                    reader = None;
                    screen_fd = None;
                    grid = None;
                    agent = Agent::new();
                    screen = None;
                }
            }
        } else {
            std::thread::sleep(Duration::from_millis(40));
        }
    }
}

enum StepOutcome {
    Continue,
    Unlocked,
}

fn step(agent: &mut Agent, requests: &[AskRequest]) -> Result<StepOutcome> {
    match agent.mode {
        Mode::Splash => {
            // silently answer the oldest request with the build key
            if agent.build_tried.is_none() {
                if let Some(req) = requests.first() {
                    askpass::write_answer(&req.socket, BUILD_PASSPHRASE.as_bytes())
                        .context("trying the build passphrase")?;
                    agent.build_tried = Some(req.path.clone());
                    agent.build_since = Instant::now();
                }
                return Ok(StepOutcome::Continue);
            }
            let tried = agent.build_tried.clone().expect("checked above");
            let still_there = requests.iter().any(|r| r.path == tried);
            let newer = requests.iter().any(|r| r.path != tried);
            if newer {
                // fresh request post-rotation: manual unlock screen
                agent.mode = Mode::Unlock;
            } else if !still_there {
                if agent.build_since.elapsed() >= GRACE {
                    return Ok(StepOutcome::Unlocked);
                }
            } else if agent.build_since.elapsed() >= BUILD_TRY_TIMEOUT {
                agent.mode = Mode::Unlock;
            }
            Ok(StepOutcome::Continue)
        }
        Mode::Unlock => {
            if let Some(secret) = agent.pending.take() {
                if let Some(req) = requests.first() {
                    let send = askpass::write_answer(&req.socket, secret.as_bytes());
                    drop(secret); // SecretBuf's Drop zeroizes its copy
                    send.context("sending the disk passphrase")?;
                    agent.answered = Some((req.path.clone(), Instant::now()));
                } else {
                    // no request yet: hold the answer for the next poll
                    agent.pending = Some(secret);
                }
            }
            if let Some((path, since)) = agent.answered.clone() {
                let wrong = requests.iter().any(|r| r.path != path);
                if wrong {
                    agent.retry = Some("that passphrase didn't decrypt - try again".to_string());
                    agent.field.clear();
                    agent.answered = None;
                } else if requests.is_empty() && since.elapsed() >= GRACE {
                    return Ok(StepOutcome::Unlocked);
                }
            }
            Ok(StepOutcome::Continue)
        }
    }
}

fn on_key(agent: &mut Agent, k: KeyEvent) {
    // the splash has no input path; Ctrl-C is ignored on purpose
    if !matches!(agent.mode, Mode::Unlock) {
        return;
    }
    match agent.field.handle_key(k) {
        FieldEvent::Submitted => {
            // the field's value IS the answer
            agent.pending = Some(SecretBuf::new(agent.field.take()));
            agent.retry = None;
            agent.feedback = None;
        }
        FieldEvent::TooShort => agent.feedback = Some(keyscript::TOO_SHORT_MESSAGE),
        FieldEvent::Edited => agent.feedback = None,
        FieldEvent::Ignored => {}
    }
}

// ---- shared frames ----

fn draw_chrome(f: &mut Frame, title: &str) -> theme::ScreenLayout {
    let area = f.area();
    let l = theme::layout(area);
    f.render_widget(
        art::Ring::for_console(l.ring.height.max(area.height.min(40))),
        l.ring,
    );
    theme::put_wordmark(f, l.brand, theme::FIELD_WIDTH);
    theme::put_centered(f, l.title, title, theme::fg(theme::LABEL));
    l
}

fn splash_frame(f: &mut Frame, pulse: usize) {
    let l = draw_chrome(f, "starting your private machine");
    let pulse_chars: [char; 6] = [' ', '.', 'o', 'O', 'o', '.'];
    let dot = pulse_chars[pulse % pulse_chars.len()].to_string();
    theme::put_centered(
        f,
        theme::row_in(l.content, 1),
        &dot,
        theme::fg(theme::RING_DIM),
    );
}

fn unlock_frame(f: &mut Frame, field: &SecretField, message: Option<(&str, Severity)>) {
    // WHITE title aligned to the input box edge
    let l = draw_chrome(f, "");
    let c = l.content;
    let field_rect = theme::center_horiz(c, theme::FIELD_WIDTH, 3);
    theme::put_left(
        f,
        theme::line_rect(c, field_rect.x, c.y),
        "enter your passphrase to decrypt your disk",
        theme::fg(theme::TEXT),
    );
    let box1 = ratatui::layout::Rect {
        x: field_rect.x,
        y: c.y + 1,
        width: field_rect.width,
        height: 3,
    };
    f.render_widget(field, box1);
    let mut row = c.y + 4;
    if let Some((msg, sev)) = message {
        let color = match sev {
            Severity::Bad => theme::BAD,
            Severity::Muted => theme::MUTED,
        };
        let msg = theme::truncate(msg, field_rect.width as usize);
        theme::put_left(
            f,
            theme::line_rect(c, field_rect.x, row),
            &msg,
            theme::fg(color),
        );
        row += 1;
    }
    theme::put_left(
        f,
        theme::line_rect(c, field_rect.x, row),
        "your passphrase never leaves this machine",
        theme::fg(theme::LABEL),
    );
    theme::put_hints(f, l.footer, &[("enter", "unlock")]);
}

fn draw(f: &mut Frame, agent: &Agent) {
    match agent.mode {
        Mode::Splash => splash_frame(f, agent.pulse),
        Mode::Unlock => {
            let message = agent
                .feedback
                .map(|m| (m, Severity::Bad))
                .or_else(|| agent.retry.as_deref().map(|m| (m, Severity::Bad)));
            unlock_frame(f, &agent.field, message);
        }
    }
}

// ---- keyscript mode ----

struct KeyscriptTty {
    terminal: Terminal<UiBackend>,
    /// The boot tty's fd, kept out for grid probes (a resize changes the console grid under a fixed viewport).
    fd: std::os::unix::io::RawFd,
    /// Grid this terminal was built for: Terminal::size() is a live backend query, not the viewport.
    grid: (u16, u16),
    /// Keyboard bytes from the tty fd WE opened — never crossterm's (no controlling tty under cryptroot).
    keys: KeyReader<std::fs::File>,
}

impl KeyscriptTty {
    /// Fixed-viewport terminal; raw mode comes from TtyHandle.
    fn new() -> Option<Self> {
        let tty = term::TtyHandle::open()?;
        let fd = tty.raw_fd();
        let keys = KeyReader::from_tty(&tty);
        let (backend, (rows, cols)) = fb::open_backend(tty, "ombra-askpass").ok()?;
        let area = ratatui::layout::Rect::new(0, 0, cols, rows);
        let mut terminal = Terminal::with_options(
            backend,
            ratatui::TerminalOptions {
                viewport: ratatui::Viewport::Fixed(area),
            },
        )
        .ok()?;
        terminal.clear().ok()?;
        Some(KeyscriptTty {
            terminal,
            fd,
            grid: (rows, cols),
            keys,
        })
    }

    fn refollow(&mut self) {
        if let Some((rows, cols)) = term::console_grid(self.fd) {
            if (rows, cols) != self.grid {
                self.grid = (rows, cols);
                let live = ratatui::layout::Rect::new(0, 0, cols, rows);
                let _ = self.terminal.resize(live);
            }
        }
    }
}

impl keyscript::KeyscriptUi for KeyscriptTty {
    fn draw_splash(&mut self, pulse: usize) {
        self.refollow();
        let _ = self.terminal.draw(|f| splash_frame(f, pulse));
    }

    fn draw_unlock(&mut self, field: &SecretField, message: Option<(&str, Severity)>) {
        self.refollow();
        let _ = self.terminal.draw(|f| unlock_frame(f, field, message));
    }

    fn next_key(&mut self) -> io::Result<Option<KeyEvent>> {
        // bounded wait; a silent tty yields None at the poll tick
        self.keys
            .next_key(Duration::from_millis(theme::KEY_POLL_MS))
    }

    fn tick_wait(&mut self, d: Duration) {
        std::thread::sleep(d);
    }
}

fn keyscript_main(args: &[String]) -> Result<()> {
    // the prompt is consumed but never displayed (branded copy only)
    let _prompt = keyscript::prompt_from_args(args).or_else(drain_prompt_from_stdin);

    let marker = keyscript::marker_path(std::env::var("CRYPTTAB_NAME").ok().as_deref());

    // terminal setup can fail on initramfs console topologies: the headless UI still answers the keyscript contract
    let tui = KeyscriptTty::new();
    let mut out = io::stdout().lock();
    match tui {
        Some(ui) => keyscript::run(
            &mut out,
            &marker,
            &mut { ui },
            BUILD_PASSPHRASE,
            keyscript::SPLASH,
            &mut build_key_is_dead,
        )?,
        None => keyscript::run(
            &mut out,
            &marker,
            &mut HeadlessUi::new(),
            BUILD_PASSPHRASE,
            keyscript::SPLASH,
            &mut build_key_is_dead,
        )?,
    }
    // NO leave_screen: the alt screen must survive cryptroot's re-invocations
    Ok(())
}

/// Plain-text unlock fallback when no terminal backend can be built; stdin is cryptroot's pipe, never user input.
struct HeadlessUi {
    tty: Option<std::fs::File>,
    /// Termios as found, restored on Drop.
    saved_termios: Option<libc::termios>,
}

impl HeadlessUi {
    fn new() -> Self {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut tty = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(0o400000) // O_NOCTTY on Linux
            .open("/dev/tty1")
            .or_else(|_| {
                std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open("/dev/tty")
            })
            .ok();
        let mut saved_termios = None;
        if let Some(f) = tty.as_ref() {
            use std::os::unix::io::AsRawFd as _;
            // ECHO off or no tty at all: a tty that cannot hide the passphrase is never read
            unsafe {
                let mut t: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(f.as_raw_fd(), &mut t) == 0 {
                    let mut quiet = t;
                    quiet.c_lflag &= !(libc::ECHO | libc::ECHONL);
                    if libc::tcsetattr(f.as_raw_fd(), libc::TCSANOW, &quiet) == 0 {
                        saved_termios = Some(t);
                    }
                }
            }
        }
        if saved_termios.is_none() {
            tty = None;
        }
        HeadlessUi { tty, saved_termios }
    }
}

impl Drop for HeadlessUi {
    fn drop(&mut self) {
        if let (Some(f), Some(t)) = (self.tty.as_ref(), self.saved_termios.take()) {
            use std::os::unix::io::AsRawFd as _;
            unsafe {
                libc::tcsetattr(f.as_raw_fd(), libc::TCSANOW, &t);
            }
        }
    }
}

impl keyscript::KeyscriptUi for HeadlessUi {
    fn draw_splash(&mut self, _pulse: usize) {}
    fn draw_unlock(&mut self, field: &SecretField, _message: Option<(&str, Severity)>) {
        if let Some(tty) = self.tty.as_mut() {
            let bullets = "*".repeat(field.value().len());
            let _ = writeln!(tty, "\r\n  OMBRA  decrypt your disk: {bullets}");
            let _ = tty.flush();
        }
    }
    fn next_key(&mut self) -> io::Result<Option<KeyEvent>> {
        // no tty: sleep so the loop draws without spinning
        let Some(tty) = self.tty.as_mut() else {
            std::thread::sleep(Duration::from_millis(200));
            return Ok(None);
        };
        let mut b = [0u8; 1];
        let n = tty.read(&mut b)?;
        if n == 0 {
            std::thread::sleep(Duration::from_millis(200));
            return Ok(None);
        }
        Ok(byte_to_key(b[0]))
    }
    fn tick_wait(&mut self, d: Duration) {
        std::thread::sleep(d);
    }
}

/// Bounded stdin drain, only reached when argv carried NO prompt and stdin is not a tty (a drain would swallow keystrokes).
fn drain_prompt_from_stdin() -> Option<String> {
    if unsafe { libc::isatty(0) } == 1 {
        return None;
    }
    let (tx, rx) = mpsc::channel();
    let reader = std::thread::Builder::new()
        .name("keyscript-prompt".into())
        .spawn(move || {
            let mut buf = [0u8; 256];
            if let Ok(n) = io::stdin().read(&mut buf) {
                if n > 0 {
                    let _ = tx.send(String::from_utf8_lossy(&buf[..n]).trim().to_string());
                }
            }
        });
    reader
        .ok()
        .and_then(|_| rx.recv_timeout(Duration::from_millis(500)).ok())
}

/// Best-effort static error frame; the stock fallback agent covers the front door.
fn draw_fatal(e: &anyhow::Error) {
    let Ok(mut writer) = term::open_writer() else {
        return;
    };
    let Ok(_raw) = term::RawGuard::new() else {
        return;
    };
    if term::enter_screen(writer.as_mut()).is_err() {
        return;
    }
    if let Ok(mut terminal) = Terminal::new(CrosstermBackend::new(writer.as_mut())) {
        let _ = terminal.draw(|f| {
            let l = theme::layout(f.area());
            f.render_widget(art::Ring::for_console(f.area().height), l.ring);
            theme::put_wordmark(f, l.brand, theme::FIELD_WIDTH);
            theme::put_centered(f, l.title, "something went wrong", theme::fg(theme::BAD));
            let detail = theme::truncate(&format!("{e:#}"), 70);
            theme::put_centered(
                f,
                theme::row_in(l.content, 1),
                &detail,
                theme::fg(theme::MUTED),
            );
            theme::put_centered(
                f,
                l.footer,
                "continuing with the stock prompt",
                theme::fg(theme::MUTED),
            );
        });
        std::thread::sleep(Duration::from_secs(2));
    }
    let _ = term::leave_screen(writer.as_mut());
}
