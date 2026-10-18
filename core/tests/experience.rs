//! Public-API integration: drive the whole welcome experience and
//! smoke-render it; nothing here runs cryptsetup.

use anyhow::{bail, Result};
use ombra_boot::input::SecretBuf;
use ombra_boot::welcome::{draw, run_apply, Action, Applier, DiskState, Screen, Welcome};
use ombra_boot::BUILD_PASSPHRASE;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::backend::TestBackend;
use ratatui::Terminal;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::empty())
}

fn type_into(app: &mut Welcome, s: &str) {
    for c in s.chars() {
        app.on_key(key(KeyCode::Char(c)));
    }
}

fn submit(app: &mut Welcome, s: &str) {
    type_into(app, s);
    app.on_key(key(KeyCode::Enter));
}

struct FakeApplier {
    calls: Vec<&'static str>,
    fail_at: Option<&'static str>,
}

impl FakeApplier {
    fn record(&mut self, step: &'static str) -> Result<()> {
        self.calls.push(step);
        if self.fail_at == Some(step) {
            bail!("simulated failure at {step}")
        }
        Ok(())
    }
}

impl Applier for FakeApplier {
    fn disk_state(&mut self) -> Result<DiskState> {
        self.record("disk_state")?;
        Ok(DiskState::Fresh)
    }
    fn add_user_key(&mut self, build_key: &[u8], passphrase: &SecretBuf) -> Result<()> {
        assert_eq!(build_key, BUILD_PASSPHRASE.as_bytes());
        assert!(!passphrase.is_empty());
        self.record("add_user_key")
    }
    fn reencrypt(&mut self, passphrase: &SecretBuf, resume: bool) -> Result<()> {
        assert!(!passphrase.is_empty());
        assert!(!resume);
        self.record("reencrypt")
    }
    fn verify_sealed(&mut self, _passphrase: &SecretBuf) -> Result<()> {
        self.record("verify_sealed")
    }
    fn set_user_password(&mut self, username: &str, password: &SecretBuf) -> Result<()> {
        assert_eq!(username, "ombra");
        assert!(!password.is_empty());
        self.record("set_user_password")
    }
}

#[test]
fn happy_path_from_welcome_to_reboot() {
    let mut app = Welcome::new();
    assert_eq!(app.screen(), Screen::Welcome);
    assert!(app.secrets().is_none());

    app.on_key(key(KeyCode::Enter));
    assert_eq!(app.screen(), Screen::DiskPassphrase);
    submit(&mut app, "sardines1");
    submit(&mut app, "sardines1");
    assert_eq!(app.screen(), Screen::UserPassword);
    submit(&mut app, "hunter2xyz");
    submit(&mut app, "hunter2xyz");
    assert_eq!(app.screen(), Screen::Summary);

    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartApply);
    app.begin_apply();
    let (disk, user) = app.secrets().expect("secrets ready to apply");

    let mut fake = FakeApplier { calls: Vec::new(), fail_at: None };
    run_apply(&mut fake, BUILD_PASSPHRASE.as_bytes(), &disk, &user).expect("apply ok");
    assert_eq!(fake.calls, vec!["disk_state", "set_user_password", "add_user_key", "reencrypt", "verify_sealed"]);

    app.apply_succeeded();
    assert_eq!(app.screen(), Screen::Rebooting);
}

#[test]
fn failed_rotation_returns_to_screen_two_and_retry_succeeds() {
    let mut app = Welcome::new();
    app.on_key(key(KeyCode::Enter));
    submit(&mut app, "sardines1");
    submit(&mut app, "sardines1");
    submit(&mut app, "hunter2xyz");
    submit(&mut app, "hunter2xyz");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartApply);

    app.begin_apply();
    app.apply_failed("rotating the disk key failed: simulated failure at reencrypt");
    assert_eq!(app.screen(), Screen::DiskPassphrase);

    submit(&mut app, "newpass99");
    submit(&mut app, "newpass99");
    assert_eq!(app.screen(), Screen::UserPassword);
    submit(&mut app, "hunter2xyz");
    submit(&mut app, "hunter2xyz");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartApply);
    app.begin_apply();
    let (disk, user) = app.secrets().unwrap();
    let mut fake = FakeApplier { calls: Vec::new(), fail_at: None };
    run_apply(&mut fake, BUILD_PASSPHRASE.as_bytes(), &disk, &user).unwrap();
    assert_eq!(fake.calls, vec!["disk_state", "set_user_password", "add_user_key", "reencrypt", "verify_sealed"]);
}

#[test]
fn renders_every_screen_across_console_sizes() {
    for (w, h) in [(160u16, 50u16), (100, 30), (80, 25)] {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        let mut app = Welcome::new();

        let screen = |app: &mut Welcome, t: &mut Terminal<TestBackend>| {
            t.draw(|f| draw(f, app)).unwrap();
            let buf = t.backend().buffer();
            (
                (0..buf.area.height)
                    .map(|y| {
                        (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect::<String>()
                    })
                    .collect::<Vec<_>>(),
                (0..buf.area.height)
                    .map(|y| {
                        (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect::<String>()
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
        };
        let has = |rows: &Vec<String>, needle: &str| rows.iter().any(|r| r.contains(needle));

        let (rows, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("WELCOME TO OMBRA"));
        assert!(has(&rows, " enter  begin"));

        app.on_key(key(KeyCode::Enter));
        let (rows, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("set your disk encryption passphrase"));
        assert!(has(&rows, "\u{256d}") && has(&rows, "\u{2570}"));
        assert!(all.contains("LUKS2 \u{b7} AES-256-XTS \u{b7} argon2id"));
        assert!(!all.contains("[+]") && !all.contains("[-]"));
        submit(&mut app, "sardines1");

        let (_, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("repeat it to confirm"));
        assert!(!all.contains("LUKS2 \u{b7} AES-256-XTS \u{b7} argon2id"));

        submit(&mut app, "sardines1");
        let (_, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("set your user password"));
        submit(&mut app, "hunter2xyz");
        submit(&mut app, "hunter2xyz");
        let (rows, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("everything set"));
        assert!(has(&rows, " enter  finish"));

        app.begin_apply();
        let (_, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("setting things up..."));
        app.apply_succeeded();
        let (_, all) = screen(&mut app, &mut terminal);
        assert!(all.contains("restarting"));
    }
}

#[test]
fn short_console_80x24_still_shows_the_full_ui() {
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    let mut app = Welcome::new();
    app.on_key(key(KeyCode::Enter));
    submit(&mut app, "sardines1");
    terminal.draw(|f| draw(f, &app)).unwrap();
    let buf = terminal.backend().buffer();
    let rows: Vec<String> = (0..buf.area.height)
        .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
        .collect();
    let all = rows.join("\n");
    assert!(all.contains("set your disk encryption passphrase"));
    assert!(rows.iter().any(|r| r.contains('\u{256d}')));
    assert!(all.contains(&ombra_boot::art::ring_rows(24)[0].trim().to_string()));
    assert!(!all.contains("enter the same passphrase"));
}
