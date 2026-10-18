//! ombra-welcome — first-use setup on tty1, before the login manager; sets exactly two secrets. Ctrl-C is ignored.

use std::process::ExitCode;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyEventKind};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use ombra_boot::fb::{self, UiBackend};
use ombra_boot::term;
use ombra_boot::welcome::{self, DiskState, Welcome};
use ombra_boot::{theme, BUILD_PASSPHRASE};

const POLL: Duration = Duration::from_millis(80);
const RESTART_NOTICE: Duration = Duration::from_millis(1500);

fn main() -> ExitCode {
    term::install_panic_hook();
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--probe") {
        // both probe answers are success: the marker FILE is the signal
        return match welcome::probe_build_key() {
            Ok(_) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("ombra-welcome --probe: {e:#}");
                ExitCode::FAILURE
            }
        };
    }
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ombra-welcome: {e:#}");
            draw_fatal(&e);
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let _raw = term::RawGuard::new().context("raw mode (need the boot tty)")?;
    let tty = term::TtyHandle::open().context("opening the boot tty")?;
    let tty_fd = tty.raw_fd();
    let (backend, (rows, cols)) = fb::open_backend(tty, "ombra-welcome").context("drawing backend on the boot tty")?;
    let mut grid = (rows, cols);
    let area = ratatui::layout::Rect::new(0, 0, cols, rows);
    let mut terminal = Terminal::with_options(
        backend,
        ratatui::TerminalOptions { viewport: ratatui::Viewport::Fixed(area) },
    )
    .context("terminal backend on the boot tty")?;
    terminal.clear().context("clearing the console")?;

    let mut app = if welcome::amnesic_boot_now() {
        Welcome::needs_persistent()
    } else {
        match welcome::startup_state() {
            Ok(DiskState::Reencrypting) => Welcome::resuming(),
            _ => Welcome::new(),
        }
    };
    let mut last_pulse = Instant::now();
    let mut last_caret = Instant::now();
    terminal.draw(|f| welcome::draw(f, &app)).context("drawing")?;

    loop {
        // the viewport is fixed at the startup grid; a Fusion resize changes the console grid under us
        if let Some((rows, cols)) = term::console_grid(tty_fd) {
            if (rows, cols) != grid {
                grid = (rows, cols);
                let live = ratatui::layout::Rect::new(0, 0, cols, rows);
                terminal.resize(live).context("resizing")?;
            }
        }
        if event::poll(POLL)? {
            if let Event::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press {
                    // re-arm the caret blink on every keystroke
                    last_caret = Instant::now();
                    match app.on_key(k) {
                        welcome::Action::StartApply => {
                            apply(&mut terminal, &mut app, tty_fd, &mut grid, false)?
                        }
                        welcome::Action::StartResume => {
                            apply(&mut terminal, &mut app, tty_fd, &mut grid, true)?
                        }
                        welcome::Action::Restart => {
                            app.begin_restart();
                            terminal.draw(|f| welcome::draw(f, &app)).context("drawing")?;
                            return restart(&mut terminal, &app);
                        }
                        welcome::Action::None => {}
                    }
                }
            }
        }
        if last_pulse.elapsed() >= Duration::from_millis(theme::PULSE_MS) {
            app.tick_pulse();
            last_pulse = Instant::now();
        }
        // caret blink: its own timer; any keypress re-arms it
        if last_caret.elapsed() >= Duration::from_millis(theme::CARET_BLINK_MS) {
            app.tick_caret();
            last_caret = Instant::now();
        }
        terminal.draw(|f| welcome::draw(f, &app)).context("drawing")?;
    }
}

/// Runs the real applier on a worker thread while the loop animates.
fn apply(
    terminal: &mut Terminal<UiBackend>,
    app: &mut Welcome,
    tty_fd: std::os::unix::io::RawFd,
    grid: &mut (u16, u16),
    resume: bool,
) -> Result<()> {
    let secrets = if resume {
        app.resume_secret().map(|p| (p.clone(), p))
    } else {
        app.secrets()
    };
    let (disk, user) = secrets.context("internal: secrets missing at apply time")?;
    app.begin_apply();
    terminal.draw(|f| welcome::draw(f, app))?;

    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::Builder::new()
        .name("ombra-apply".into())
        .spawn(move || {
            let mut applier = welcome::SystemApplier;
            let result = if resume {
                welcome::run_resume(&mut applier, &disk)
            } else {
                welcome::run_apply(&mut applier, BUILD_PASSPHRASE.as_bytes(), &disk, &user)
            };
            let _ = tx.send(result.err().map(|e| format!("{e:#}")));
        })
        .context("spawning the apply worker")?;

    loop {
        match rx.recv_timeout(Duration::from_millis(120)) {
            Ok(None) => break,
            Ok(Some(detail)) => {
                app.apply_failed(&brief(&detail));
                return Ok(());
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                app.tick_pulse();
                if let Some((rows, cols)) = term::console_grid(tty_fd) {
                    if (rows, cols) != *grid {
                        *grid = (rows, cols);
                        let live = ratatui::layout::Rect::new(0, 0, cols, rows);
                        terminal.resize(live).context("resizing")?;
                    }
                }
                terminal.draw(|f| welcome::draw(f, app))?;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                app.apply_failed("the setup step stopped unexpectedly");
                return Ok(());
            }
        }
    }

    app.apply_succeeded();
    terminal.draw(|f| welcome::draw(f, app))?;
    std::thread::sleep(RESTART_NOTICE);
    restart(terminal, app)
}

fn restart(
    terminal: &mut Terminal<UiBackend>,
    app: &Welcome,
) -> Result<()> {
    // if reboot fails, fall through to the forced reboot
    if let Err(e) = welcome::reboot() {
        eprintln!("ombra-welcome: {e:#}");
    }

    std::thread::sleep(Duration::from_secs(15));
    let _ = std::process::Command::new("reboot")
        .arg("-f")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    loop {
        std::thread::sleep(POLL);
        terminal.draw(|f| welcome::draw(f, app))?;
    }
}

fn brief(detail: &str) -> String {
    let line: String = detail.chars().take(70).collect();
    if detail.chars().count() > 70 {
        format!("{line}...")
    } else {
        line
    }
}

/// Best-effort static error frame; the unit is Restart=on-failure.
fn draw_fatal(e: &anyhow::Error) {
    let Ok(mut writer) = term::open_writer() else { return };
    let Ok(_raw) = term::RawGuard::new() else { return };
    if term::enter_screen(writer.as_mut()).is_err() {
        return;
    }
    if let Ok(mut terminal) = Terminal::new(CrosstermBackend::new(writer.as_mut())) {
        let _ = terminal.draw(|f| {
            use ombra_boot::art;
            let l = theme::layout(f.area());
            f.render_widget(art::Ring::for_console(f.area().height), l.ring);
            theme::put_wordmark(f, l.brand, theme::FIELD_WIDTH);
            theme::put_centered(f, l.title, "something went wrong", theme::fg(theme::BAD));
            let detail = theme::truncate(&format!("{e:#}"), 70);
            theme::put_centered(f, l.content, &detail, theme::fg(theme::MUTED));
            theme::put_centered(
                f,
                l.footer,
                "please restart the machine and try again",
                theme::fg(theme::MUTED),
            );
        });
        std::thread::sleep(Duration::from_secs(2));
    }
    let _ = term::leave_screen(writer.as_mut());
}
