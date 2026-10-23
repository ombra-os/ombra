//! ombra — the desktop's connectivity face as a command; draws on the main screen so the final frame stays.

use std::io::{self, Write as _};
use std::process::ExitCode;
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::tty::IsTty as _;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::Rect;
use ratatui::Terminal;

use ombra_boot::panel::{self, ProbeRunner, Snapshot, SystemRunner};
use ombra_boot::term;

const USAGE: &str = "\
usage: ombra [--plain] [--watch]

  the desktop's connectivity face: is ALL my traffic going
  through the gateway's Tor, strictly?

  --plain   plain text instead of the panel (also automatic
            when stdout is not a terminal)
  --watch   keep the panel up, re-probing every 30s; ctrl-c quits

  always exits 0 - it is a face, not a check\
";

const WATCH_HINT: &str = "refreshing every 30s - ctrl-c to quit";
const WATCH_POLL: Duration = Duration::from_millis(100);

type Tui = Terminal<CrosstermBackend<Box<dyn io::Write>>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Tui { watch: bool },
    Plain,
    Help,
}

fn decide_mode(args: &[String], stdout_is_tty: bool) -> Mode {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        return Mode::Help;
    }
    if args.iter().any(|a| a == "--plain") || !stdout_is_tty {
        return Mode::Plain;
    }
    Mode::Tui {
        watch: args.iter().any(|a| a == "--watch"),
    }
}

fn main() -> ExitCode {
    term::install_panic_hook();
    let args: Vec<String> = std::env::args().skip(1).collect();
    match decide_mode(&args, io::stdout().is_tty()) {
        Mode::Help => println!("{USAGE}"),
        Mode::Plain => run_plain(),
        Mode::Tui { watch } => {
            if let Err(e) = run_tui(watch) {
                // no usable tty: degrade to plain text
                eprintln!("ombra: {e}; plain output instead");
                run_plain();
            }
        }
    }
    // a face, not a check: always exit 0
    ExitCode::SUCCESS
}

fn run_plain() {
    let snap = panel::collect_snapshot(&SystemRunner);
    print!("{}", panel::plain_text(&snap));
    let _ = io::stdout().flush();
}

fn run_tui(watch: bool) -> io::Result<()> {
    let _raw = term::RawGuard::new()?;
    let mut tty = term::TtyHandle::open()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no usable tty for the panel"))?;
    let (rows, cols) = tty.measure();
    let backend = CrosstermBackend::new(Box::new(tty) as Box<dyn io::Write>);
    let area = Rect::new(0, 0, cols, rows);
    let mut terminal = Terminal::with_options(
        backend,
        ratatui::TerminalOptions {
            viewport: ratatui::Viewport::Fixed(area),
        },
    )?;
    panel::enter(terminal.backend_mut())?;
    let result = session(&mut terminal, watch);
    let _ = panel::restore(terminal.backend_mut());
    result
}

fn session(terminal: &mut Tui, watch: bool) -> io::Result<()> {
    let runner: Arc<dyn ProbeRunner> = Arc::new(SystemRunner);
    let hint = if watch { Some(WATCH_HINT) } else { None };

    let mut snap = Snapshot::checking();
    draw_panel(terminal, &snap, hint)?;
    let mut rx = panel::spawn_probes(runner.clone());
    for _ in 0..3 {
        let (key, section) = recv_section(&rx)?;
        snap.apply(key, section);
        draw_panel(terminal, &snap, hint)?;
    }

    if !watch {
        return Ok(());
    }
    loop {
        if wait_or_quit(panel::WATCH_PERIOD)? {
            return Ok(());
        }
        snap = Snapshot::checking();
        draw_panel(terminal, &snap, hint)?;
        rx = panel::spawn_probes(runner.clone());
        for _ in 0..3 {
            let (key, section) = recv_section(&rx)?;
            snap.apply(key, section);
            draw_panel(terminal, &snap, hint)?;
        }
    }
}

fn draw_panel(terminal: &mut Tui, snap: &Snapshot, hint: Option<&str>) -> io::Result<()> {
    terminal.draw(|f| panel::draw(f, snap, hint)).map(|_| ())
}

fn recv_section(
    rx: &Receiver<(panel::ProbeKey, panel::Section)>,
) -> io::Result<(panel::ProbeKey, panel::Section)> {
    rx.recv().map_err(|e| {
        io::Error::new(
            io::ErrorKind::BrokenPipe,
            format!("probe thread ended: {e}"),
        )
    })
}

fn wait_or_quit(period: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + period;
    while Instant::now() < deadline {
        if event::poll(WATCH_POLL)? {
            if let Event::Key(k) = event::read()? {
                if is_quit_key(&k) {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// Ctrl-C (raw mode keeps ISIG off, so it arrives as a key event) or q.
fn is_quit_key(k: &crossterm::event::KeyEvent) -> bool {
    k.kind == KeyEventKind::Press
        && (matches!(k.code, KeyCode::Char('q'))
            || (k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn interactive_terminal_gets_the_panel() {
        assert_eq!(decide_mode(&args(&[]), true), Mode::Tui { watch: false });
    }

    #[test]
    fn watch_alone_is_a_watching_panel() {
        assert_eq!(
            decide_mode(&args(&["--watch"]), true),
            Mode::Tui { watch: true }
        );
    }

    #[test]
    fn plain_flag_forces_plain_even_on_a_tty() {
        assert_eq!(decide_mode(&args(&["--plain"]), true), Mode::Plain);
    }

    #[test]
    fn plain_wins_over_watch() {
        assert_eq!(
            decide_mode(&args(&["--plain", "--watch"]), true),
            Mode::Plain
        );
    }

    #[test]
    fn piped_stdout_falls_back_to_plain() {
        assert_eq!(decide_mode(&args(&[]), false), Mode::Plain);
        assert_eq!(decide_mode(&args(&["--watch"]), false), Mode::Plain);
    }

    #[test]
    fn help_wins_over_everything() {
        assert_eq!(decide_mode(&args(&["-h"]), false), Mode::Help);
        assert_eq!(decide_mode(&args(&["--watch", "--help"]), true), Mode::Help);
    }

    #[test]
    fn usage_mentions_the_flags_and_stays_ascii() {
        assert!(USAGE.contains("--plain") && USAGE.contains("--watch"));
        assert!(USAGE.is_ascii());
    }

    #[test]
    fn quit_keys_are_ctrl_c_and_q_only() {
        use crossterm::event::KeyEvent;
        let press = |code: KeyCode, mods: KeyModifiers| KeyEvent {
            code,
            modifiers: mods,
            kind: KeyEventKind::Press,
            state: crossterm::event::KeyEventState::NONE,
        };
        assert!(is_quit_key(&press(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL
        )));
        assert!(is_quit_key(&press(KeyCode::Char('q'), KeyModifiers::NONE)));
        let mut release = press(KeyCode::Char('q'), KeyModifiers::NONE);
        release.kind = KeyEventKind::Release;
        assert!(!is_quit_key(&release));
        assert!(!is_quit_key(&press(KeyCode::Char('c'), KeyModifiers::NONE)));
        assert!(!is_quit_key(&press(
            KeyCode::Char('x'),
            KeyModifiers::CONTROL
        )));
        assert!(!is_quit_key(&press(
            KeyCode::Char('C'),
            KeyModifiers::CONTROL
        )));
    }
}
