//! First-use setup: welcome -> disk passphrase -> user password -> summary -> apply; apply is behind [`Applier`].

use std::fs;
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt;
use std::process::{Command, Stdio};

use anyhow::{anyhow, bail, ensure, Context, Result};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::text::Line;
use ratatui::Frame;

use crate::input::{FieldEvent, SecretBuf, SecretField, SecretFlow, Severity};
use crate::{art, theme};

/// The only user account on an Ombra machine.
pub const USER: &str = "ombra";
/// tmpfs keyfile carrying the build key through luksChangeKey; removed as soon as cryptsetup is done.
pub const BUILD_KEYFILE: &str = "/run/ombra-build-key";
/// tmpfs keyfile for the NEW passphrase — cryptsetup must never read a new key from the tty.
pub const NEW_KEYFILE: &str = "/run/ombra-new-key";
/// Written each boot by `ombra-welcome --probe`: setup is complete iff the public build key NO LONGER opens the disk.
pub const SETUP_COMPLETE: &str = "/run/ombra/setup-complete";

pub const PULSE_CHARS: [char; 6] = [' ', '.', 'o', 'O', 'o', '.'];

/// Where the disk is in its first-use life.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiskState {
    /// The public build key still opens the disk; no re-encryption started.
    Fresh,
    /// A volume-key re-encryption was started and has not finished.
    Reencrypting,
    /// Re-encryption finished and the build key is dead.
    Sealed,
}

pub trait Applier: Send {
    fn set_user_password(&mut self, username: &str, password: &SecretBuf) -> Result<()>;
    fn disk_state(&mut self) -> Result<DiskState>;
    /// Idempotent: a no-op when `passphrase` already opens the disk.
    fn add_user_key(&mut self, build_key: &[u8], passphrase: &SecretBuf) -> Result<()>;
    /// Replaces the volume key; `resume` continues an interrupted run.
    fn reencrypt(&mut self, passphrase: &SecretBuf, resume: bool) -> Result<()>;
    /// Post-condition: sealed, the build key dead, `passphrase` live.
    fn verify_sealed(&mut self, passphrase: &SecretBuf) -> Result<()>;
}

/// Refuses the public build passphrase as anyone's key.
pub fn forbid_build_passphrase(passphrase: &SecretBuf) -> Result<()> {
    ensure!(
        passphrase.expose() != crate::BUILD_PASSPHRASE,
        "that is the public build passphrase - choose your own"
    );
    Ok(())
}

/// A sealed disk is verified before the password lands; otherwise the password lands first, then the disk walks Fresh -> keyed -> re-encrypted -> verified.
pub fn run_apply(
    applier: &mut dyn Applier,
    build_key: &[u8],
    disk_passphrase: &SecretBuf,
    user_password: &SecretBuf,
) -> Result<()> {
    forbid_build_passphrase(disk_passphrase)?;
    match applier.disk_state()? {
        DiskState::Sealed => {
            applier.verify_sealed(disk_passphrase)?;
            applier.set_user_password(USER, user_password)
        }
        DiskState::Fresh => {
            applier.set_user_password(USER, user_password)?;
            applier.add_user_key(build_key, disk_passphrase)?;
            applier.reencrypt(disk_passphrase, false)?;
            applier.verify_sealed(disk_passphrase)
        }
        DiskState::Reencrypting => {
            applier.set_user_password(USER, user_password)?;
            applier.reencrypt(disk_passphrase, true)?;
            applier.verify_sealed(disk_passphrase)
        }
    }
}

/// Boot-time resume of an interrupted re-encryption: only the passphrase is asked.
pub fn run_resume(applier: &mut dyn Applier, passphrase: &SecretBuf) -> Result<()> {
    forbid_build_passphrase(passphrase)?;
    match applier.disk_state()? {
        DiskState::Reencrypting => applier.reencrypt(passphrase, true)?,
        DiskState::Sealed => {}
        DiskState::Fresh => bail!("no interrupted re-encryption to resume"),
    }
    applier.verify_sealed(passphrase)
}

/// Boot-time gate: dead build key ⇒ write the runtime marker the display manager conditions on.
pub fn record_gate_result(build_key_dead: bool) -> Result<()> {
    if build_key_dead {
        if let Some(p) = std::path::Path::new(SETUP_COMPLETE).parent() {
            fs::create_dir_all(p).context("creating /run/ombra")?;
        }
        fs::write(SETUP_COMPLETE, b"ok\n").context("writing the setup-complete marker")?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Screen {
    Welcome,
    DiskPassphrase,
    UserPassword,
    Summary,
    Resume,
    Applying,
    Rebooting,
    NeedsPersistent,
}

impl Screen {
    pub fn title(self) -> &'static str {
        match self {
            Screen::Welcome => "WELCOME TO OMBRA",
            Screen::DiskPassphrase => "set your disk encryption passphrase",
            Screen::UserPassword => "set your user password",
            Screen::Summary => "everything set",
            Screen::Resume => "finish securing your disk",
            Screen::Applying => "setting things up...",
            Screen::Rebooting => "restarting",
            Screen::NeedsPersistent => "restart in persistent mode",
        }
    }

    pub fn hints(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Screen::Welcome => &[("enter", "begin")],
            Screen::Summary => &[("enter", "finish")],
            Screen::NeedsPersistent => &[("enter", "restart")],
            _ => &[],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    None,
    StartApply,
    StartResume,
    Restart,
}

pub struct Welcome {
    screen: Screen,
    disk_flow: SecretFlow,
    user_flow: SecretFlow,
    disk_secret: Option<SecretBuf>,
    user_secret: Option<SecretBuf>,
    resume_field: SecretField,
    resume_secret: Option<SecretBuf>,
    resuming: bool,
    /// Screen-level message (e.g. an apply failure).
    note: Option<(String, Severity)>,
    pulse: usize,
    caret_phase: bool,
}

impl Welcome {
    pub fn new() -> Self {
        Welcome {
            screen: Screen::Welcome,
            disk_flow: {
                let mut f = SecretFlow::new("passphrase", "repeat passphrase");
                f.forbid(crate::BUILD_PASSPHRASE);
                f
            },
            user_flow: SecretFlow::new("password", "repeat password"),
            disk_secret: None,
            user_secret: None,
            resume_field: SecretField::new("passphrase"),
            resume_secret: None,
            resuming: false,
            note: None,
            pulse: 0,
            caret_phase: true,
        }
    }

    /// Starts at the passphrase prompt that finishes an interrupted re-encryption.
    pub fn resuming() -> Self {
        let mut w = Welcome::new();
        w.resuming = true;
        w.screen = Screen::Resume;
        w
    }

    /// First-time setup cannot run on a RAM-overlay root.
    pub fn needs_persistent() -> Self {
        let mut w = Welcome::new();
        w.screen = Screen::NeedsPersistent;
        w
    }

    pub fn begin_restart(&mut self) {
        self.screen = Screen::Rebooting;
        self.note = None;
    }

    pub fn resume_field(&self) -> &SecretField {
        &self.resume_field
    }

    pub fn resume_secret(&self) -> Option<SecretBuf> {
        self.resume_secret.clone()
    }

    pub fn screen(&self) -> Screen {
        self.screen
    }

    pub fn active_flow(&self) -> &SecretFlow {
        match self.screen {
            Screen::DiskPassphrase => &self.disk_flow,
            _ => &self.user_flow,
        }
    }

    pub fn note(&self) -> Option<(&str, Severity)> {
        self.note.as_ref().map(|(m, s)| (m.as_str(), *s))
    }

    pub fn pulse(&self) -> char {
        PULSE_CHARS[self.pulse % PULSE_CHARS.len()]
    }

    /// Advance the working-screen pulse.
    pub fn tick_pulse(&mut self) {
        self.pulse = (self.pulse + 1) % PULSE_CHARS.len();
    }

    /// The caret blinks on its own counter, slower than the pulse.
    pub fn tick_caret(&mut self) {
        self.caret_phase = !self.caret_phase;
        self.disk_flow.set_caret(self.caret_phase);
        self.user_flow.set_caret(self.caret_phase);
        self.resume_field.set_caret(self.caret_phase);
    }

    /// True while the caret should be painted on the next frame.
    pub fn caret_on(&self) -> bool {
        self.caret_phase
    }

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        match self.screen {
            Screen::Welcome => {
                if key.code == KeyCode::Enter {
                    self.screen = Screen::DiskPassphrase;
                }
                Action::None
            }
            Screen::DiskPassphrase => {
                match self.disk_flow.handle_key(key) {
                    crate::input::FlowEvent::Completed(secret) => {
                        self.disk_secret = Some(secret);
                        self.screen = Screen::UserPassword;
                        self.note = None;
                    }
                    _ => {}
                }
                Action::None
            }
            Screen::UserPassword => {
                match self.user_flow.handle_key(key) {
                    crate::input::FlowEvent::Completed(secret) => {
                        self.user_secret = Some(secret);
                        self.screen = Screen::Summary;
                        self.note = None;
                    }
                    _ => {}
                }
                Action::None
            }
            Screen::Summary => {
                if key.code == KeyCode::Enter {
                    self.note = None;
                    Action::StartApply
                } else {
                    Action::None
                }
            }
            Screen::Resume => {
                match self.resume_field.handle_key(key) {
                    FieldEvent::Submitted
                        if self.resume_field.value() == crate::BUILD_PASSPHRASE =>
                    {
                        self.note = Some((
                            "that is the public build passphrase - choose your own".to_string(),
                            Severity::Bad,
                        ));
                    }
                    FieldEvent::Submitted => {
                        self.resume_secret = Some(SecretBuf::new(self.resume_field.take()));
                        self.note = None;
                        return Action::StartResume;
                    }
                    FieldEvent::TooShort => {
                        self.note = Some(("use at least 8 characters".to_string(), Severity::Bad));
                    }
                    FieldEvent::Edited => self.note = None,
                    FieldEvent::Ignored => {}
                }
                Action::None
            }
            Screen::NeedsPersistent => {
                if key.code == KeyCode::Enter {
                    Action::Restart
                } else {
                    Action::None
                }
            }
            // Applying / Rebooting: no input honored
            _ => Action::None,
        }
    }

    pub fn begin_apply(&mut self) {
        self.screen = Screen::Applying;
        self.note = None;
    }

    /// Both secrets, present only once the user completed both flows.
    pub fn secrets(&self) -> Option<(SecretBuf, SecretBuf)> {
        Some((self.disk_secret.clone()?, self.user_secret.clone()?))
    }

    pub fn apply_failed(&mut self, detail: &str) {
        self.disk_flow.reset();
        self.user_flow.reset();
        self.disk_secret = None;
        self.user_secret = None;
        self.resume_field.clear();
        self.resume_secret = None;
        self.screen = if self.resuming {
            Screen::Resume
        } else {
            Screen::DiskPassphrase
        };
        self.note = Some((detail.to_string(), Severity::Bad));
    }

    pub fn apply_succeeded(&mut self) {
        // drop the held secret copies
        self.disk_secret = None;
        self.user_secret = None;
        self.resume_secret = None;
        self.screen = Screen::Rebooting;
        self.note = None;
    }
}

impl Default for Welcome {
    fn default() -> Self {
        Self::new()
    }
}

pub fn draw(f: &mut Frame, app: &Welcome) {
    let area = f.area();
    let l = theme::layout(area);
    f.render_widget(
        art::Ring::for_console(l.ring.height.max(area.height.min(40))),
        l.ring,
    );
    theme::put_wordmark(f, l.brand, theme::FIELD_WIDTH);
    if !matches!(
        app.screen(),
        Screen::DiskPassphrase | Screen::UserPassword | Screen::Resume
    ) {
        theme::put_centered(f, l.title, app.screen().title(), theme::fg(theme::LABEL));
    }

    // field screens need the full content height: no footer band
    let mut c = l.content;
    if matches!(
        app.screen(),
        Screen::DiskPassphrase | Screen::UserPassword | Screen::Resume
    ) {
        c.height = area.bottom().saturating_sub(c.y);
    }
    match app.screen() {
        Screen::Welcome => {
            let label = theme::fg(theme::LABEL);
            let text = theme::fg(theme::TEXT);
            let lines: &[(&str, ratatui::style::Style)] = &[
                ("om\u{b7}bra  /'om.br\u{e4}/  \u{b7}  italian, noun", label),
                ("", text),
                ("1. shadow.", text),
                ("2. this machine: everything it does online", text),
                ("   passes through tor. you were never here.", text),
            ];
            theme::put_block(f, c, lines);
            let hint_row = (lines.len() as u16 + 1).min(c.height.saturating_sub(1));
            theme::put_hints(f, theme::row_in(c, hint_row), app.screen().hints());
        }
        Screen::DiskPassphrase | Screen::UserPassword => {
            // title left-aligned to the input box's edge
            let field = theme::center_horiz(c, theme::FIELD_WIDTH, 3);
            let title = app.screen().title();
            theme::put_left(
                f,
                theme::line_rect(c, field.x, c.y),
                title,
                theme::fg(theme::TEXT),
            );
            let box1 = ratatui::layout::Rect {
                x: field.x,
                y: c.y + 1,
                width: field.width,
                height: 3,
            };
            f.render_widget(app.active_flow().first_field(), box1);
            let mut row = c.y + 4;

            // the second box spawns below once the first is accepted
            if app.active_flow().on_second() {
                let second = ratatui::layout::Rect {
                    x: field.x,
                    y: row,
                    width: field.width,
                    height: 3,
                };
                f.render_widget(app.active_flow().second_field(), second);
                row += 3;
            }

            if let Some((msg, sev)) = app.active_flow().message() {
                let color = match sev {
                    Severity::Bad => theme::BAD,
                    Severity::Muted => theme::MUTED,
                };
                let msg = theme::truncate(msg, field.width as usize);
                theme::put_left(f, theme::line_rect(c, field.x, row), &msg, theme::fg(color));
                row += 1;
            } else if !app.active_flow().on_second() {
                let info = match app.screen() {
                    Screen::DiskPassphrase => {
                        theme::dotted_line(&["LUKS2", "AES-256-XTS", "argon2id"])
                    }
                    _ => Line::styled(
                        "the password for the account \"ombra\"",
                        theme::fg(theme::LABEL),
                    ),
                };
                theme::put_line(f, theme::line_rect(c, field.x, row), info);
            }
            if let Some((note, sev)) = app.note() {
                let color = match sev {
                    Severity::Bad => theme::BAD,
                    Severity::Muted => theme::MUTED,
                };
                let note = theme::truncate(note, field.width as usize);
                theme::put_left(
                    f,
                    theme::line_rect(c, field.x, row + 1),
                    &note,
                    theme::fg(color),
                );
            }
        }
        Screen::Summary => {
            theme::put_line_centered(
                f,
                theme::row_in(c, 0),
                theme::status_line(
                    theme::GOOD,
                    "Your system will restart now.",
                    theme::fg(theme::TEXT),
                ),
            );
            theme::put_centered(
                f,
                theme::row_in(c, 1),
                "At the next screen, enter your NEW passphrase - that is normal.",
                theme::fg(theme::LABEL),
            );
            theme::put_hints(f, theme::row_in(c, 3), app.screen().hints());
        }
        Screen::Resume => {
            let field = theme::center_horiz(c, theme::FIELD_WIDTH, 3);
            theme::put_left(
                f,
                theme::line_rect(c, field.x, c.y),
                "enter your passphrase to finish encrypting your disk",
                theme::fg(theme::TEXT),
            );
            let box1 = ratatui::layout::Rect {
                x: field.x,
                y: c.y + 1,
                width: field.width,
                height: 3,
            };
            f.render_widget(app.resume_field(), box1);
            let (msg, color) = match app.note() {
                Some((m, Severity::Bad)) => (m, theme::BAD),
                Some((m, Severity::Muted)) => (m, theme::MUTED),
                None => (
                    "the last setup was interrupted - this picks it up",
                    theme::MUTED,
                ),
            };
            let msg = theme::truncate(msg, field.width as usize);
            theme::put_left(
                f,
                theme::line_rect(c, field.x, c.y + 4),
                &msg,
                theme::fg(color),
            );
        }
        Screen::Applying => {
            let dot: String = app.pulse().to_string();
            theme::put_centered(
                f,
                theme::row_in(c, 0),
                "making a new key for your disk and re-encrypting it",
                theme::fg(theme::TEXT),
            );
            theme::put_centered(
                f,
                theme::row_in(c, 1),
                "this takes a while",
                theme::fg(theme::LABEL),
            );
            theme::put_centered(f, theme::row_in(c, 3), &dot, theme::fg(theme::RING_DIM));
            theme::put_centered(
                f,
                theme::row_in(c, 5),
                "do not power off or restart",
                theme::fg(theme::AMBER),
            );
        }
        Screen::NeedsPersistent => {
            theme::put_centered(
                f,
                theme::row_in(c, 0),
                "first-time setup needs a disk that remembers.",
                theme::fg(theme::TEXT),
            );
            theme::put_centered(
                f,
                theme::row_in(c, 1),
                "restart and choose Persistent at the boot menu.",
                theme::fg(theme::TEXT),
            );
            theme::put_hints(f, theme::row_in(c, 3), app.screen().hints());
        }
        Screen::Rebooting => {}
    }
}

// ---- the real applier ----

pub struct SystemApplier;

impl Applier for SystemApplier {
    fn set_user_password(&mut self, username: &str, password: &SecretBuf) -> Result<()> {
        let mut child = Command::new("chpasswd")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("running chpasswd")?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("chpasswd stdin unavailable"))?;
        // never via argv/env; the line buffer is zeroized on drop
        let line = SecretBuf::new(format!("{username}:{}\n", password.expose()));
        stdin.write_all(line.as_bytes())?;
        drop(stdin);
        drop(line);
        let out = child.wait_with_output()?;
        ensure!(
            out.status.success(),
            "setting the user password failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
        Ok(())
    }

    fn disk_state(&mut self) -> Result<DiskState> {
        current_disk_state(&discover_luks()?.device)
    }

    fn add_user_key(&mut self, build_key: &[u8], passphrase: &SecretBuf) -> Result<()> {
        forbid_build_passphrase(passphrase)?;
        let dev = discover_luks()?.device;
        let _newkey = KeyFileGuard::write(NEW_KEYFILE, passphrase.as_bytes())?;
        if key_opens_device(&dev, NEW_KEYFILE)? {
            return Ok(());
        }
        let _buildkey = KeyFileGuard::write(BUILD_KEYFILE, build_key)?;
        let out = tool("cryptsetup")
            .args(luks_add_key_args(&dev))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .context("running cryptsetup luksAddKey")?;
        ensure!(
            out.status.success(),
            "adding your passphrase failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
        ensure!(
            key_opens_device(&dev, NEW_KEYFILE)?,
            "the new passphrase does not open the disk after adding it"
        );
        Ok(())
    }

    fn reencrypt(&mut self, passphrase: &SecretBuf, resume: bool) -> Result<()> {
        forbid_build_passphrase(passphrase)?;
        let luks = discover_luks()?;
        let _newkey = KeyFileGuard::write(NEW_KEYFILE, passphrase.as_bytes())?;
        let out = tool("cryptsetup")
            .args(reencrypt_args(
                &luks.mapping,
                &luks.device,
                user_key_slot(&luks.device)?,
                resume,
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .context("running cryptsetup reencrypt")?;
        if let Some(why) =
            reencrypt_failure(out.status.code(), &String::from_utf8_lossy(&out.stderr))
        {
            bail!("{why}");
        }
        let _buildkey = KeyFileGuard::write(BUILD_KEYFILE, crate::BUILD_PASSPHRASE.as_bytes())?;
        if key_opens_device(&luks.device, BUILD_KEYFILE)? {
            let build_slot = key_slot(&luks.device, BUILD_KEYFILE)?;
            let user_slot = key_slot(&luks.device, NEW_KEYFILE)?;
            ensure_distinct_slots(user_slot, build_slot)?;
            let out = tool("cryptsetup")
                .args([
                    "luksRemoveKey",
                    "--batch-mode",
                    "--key-file",
                    BUILD_KEYFILE,
                    &luks.device,
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .output()
                .context("running cryptsetup luksRemoveKey")?;
            ensure!(
                out.status.success(),
                "retiring the build passphrase failed: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(())
    }

    fn verify_sealed(&mut self, passphrase: &SecretBuf) -> Result<()> {
        let dev = discover_luks()?.device;
        let _newkey = KeyFileGuard::write(NEW_KEYFILE, passphrase.as_bytes())?;
        let state = current_disk_state(&dev)?;
        let build_opens = {
            let _buildkey = KeyFileGuard::write(BUILD_KEYFILE, crate::BUILD_PASSPHRASE.as_bytes())?;
            key_opens_device(&dev, BUILD_KEYFILE)?
        };
        let user_opens = key_opens_device(&dev, NEW_KEYFILE)?;
        sealed_verdict(state, build_opens, user_opens)?;
        // advisory: every surviving keyslot should be argon2id, but a stale one must not strand a sealed disk
        if let Err(e) = verify_argon2id(&dev) {
            eprintln!("ombra-welcome: {e:#}");
        }
        Ok(())
    }
}

/// The post-condition: re-encryption finished, the build key dead, the user's key live.
pub fn sealed_verdict(state: DiskState, build_opens: bool, user_opens: bool) -> Result<()> {
    ensure!(
        state != DiskState::Reencrypting,
        "the disk re-encryption has not finished"
    );
    ensure!(
        !build_opens && state == DiskState::Sealed,
        "the build passphrase still opens the disk"
    );
    ensure!(user_opens, "that passphrase does not open the disk");
    Ok(())
}

/// Reencrypting while a re-encryption is unfinished (build key irrelevant); else by whether the build key still opens.
pub fn disk_state_from(
    reencrypting: bool,
    build_key_opens: impl FnOnce() -> Result<bool>,
) -> Result<DiskState> {
    if reencrypting {
        return Ok(DiskState::Reencrypting);
    }
    Ok(if build_key_opens()? {
        DiskState::Fresh
    } else {
        DiskState::Sealed
    })
}

fn current_disk_state(dev: &str) -> Result<DiskState> {
    let dump = luks_dump(dev)?;
    let json_says = luks_json(dev)
        .map(|j| reencrypt_in_json(&j))
        .unwrap_or(false);
    disk_state_from(reencrypt_in_progress(&dump) || json_says, || {
        let _keyfile = KeyFileGuard::write(BUILD_KEYFILE, crate::BUILD_PASSPHRASE.as_bytes())?;
        key_opens_device(dev, BUILD_KEYFILE)
    })
}

/// Boot gate: the marker is written only for a sealed disk — build key dead AND no re-encryption pending.
pub fn probe_build_key() -> Result<bool> {
    let state = current_disk_state(&discover_luks()?.device)?;
    let sealed = state == DiskState::Sealed;
    record_gate_result(sealed)?;
    Ok(sealed)
}

/// What the welcome flow must do at startup; errors fail closed to the normal flow.
pub fn startup_state() -> Result<DiskState> {
    current_disk_state(&discover_luks()?.device)
}

/// Only cryptsetup exit 2 means "no key available with this passphrase"; every other failure is an error, never a verdict.
pub fn passphrase_verdict(code: Option<i32>) -> Result<bool> {
    match code {
        Some(0) => Ok(true),
        Some(2) => Ok(false),
        Some(c) => bail!("cryptsetup --test-passphrase failed (exit {c})"),
        None => bail!("cryptsetup --test-passphrase was killed by a signal"),
    }
}

/// The keyslot a key file opens: reencrypt refuses a bare key file while several slots are active.
fn key_slot(dev: &str, keyfile: &str) -> Result<u32> {
    for slot in parse_keyslots(&luks_dump(dev)?) {
        let status = tool("cryptsetup")
            .args([
                "open",
                "--test-passphrase",
                "--key-file",
                keyfile,
                "--key-slot",
                &slot.to_string(),
                dev,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .context("running cryptsetup --test-passphrase")?;
        if status.code() == Some(0) {
            return Ok(slot);
        }
    }
    bail!("that passphrase does not open the disk")
}

fn user_key_slot(dev: &str) -> Result<u32> {
    key_slot(dev, NEW_KEYFILE)
}

/// Removing the build key must never remove the slot the user's key lives in.
pub fn ensure_distinct_slots(user_slot: u32, build_slot: u32) -> Result<()> {
    ensure!(
        user_slot != build_slot,
        "the new passphrase shares a keyslot with the build passphrase; not removing it"
    );
    Ok(())
}

fn key_opens_device(dev: &str, keyfile: &str) -> Result<bool> {
    let out = tool("cryptsetup")
        .args(["open", "--test-passphrase", "--key-file", keyfile, dev])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .context("running cryptsetup --test-passphrase")?;
    passphrase_verdict(out.status.code()).map_err(|e| {
        let why = String::from_utf8_lossy(&out.stderr);
        anyhow!("{e}: {}", why.trim())
    })
}

/// argv for adding the user's passphrase; the PBKDF cost is pinned, never benchmarked.
pub fn luks_add_key_args(dev: &str) -> Vec<String> {
    [
        "luksAddKey",
        "--key-file",
        BUILD_KEYFILE,
        "--new-keyfile",
        NEW_KEYFILE,
        "--pbkdf",
        "argon2id",
        "--pbkdf-memory",
        "1048576",
        "--pbkdf-parallel",
        "2",
        "--pbkdf-force-iterations",
        "4",
        dev,
    ]
    .iter()
    .map(|a| a.to_string())
    .collect()
}

/// argv for the online volume-key replacement (or its resume). The user's key unlocks it, so the build slot is not re-wrapped and dies with the old key.
pub fn reencrypt_args(mapping: &str, dev: &str, slot: u32, resume: bool) -> Vec<String> {
    let slot = slot.to_string();
    let mut args: Vec<&str> = vec![
        "reencrypt",
        "--batch-mode",
        "--key-file",
        NEW_KEYFILE,
        "--key-slot",
        &slot,
        "--active-name",
        mapping,
    ];
    if resume {
        args.push("--resume-only");
    } else {
        args.extend([
            "--cipher",
            "aes-xts-plain64",
            "--key-size",
            "512",
            "--pbkdf",
            "argon2id",
            "--pbkdf-memory",
            "1048576",
            "--pbkdf-parallel",
            "2",
            "--pbkdf-force-iterations",
            "4",
            "--resilience",
            "checksum",
            "--resilience-hash",
            "sha256",
        ]);
    }
    args.push(dev);
    args.iter().map(|a| a.to_string()).collect()
}

/// None on success; a plain-words reason otherwise (exit 2 = the passphrase is not a key of this disk).
pub fn reencrypt_failure(code: Option<i32>, stderr: &str) -> Option<String> {
    match code {
        Some(0) => None,
        Some(2) => Some("that passphrase does not open the disk".to_string()),
        Some(c) => {
            let why = stderr.trim();
            Some(format!("re-encrypting the disk failed (exit {c}): {why}"))
        }
        None => Some("re-encrypting the disk was killed".to_string()),
    }
}

/// True while LUKS2 online re-encryption is unfinished: a reencrypt requirement flag or a `reencrypt` keyslot.
pub fn reencrypt_in_progress(luks_dump_output: &str) -> bool {
    luks_dump_output.lines().any(|line| {
        let t = line.trim();
        if let Some(req) = t.strip_prefix("Requirements:") {
            return req.contains("reencrypt");
        }
        t.split_once(':').is_some_and(|(num, rest)| {
            num.trim().parse::<u32>().is_ok() && rest.trim() == "reencrypt"
        })
    })
}

fn tool(program: &str) -> Command {
    let mut c = Command::new(program);
    c.env("LC_ALL", "C");
    c
}

struct KeyFileGuard {
    path: &'static str,
}

impl KeyFileGuard {
    fn write(path: &'static str, bytes: &[u8]) -> Result<Self> {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            // permissions before content: no wide-open keyfile window
            .mode(0o400)
            .open(path)
            .with_context(|| format!("creating {path}"))?;
        f.write_all(bytes)
            .with_context(|| format!("writing {path}"))?;
        Ok(KeyFileGuard { path })
    }
}

impl Drop for KeyFileGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.path);
    }
}

/// overlayroot mounts the real root read-only here, leaving `/` as the overlay.
const OVERLAY_LOWER: &str = "/media/root-ro";

/// The device mounted on / in `lsblk -no NAME,MOUNTPOINT` output.
pub fn parse_lsblk_root(output: &str) -> Option<String> {
    let find = |mount: &str| {
        output.lines().find_map(|line| {
            let mut fields = line.split_whitespace();
            let name = fields
                .next()?
                .trim_start_matches(|c: char| !c.is_alphanumeric());
            fields.find(|m| *m == mount).map(|_| name.to_string())
        })
    };
    find("/").or_else(|| find(OVERLAY_LOWER))
}

/// dm names reachable from `from` (inclusive) in `dmsetup ls --tree` output.
pub fn dm_ancestors(tree: &str, from: &str) -> Vec<String> {
    let mut children: Vec<(String, String)> = Vec::new();
    let mut section: Option<String> = None;
    for line in tree.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let body = line.trim_start().trim_start_matches([
            '\u{251c}', '\u{2514}', '\u{2500}', '\u{2502}', '|', '`', '-', ' ', '\t',
        ]);
        let name = dm_line_name(body);
        if line.starts_with(' ') || line.starts_with('\t') {
            if let (Some(parent), Some(child)) = (&section, name) {
                children.push((parent.clone(), child));
            }
        } else {
            section = name;
        }
    }
    let mut seen = vec![from.to_string()];
    let mut i = 0;
    while i < seen.len() {
        let here = seen[i].clone();
        for (parent, child) in &children {
            if *parent == here && !seen.contains(child) {
                seen.push(child.clone());
            }
        }
        i += 1;
    }
    seen
}

/// `name (major:minor)` from a dmsetup tree line; unnamed leaves `(maj:min)` are None.
fn dm_line_name(body: &str) -> Option<String> {
    let rest = body.trim_end().strip_suffix(')')?;
    let (name, _devno) = rest.split_once(" (")?;
    let name = name.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// (target, source) per crypttab entry; comments, blanks and short lines are skipped.
pub fn parse_crypttab(text: &str) -> Vec<(String, String)> {
    text.lines()
        .map(str::trim_start)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let target = fields.next()?;
            let source = fields.next()?;
            Some((target.to_string(), source.to_string()))
        })
        .collect()
}

/// The LUKS container behind root: the crypttab target on root's dm ancestry,
/// its source resolved through blkid. None ⇒ the caller fails closed — never a first-hit guess.
pub fn resolve_root_luks(crypttab: &str, ancestry: &[String], blkid: &str) -> Option<String> {
    resolve_root_luks_mapping(crypttab, ancestry, blkid).map(|(_, dev)| dev)
}

/// (dm mapping name, device) of the root LUKS container.
pub fn resolve_root_luks_mapping(
    crypttab: &str,
    ancestry: &[String],
    blkid: &str,
) -> Option<(String, String)> {
    parse_crypttab(crypttab)
        .iter()
        .filter(|(target, _)| ancestry.contains(target))
        .find_map(|(target, source)| {
            resolve_crypttab_source(source, blkid).map(|dev| (target.clone(), dev.to_string()))
        })
}

/// crypttab source → device: `UUID=` through blkid, literal /dev/ paths as-is.
fn resolve_crypttab_source<'a>(source: &'a str, blkid: &'a str) -> Option<&'a str> {
    if let Some(uuid) = source
        .strip_prefix("UUID=")
        .or_else(|| source.strip_prefix("uuid="))
    {
        blkid_device_with_uuid(blkid, uuid)
    } else if source.starts_with("/dev/") {
        Some(source)
    } else {
        None
    }
}

/// The blkid device line carrying `UUID="<uuid>"` — resolves crypttab UUID= sources.
pub fn blkid_device_with_uuid<'a>(blkid: &'a str, uuid: &str) -> Option<&'a str> {
    let quoted = format!("UUID=\"{uuid}\"");
    blkid.lines().find_map(|line| {
        let (dev, rest) = line.split_once(':')?;
        rest.contains(&quoted).then_some(dev.trim())
    })
}

struct RootLuks {
    mapping: String,
    device: String,
}

/// The LUKS container behind root — resolution failure is fatal, no first-hit guess.
fn discover_luks() -> Result<RootLuks> {
    let crypttab = fs::read_to_string("/etc/crypttab").context("reading /etc/crypttab")?;
    let ancestry = root_dm_ancestry()?;
    let out = tool("blkid")
        .output()
        .context("running blkid (is the util-linux package present?)")?;
    ensure!(
        out.status.success(),
        "blkid failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    resolve_root_luks_mapping(&crypttab, &ancestry, &String::from_utf8_lossy(&out.stdout))
        .map(|(mapping, device)| RootLuks { mapping, device })
        .ok_or_else(|| anyhow!("no crypttab LUKS target on root's device-mapper ancestry"))
}

/// dm names behind the device mounted on / — a crypttab target must be among them.
fn root_dm_ancestry() -> Result<Vec<String>> {
    let out = tool("lsblk")
        .args(["-nlo", "NAME,MOUNTPOINT"])
        .output()
        .context("running lsblk")?;
    ensure!(
        out.status.success(),
        "lsblk failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    let root = parse_lsblk_root(&String::from_utf8_lossy(&out.stdout))
        .ok_or_else(|| anyhow!("lsblk shows no device mounted on /"))?;
    let tree = tool("dmsetup")
        .args(["ls", "--tree", "-o", "ascii"])
        .output()
        .context("running dmsetup")?;
    ensure!(
        tree.status.success(),
        "dmsetup failed: {}",
        String::from_utf8_lossy(&tree.stderr).trim()
    );
    Ok(dm_ancestors(&String::from_utf8_lossy(&tree.stdout), &root))
}

/// The slots this run created: `after` minus `before`, ascending, deduped.
pub fn created_slots(before: &[u32], after: &[u32]) -> Vec<u32> {
    let mut created: Vec<u32> = after
        .iter()
        .filter(|slot| !before.contains(slot))
        .copied()
        .collect();
    created.sort_unstable();
    created.dedup();
    created
}

/// Occupied keyslots from `luksDump` text; the block ends at the next top-level line.
pub fn parse_keyslots(luks_dump_output: &str) -> Vec<u32> {
    let mut in_keyslots = false;
    let mut slots = Vec::new();
    for line in luks_dump_output.lines() {
        let t = line.trim_end();
        if t.starts_with("Keyslots:") {
            in_keyslots = true;
            continue;
        }
        if in_keyslots {
            let body = t.trim_start();
            if body.is_empty() {
                continue;
            }
            // no leading whitespace at all ⇒ the next top-level section
            if body.len() == t.len() {
                break;
            }
            if let Some((num, _rest)) = body.split_once(':') {
                if let Ok(n) = num.trim().parse::<u32>() {
                    slots.push(n);
                }
            }
        }
    }
    slots
}

fn luks_dump(dev: &str) -> Result<String> {
    let out = tool("cryptsetup")
        .args(["luksDump", dev])
        .stdin(Stdio::null())
        .output()
        .context("running cryptsetup luksDump")?;
    ensure!(
        out.status.success(),
        "luksDump failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn luks_json(dev: &str) -> Result<String> {
    let out = tool("cryptsetup")
        .args(["luksDump", "--dump-json-metadata", dev])
        .stdin(Stdio::null())
        .output()
        .context("running cryptsetup luksDump --dump-json-metadata")?;
    ensure!(
        out.status.success(),
        "luksDump json failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// True when LUKS2 JSON metadata shows an unfinished re-encryption: a `reencrypt` keyslot or a reencrypt requirement.
pub fn reencrypt_in_json(json: &str) -> bool {
    let compact: String = json.chars().filter(|c| !c.is_whitespace()).collect();
    compact.contains("\"type\":\"reencrypt\"")
        || compact.contains("\"online-reencrypt")
        || compact.contains("\"offline-reencrypt")
}

/// Every keyslot must be argon2id after rotation.
pub fn check_argon2id(luks_dump_output: &str) -> Result<()> {
    let mut seen = false;
    for line in luks_dump_output.lines() {
        let line = line.trim();
        if let Some(pbkdf) = line.strip_prefix("PBKDF:") {
            seen = true;
            let got = pbkdf.trim();
            if got != "argon2id" {
                bail!("keyslot PBKDF is {got}, not argon2id");
            }
        }
    }
    ensure!(seen, "no PBKDF lines in luksDump output");
    Ok(())
}

fn verify_argon2id(dev: &str) -> Result<()> {
    check_argon2id(&luks_dump(dev)?)
}

pub fn amnesic_boot(cmdline: &str) -> bool {
    cmdline.split_whitespace().any(|t| {
        t.strip_prefix("overlayroot=")
            .is_some_and(|v| !v.is_empty() && v != "disabled")
    })
}

pub fn amnesic_boot_now() -> bool {
    fs::read_to_string("/proc/cmdline")
        .map(|c| amnesic_boot(&c))
        .unwrap_or(false)
}

pub fn reboot() -> Result<()> {
    let status = Command::new("systemctl")
        .arg("reboot")
        .status()
        .context("running systemctl reboot")?;
    ensure!(status.success(), "systemctl reboot failed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyModifiers;
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

    struct FakeApplier {
        calls: Vec<String>,
        fail_at: Option<&'static str>,
        state: DiskState,
        /// The passphrase that actually opens the fake disk.
        live_key: Option<String>,
    }

    impl FakeApplier {
        fn new() -> Self {
            FakeApplier {
                calls: Vec::new(),
                fail_at: None,
                state: DiskState::Fresh,
                live_key: None,
            }
        }
        fn failing_at(name: &'static str) -> Self {
            FakeApplier {
                fail_at: Some(name),
                ..FakeApplier::new()
            }
        }
        fn in_state(state: DiskState, key: &str) -> Self {
            FakeApplier {
                state,
                live_key: Some(key.to_string()),
                ..FakeApplier::new()
            }
        }
        fn step(&mut self, name: &str) -> Result<()> {
            self.calls.push(name.to_string());
            match self.fail_at {
                Some(f) if f == name => bail!("boom at {name}"),
                _ => Ok(()),
            }
        }
    }

    impl Applier for FakeApplier {
        fn set_user_password(&mut self, _u: &str, _p: &SecretBuf) -> Result<()> {
            self.step("set_user_password")
        }
        fn disk_state(&mut self) -> Result<DiskState> {
            self.step("disk_state")?;
            Ok(self.state)
        }
        fn add_user_key(&mut self, _old: &[u8], new: &SecretBuf) -> Result<()> {
            self.step("luksAddKey")?;
            self.live_key = Some(new.expose().to_string());
            Ok(())
        }
        fn reencrypt(&mut self, pass: &SecretBuf, resume: bool) -> Result<()> {
            self.step(if resume { "resume" } else { "reencrypt" })?;
            ensure!(
                self.live_key.as_deref() == Some(pass.expose()),
                "that passphrase does not open the disk"
            );
            self.state = DiskState::Sealed;
            Ok(())
        }
        fn verify_sealed(&mut self, pass: &SecretBuf) -> Result<()> {
            self.step("verify_sealed")?;
            ensure!(
                self.live_key.as_deref() == Some(pass.expose()),
                "that passphrase does not open the disk"
            );
            sealed_verdict(self.state, false, true)
        }
    }

    fn reach_summary() -> Welcome {
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "hunter2xyz");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "hunter2xyz");
        app.on_key(key(KeyCode::Enter));
        app
    }

    #[test]
    fn state_machine_walks_all_screens() {
        let mut app = Welcome::new();
        assert_eq!(app.screen(), Screen::Welcome);
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert_eq!(app.screen(), Screen::DiskPassphrase);
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::UserPassword);
        type_into(&mut app, "hunter2xyz");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "hunter2xyz");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::Summary);
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartApply);
        app.begin_apply();
        assert_eq!(app.screen(), Screen::Applying);
        app.apply_succeeded();
        assert_eq!(app.screen(), Screen::Rebooting);
    }

    #[test]
    fn short_secret_does_not_advance_the_stage() {
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "short");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::DiskPassphrase);
        assert_eq!(
            app.active_flow().message(),
            Some(("use at least 8 characters", Severity::Bad))
        );
    }

    #[test]
    fn mismatch_restarts_the_disk_stage_only_on_failure() {
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines2");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::DiskPassphrase);
        assert_eq!(
            app.active_flow().message(),
            Some(("those didn't match - set them again", Severity::Bad))
        );
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::UserPassword);
    }

    #[test]
    fn apply_runs_all_steps_in_order_and_records_secrets() {
        let mut app = reach_summary();
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartApply);
        app.begin_apply();
        let (disk, user) = app.secrets().expect("both secrets held");
        let mut fake = FakeApplier::new();
        run_apply(&mut fake, crate::BUILD_PASSPHRASE.as_bytes(), &disk, &user).unwrap();
        assert_eq!(
            fake.calls,
            vec![
                "disk_state",
                "set_user_password",
                "luksAddKey",
                "reencrypt",
                "verify_sealed"
            ]
        );
        app.apply_succeeded();
        assert_eq!(app.screen(), Screen::Rebooting);
    }

    #[test]
    fn the_user_password_lands_before_any_disk_change() {
        let app = reach_summary();
        let (disk, user) = app.secrets().unwrap();
        let mut fake = FakeApplier::new();
        run_apply(&mut fake, b"ombra-disk", &disk, &user).unwrap();
        let pw = fake
            .calls
            .iter()
            .position(|c| c == "set_user_password")
            .unwrap();
        let add = fake.calls.iter().position(|c| c == "luksAddKey").unwrap();
        assert!(pw < add, "sequence: {:?}", fake.calls);
    }

    #[test]
    fn the_user_key_is_live_before_the_volume_key_is_touched() {
        let app = reach_summary();
        let (disk, user) = app.secrets().unwrap();
        let mut fake = FakeApplier::new();
        run_apply(&mut fake, b"ombra-disk", &disk, &user).unwrap();
        let add = fake.calls.iter().position(|c| c == "luksAddKey").unwrap();
        let enc = fake.calls.iter().position(|c| c == "reencrypt").unwrap();
        let verify = fake
            .calls
            .iter()
            .position(|c| c == "verify_sealed")
            .unwrap();
        assert!(add < enc && enc < verify, "sequence: {:?}", fake.calls);
        // no step ever removes the build slot by itself: re-encryption retires it
        assert!(!fake
            .calls
            .iter()
            .any(|c| c.contains("Kill") || c.contains("Remove")));
    }

    #[test]
    fn a_failed_reencrypt_never_reaches_verification_and_retry_resumes() {
        let app = reach_summary();
        let (disk, user) = app.secrets().unwrap();
        let mut fake = FakeApplier::failing_at("reencrypt");
        assert!(run_apply(&mut fake, b"ombra-disk", &disk, &user).is_err());
        assert_eq!(
            fake.calls,
            vec!["disk_state", "set_user_password", "luksAddKey", "reencrypt"]
        );
        // an interrupted run is picked up with the same passphrase
        let mut fake = FakeApplier::in_state(DiskState::Reencrypting, disk.expose());
        run_apply(&mut fake, b"ombra-disk", &disk, &user).unwrap();
        assert_eq!(
            fake.calls,
            vec!["disk_state", "set_user_password", "resume", "verify_sealed"]
        );
    }

    #[test]
    fn resume_with_the_wrong_passphrase_fails_and_keeps_the_disk_unfinished() {
        let app = reach_summary();
        let (_, user) = app.secrets().unwrap();
        let typed = SecretBuf::new("some-other-pass");
        let mut fake = FakeApplier::in_state(DiskState::Reencrypting, "sardines1");
        assert!(run_apply(&mut fake, b"ombra-disk", &typed, &user).is_err());
        assert_eq!(fake.state, DiskState::Reencrypting);
        assert!(!fake.calls.contains(&"verify_sealed".to_string()));
    }

    #[test]
    fn a_retry_after_a_late_failure_checks_the_typed_passphrase_not_just_the_dead_build_key() {
        let app = reach_summary();
        let (_, user) = app.secrets().unwrap();
        // the disk was sealed under "sardines1"; the user now types something else
        let typed = SecretBuf::new("a-different-one");
        let mut fake = FakeApplier::in_state(DiskState::Sealed, "sardines1");
        let err = run_apply(&mut fake, b"ombra-disk", &typed, &user).unwrap_err();
        assert!(
            err.to_string().contains("does not open the disk"),
            "{err:#}"
        );
        assert!(!fake.calls.contains(&"reencrypt".to_string()));
        // the right one then passes without touching the volume key again
        let right = SecretBuf::new("sardines1");
        run_apply(&mut fake, b"ombra-disk", &right, &user).unwrap();
        assert!(!fake.calls.contains(&"luksAddKey".to_string()));
    }

    #[test]
    fn a_failed_post_check_is_retryable_without_redoing_the_disk() {
        let app = reach_summary();
        let (disk, user) = app.secrets().unwrap();
        let mut fake = FakeApplier::failing_at("verify_sealed");
        assert!(run_apply(&mut fake, b"ombra-disk", &disk, &user).is_err());
        assert_eq!(fake.state, DiskState::Sealed);
        fake.fail_at = None;
        fake.calls.clear();
        run_apply(&mut fake, b"ombra-disk", &disk, &user).unwrap();
        assert_eq!(
            fake.calls,
            vec!["disk_state", "verify_sealed", "set_user_password"]
        );
    }

    #[test]
    fn resume_asks_only_the_passphrase_and_never_touches_the_user_password() {
        let pass = SecretBuf::new("sardines1");
        let mut fake = FakeApplier::in_state(DiskState::Reencrypting, "sardines1");
        run_resume(&mut fake, &pass).unwrap();
        assert_eq!(fake.calls, vec!["disk_state", "resume", "verify_sealed"]);

        let mut fresh = FakeApplier::in_state(DiskState::Fresh, "sardines1");
        assert!(run_resume(&mut fresh, &pass).is_err());
        assert!(!fresh.calls.contains(&"resume".to_string()));
    }

    #[test]
    fn a_sealed_disk_never_gets_a_new_password_for_a_wrong_passphrase() {
        let app = reach_summary();
        let (_, user) = app.secrets().unwrap();
        let typed = SecretBuf::new("a-different-one");
        let mut fake = FakeApplier::in_state(DiskState::Sealed, "sardines1");
        assert!(run_apply(&mut fake, b"ombra-disk", &typed, &user).is_err());
        assert_eq!(fake.calls, vec!["disk_state", "verify_sealed"]);
        assert!(!fake.calls.contains(&"set_user_password".to_string()));
    }

    #[test]
    fn the_build_passphrase_is_refused_everywhere_it_can_reach_cryptsetup() {
        let app = reach_summary();
        let (_, user) = app.secrets().unwrap();
        let public = SecretBuf::new(crate::BUILD_PASSPHRASE);
        let mut fake = FakeApplier::in_state(DiskState::Reencrypting, crate::BUILD_PASSPHRASE);
        assert!(run_apply(&mut fake, b"ombra-disk", &public, &user).is_err());
        assert!(run_resume(&mut fake, &public).is_err());
        assert!(fake.calls.is_empty(), "{:?}", fake.calls);
        assert!(forbid_build_passphrase(&public).is_err());
        assert!(SystemApplier.add_user_key(b"x", &public).is_err());
        assert!(SystemApplier.reencrypt(&public, true).is_err());
    }

    #[test]
    fn the_resume_screen_refuses_the_build_passphrase() {
        let mut app = Welcome::resuming();
        type_into(&mut app, crate::BUILD_PASSPHRASE);
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert!(app.resume_secret().is_none());
        assert_eq!(
            app.note(),
            Some((
                "that is the public build passphrase - choose your own",
                Severity::Bad
            ))
        );
    }

    #[test]
    fn the_build_slot_is_never_removed_when_it_is_the_users_slot() {
        assert!(ensure_distinct_slots(1, 0).is_ok());
        assert!(ensure_distinct_slots(0, 0).is_err());
    }

    #[test]
    fn json_metadata_reports_unfinished_reencryption() {
        let idle = r#"{"keyslots":{"0":{"type":"luks2","key_size":64}},"config":{"json_size":"12288","keyslots_size":"16744448"}}"#;
        assert!(!reencrypt_in_json(idle));
        assert!(!reencrypt_in_json(""));
        let slot =
            r#"{"keyslots":{"0":{"type":"luks2"},"2":{ "type" : "reencrypt","mode":"reencrypt"}}}"#;
        assert!(reencrypt_in_json(slot));
        let req =
            r#"{"keyslots":{},"config":{"requirements":{"mandatory":["online-reencrypt-v2"]}}}"#;
        assert!(reencrypt_in_json(req));
        let off = "{\"config\":{\"requirements\":{\"mandatory\":[\"offline-reencrypt\"]}}}";
        assert!(reencrypt_in_json(off));
    }

    #[test]
    fn the_resume_screen_collects_one_passphrase_and_returns_on_failure() {
        let mut app = Welcome::resuming();
        assert_eq!(app.screen(), Screen::Resume);
        type_into(&mut app, "short");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert_eq!(
            app.note(),
            Some(("use at least 8 characters", Severity::Bad))
        );
        for _ in 0..5 {
            app.on_key(key(KeyCode::Backspace));
        }
        type_into(&mut app, "sardines1");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::StartResume);
        assert_eq!(app.resume_secret().unwrap().expose(), "sardines1");
        app.begin_apply();
        app.apply_failed("that passphrase does not open the disk");
        assert_eq!(app.screen(), Screen::Resume);
        assert!(app.resume_field().is_empty());
        assert!(app.resume_secret().is_none());
    }

    #[test]
    fn the_resume_and_progress_screens_say_it_plainly() {
        let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
        let mut app = Welcome::resuming();
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(all.contains("finish encrypting your disk"));
        app.begin_apply();
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(all.contains("re-encrypting"));
        assert!(all.contains("do not power off"));
        for (w, h) in [(80u16, 25u16), (40, 14), (20, 6)] {
            let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
            t.draw(|f| draw(f, &app)).unwrap();
        }
    }

    #[test]
    fn only_exit_two_is_a_wrong_passphrase() {
        assert_eq!(passphrase_verdict(Some(0)).unwrap(), true);
        assert_eq!(passphrase_verdict(Some(2)).unwrap(), false);
        for code in [Some(1), Some(3), Some(4), Some(5), Some(127), Some(255)] {
            assert!(
                passphrase_verdict(code).is_err(),
                "{code:?} must fail closed"
            );
        }
        assert!(passphrase_verdict(None).is_err());
    }

    #[test]
    fn the_gate_treats_a_pending_reencrypt_as_incomplete_whatever_the_build_key_says() {
        // build key dead but re-encryption unfinished: not sealed, and the key is never even probed
        let state = disk_state_from(true, || panic!("probed the build key")).unwrap();
        assert_eq!(state, DiskState::Reencrypting);
        assert_eq!(
            disk_state_from(false, || Ok(false)).unwrap(),
            DiskState::Sealed
        );
        assert_eq!(
            disk_state_from(false, || Ok(true)).unwrap(),
            DiskState::Fresh
        );
        // a probe error is an error, never "sealed"
        assert!(disk_state_from(false, || bail!("exit 5")).is_err());
    }

    #[test]
    fn the_post_condition_demands_all_three() {
        assert!(sealed_verdict(DiskState::Sealed, false, true).is_ok());
        assert!(sealed_verdict(DiskState::Reencrypting, false, true).is_err());
        assert!(sealed_verdict(DiskState::Fresh, true, true).is_err());
        assert!(sealed_verdict(DiskState::Sealed, true, true).is_err());
        assert!(sealed_verdict(DiskState::Sealed, false, false).is_err());
    }

    #[test]
    fn reencrypt_progress_is_read_from_the_header() {
        assert!(!reencrypt_in_progress(LIVE_LUKSDUMP));
        let mid = LIVE_LUKSDUMP.replace(
            "Flags:       \t(no flags)\n",
            "Flags:       \t(no flags)\nRequirements:\tonline-reencrypt-v2\n",
        );
        assert!(reencrypt_in_progress(&mid));
        let slot_only = LIVE_LUKSDUMP.replace(
            "Tokens:",
            "  2: reencrypt\n\tMode:       reencrypt\n\tDirection:  forward\nTokens:",
        );
        assert!(reencrypt_in_progress(&slot_only));
        assert!(!reencrypt_in_progress("Requirements:\t(none)\n"));
        assert!(!reencrypt_in_progress(""));
    }

    #[test]
    fn reencrypt_argv_pins_cost_resilience_and_the_users_key() {
        let fresh = reencrypt_args("root_crypt", "/dev/nvme0n1p4", 1, false);
        let joined = fresh.join(" ");
        for want in [
            "reencrypt --batch-mode --key-file /run/ombra-new-key --key-slot 1 --active-name root_crypt",
            "--cipher aes-xts-plain64 --key-size 512",
            "--pbkdf argon2id --pbkdf-memory 1048576 --pbkdf-parallel 2 --pbkdf-force-iterations 4",
            "--resilience checksum",
        ] {
            assert!(joined.contains(want), "{joined}");
        }
        assert!(!joined.contains("--keep-key"));
        assert!(!joined.contains("ombra-build-key"));
        assert_eq!(fresh.last().unwrap(), "/dev/nvme0n1p4");

        let resume = reencrypt_args("root_crypt", "/dev/nvme0n1p4", 1, true).join(" ");
        assert!(resume.contains("--resume-only"));
        assert!(!resume.contains("--cipher"));
        assert!(!resume.contains("--pbkdf"));
    }

    #[test]
    fn reencrypt_failures_are_plain() {
        assert_eq!(reencrypt_failure(Some(0), ""), None);
        assert!(reencrypt_failure(Some(2), "")
            .unwrap()
            .contains("does not open"));
        assert!(reencrypt_failure(Some(1), " no space \n")
            .unwrap()
            .contains("no space"));
        assert!(reencrypt_failure(None, "").is_some());
    }

    #[test]
    fn the_add_key_argv_authenticates_with_the_build_key_only() {
        let a = luks_add_key_args("/dev/x");
        assert!(a.windows(2).any(|w| w == ["--key-file", BUILD_KEYFILE]));
        assert!(a.windows(2).any(|w| w == ["--new-keyfile", NEW_KEYFILE]));
        assert_eq!(a.last().unwrap(), "/dev/x");
    }

    #[test]
    fn the_root_mapping_name_comes_from_the_crypttab_target() {
        let ancestry = dm_ancestors(LIVE_DM_TREE, "vg0-root");
        assert_eq!(
            resolve_root_luks_mapping(LIVE_CRYPTTAB, &ancestry, TWO_LUKS_BLKID),
            Some(("nvme0n1p4_crypt".to_string(), "/dev/nvme0n1p4".to_string()))
        );
    }

    #[test]
    fn apply_failure_sends_the_user_back_to_screen_two() {
        let mut app = reach_summary();
        app.begin_apply();
        app.apply_failed("rotating the disk key failed: boom");
        assert_eq!(app.screen(), Screen::DiskPassphrase);
        assert_eq!(
            app.note(),
            Some(("rotating the disk key failed: boom", Severity::Bad))
        );
        assert!(app.active_flow().active_field().is_empty());
        type_into(&mut app, "newpass99");
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "newpass99");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::UserPassword);
    }

    #[test]
    fn apply_stops_at_the_first_failing_step() {
        let app = reach_summary();
        let (disk, user) = app.secrets().unwrap();

        // chpasswd failure: nothing else is touched
        let mut fake = FakeApplier::failing_at("set_user_password");
        assert!(run_apply(&mut fake, b"ombra-disk", &disk, &user).is_err());
        assert_eq!(fake.calls, vec!["disk_state", "set_user_password"]);

        // key-add failure after chpasswd: the password already landed, the volume key untouched
        let mut fake = FakeApplier::failing_at("luksAddKey");
        assert!(run_apply(&mut fake, b"ombra-disk", &disk, &user).is_err());
        assert_eq!(
            fake.calls,
            vec!["disk_state", "set_user_password", "luksAddKey"]
        );
    }

    /// Real cryptsetup `luksDump` from the live machine — THE regression pin.
    const LIVE_LUKSDUMP: &str = "\
LUKS header information
Version:       \t2
Epoch:         \t4
Metadata area: \t16384 [bytes]
Keyslots area: \t16744448 [bytes]
UUID:          \tb1052eac-b952-48d8-9e5b-ecc290109c71
Label:         \t(no label)
Subsystem:     \t(no subsystem)
Flags:       \t(no flags)

Data segments:
  0: crypt
\toffset: 16777216 [bytes]
\tlength: (whole device)
\tcipher: aes-xts-plain64
\tsector: 512 [bytes]

Keyslots:
  0: luks2
\tKey:        512 bits
\tPriority:   normal
\tCipher:     aes-xts-plain64
\tCipher key: 512 bits
\tPBKDF:      argon2id
\tTime cost:  13
\tMemory:     1048576
\tThreads:    4
\tSalt:       26 fd 5f b2 90 a0 2a 9e a3 b4 4f b8 f3 6e d1 d3
\t            42 b4 35 4a 59 37 2e 49 7a de b2 a1 45 bc af 80
\tAF stripes: 4000
\tAF hash:    sha256
\tArea offset:32768 [bytes]
\tArea length:258048 [bytes]
\tDigest ID:  0
  1: luks2
\tKey:        512 bits
\tPriority:   normal
\tCipher:     aes-xts-plain64
\tCipher key: 512 bits
\tPBKDF:      argon2id
\tTime cost:  4
\tMemory:     262144
\tThreads:    2
\tSalt:       95 b1 b8 50 71 45 02 b4 ec ea d6 9d 0c 5c c0 ee
\t            17 bf 33 24 1d 9f d4 b2 0c cc 1c 54 51 81 61 35
\tAF stripes: 4000
\tAF hash:    sha256
\tArea offset:290816 [bytes]
\tArea length:258048 [bytes]
\tDigest ID:  0
Tokens:
Digests:
  0: pbkdf2
\tHash:       sha256
\tIterations: 587766
\tSalt:       9f e4 23 ea c6 75 52 18 39 89 0e cd 23 88 60 af
\t            05 bc 7e 8d 58 d3 d7 a5 0f 55 b5 f5 2f 9e b9 63
\tDigest:     a9 cd 5c 04 4e 1a 3f 39 bd f5 e4 05 b2 4e 6a 90
\t            df ba e3 31 fe 45 fb 85 6d 41 ec 58 21 4f 52 3c
";

    #[test]
    fn keyslot_parsing_reads_the_dump_block_only() {
        let dump = "\
LUKS header information
Version:        2
Keyslots:
  0: luks2
    Key:        512 bits
  5: luks2
    Key:        512 bits
Tokens:
  0: ...
";
        assert_eq!(parse_keyslots(dump), vec![0, 5]);
        assert_eq!(parse_keyslots("no keyslots here\n"), Vec::<u32>::new());
    }

    #[test]
    fn keyslot_parsing_reads_the_real_live_dump() {
        assert_eq!(parse_keyslots(LIVE_LUKSDUMP), vec![0, 1]);
        assert!(check_argon2id(LIVE_LUKSDUMP).is_ok());
    }

    #[test]
    fn created_slots_is_after_minus_before() {
        assert_eq!(created_slots(&[0], &[0, 1]), vec![1]);
        assert_eq!(created_slots(&[0, 1], &[0, 1, 2]), vec![2]);
        assert_eq!(created_slots(&[1, 3], &[0, 1, 3]), vec![0]);
        assert_eq!(created_slots(&[0, 1], &[0, 1]), Vec::<u32>::new());
        assert_eq!(created_slots(&[], &[2, 0, 2]), vec![0, 2]);
    }

    #[test]
    fn the_kill_list_never_touches_what_the_add_created() {
        for (before, after) in [
            (vec![0], vec![0, 1]),
            (vec![0, 1], vec![0, 1, 2]),
            (vec![1, 3], vec![0, 1, 3]),
        ] {
            let created = created_slots(&before, &after);
            assert!(!created.is_empty(), "no created slot: the run must abort");
            for slot in &before {
                assert!(!created.contains(slot), "kill list hits a fresh slot");
            }
        }
    }

    /// The installed crypttab shape (late-command's pinned root tuple plus the swap line).
    const LIVE_CRYPTTAB: &str = "\
nvme0n1p4_crypt UUID=8f32ab90-dead-beef-cafe-1234567890ab none luks,discard,x-initrd.attach,keyscript=/usr/local/libexec/ombra/ombra-askpass,tries=0
cryptswap /dev/vg0/swap_1 /dev/urandom cipher=aes-xts-plain64,size=512,swap
";

    /// A foreign crypto_LUKS listed BEFORE the real container — a first-hit guess would pick it.
    const TWO_LUKS_BLKID: &str = "\
/dev/nvme1n1: UUID=\"aaaaaaaa-0000-1111-2222-333333333333\" TYPE=\"crypto_LUKS\"
/dev/nvme0n1p4: UUID=\"8f32ab90-dead-beef-cafe-1234567890ab\" TYPE=\"crypto_LUKS\" PARTUUID=\"3333-4444\"
/dev/nvme0n1p2: UUID=\"ef20b8f4-0000-0000-0000-000000000000\" TYPE=\"ext4\"
";

    #[test]
    fn lsblk_tree_glyphs_do_not_leak_into_the_root_name() {
        let out = "nvme0n1\n\u{251c}\u{2500}nvme0n1p1 /boot/efi\n\u{2514}\u{2500}nvme0n1p4\n  \u{2514}\u{2500}nvme0n1p4_crypt\n    \u{251c}\u{2500}ombra--vg-root /\n    \u{2514}\u{2500}ombra--vg-swap_1\n";
        assert_eq!(parse_lsblk_root(out).as_deref(), Some("ombra--vg-root"));
        let ascii = "nvme0n1\n|-nvme0n1p1 /boot/efi\n`-nvme0n1p4\n  `-nvme0n1p4_crypt\n    |-ombra--vg-root /\n";
        assert_eq!(parse_lsblk_root(ascii).as_deref(), Some("ombra--vg-root"));
    }

    #[test]
    fn dmsetup_ascii_tree_resolves_the_crypt_ancestor() {
        let tree = "ombra--vg-root (254:1)\n `-nvme0n1p4_crypt (254:0)\nombra--vg-swap_1 (254:2)\n `-nvme0n1p4_crypt (254:0)\n";
        let got = dm_ancestors(tree, "ombra--vg-root");
        assert!(got.contains(&"nvme0n1p4_crypt".to_string()), "{got:?}");
    }

    /// `dmsetup ls --tree` shape on the installed layout: LVM LVs over the LUKS container.
    const LIVE_DM_TREE: &str = "\
vg0-root (254:1)
 \u{251c}\u{2500}nvme0n1p4_crypt (254:0)
 \u{2514}\u{2500}vg0-swap (254:2)
vg0-swap (254:2)
 \u{2514}\u{2500}nvme0n1p4_crypt (254:0)
nvme0n1p4_crypt (254:0)
 \u{2514}\u{2500} (259:4)
";

    #[test]
    fn dm_ancestry_walks_from_root_through_the_luks_container() {
        assert_eq!(
            dm_ancestors(LIVE_DM_TREE, "vg0-root"),
            vec!["vg0-root", "nvme0n1p4_crypt", "vg0-swap"]
        );
        assert_eq!(
            dm_ancestors(LIVE_DM_TREE, "nvme0n1p4_crypt"),
            vec!["nvme0n1p4_crypt"]
        );
        assert_eq!(
            dm_ancestors(LIVE_DM_TREE, "no-such-device"),
            vec!["no-such-device"]
        );
    }

    #[test]
    fn lsblk_parsing_finds_the_root_mount_only() {
        let out = "\
nvme0n1
nvme0n1p1 /boot/efi
nvme0n1p2 /boot
nvme0n1p4
vg0-root /
vg0-swap [SWAP]
";
        assert_eq!(parse_lsblk_root(out).as_deref(), Some("vg0-root"));
        assert_eq!(parse_lsblk_root(""), None);
        let amnesic = "nvme0n1p4_crypt\nvg0-root /media/root-ro\nnvme0n1p3 /media/root-ro/boot\n";
        assert_eq!(parse_lsblk_root(amnesic).as_deref(), Some("vg0-root"));
    }

    #[test]
    fn root_resolution_picks_the_container_behind_root_not_the_first_blkid_hit() {
        let ancestry = dm_ancestors(LIVE_DM_TREE, "vg0-root");
        let dev = resolve_root_luks(LIVE_CRYPTTAB, &ancestry, TWO_LUKS_BLKID).unwrap();
        assert_eq!(dev, "/dev/nvme0n1p4");
    }

    #[test]
    fn a_literal_dev_crypttab_source_resolves_without_blkid() {
        let ancestry = vec!["vg0-root".to_string(), "rootdev".to_string()];
        assert_eq!(
            resolve_root_luks("rootdev /dev/nvme0n1p4 none luks\n", &ancestry, ""),
            Some("/dev/nvme0n1p4".to_string())
        );
    }

    #[test]
    fn root_resolution_fails_closed_on_bad_crypttab() {
        let ancestry = dm_ancestors(LIVE_DM_TREE, "vg0-root");
        // empty / blank / comment-only
        assert_eq!(resolve_root_luks("", &ancestry, TWO_LUKS_BLKID), None);
        assert_eq!(
            resolve_root_luks("   \n# just a comment\n", &ancestry, TWO_LUKS_BLKID),
            None
        );
        // malformed line: no resolvable pair
        assert_eq!(
            resolve_root_luks("onlytarget\n", &ancestry, TWO_LUKS_BLKID),
            None
        );
        // a target off the root ancestry is ignored even when its source resolves
        assert_eq!(
            resolve_root_luks(
                "cryptswap /dev/vg0/swap_1 /dev/urandom swap\n",
                &ancestry,
                TWO_LUKS_BLKID
            ),
            None
        );
        // the root target's UUID missing from blkid is a failure, never a guess
        assert_eq!(
            resolve_root_luks(
                "nvme0n1p4_crypt UUID=00000000-dead-beef-cafe-111111111111 none luks\n",
                &ancestry,
                TWO_LUKS_BLKID
            ),
            None
        );
    }

    #[test]
    fn argon2id_check_accepts_luks2_and_rejects_other_pbkdf() {
        let dump = "\
LUKS header information
Version:           2
Keyslots:
  0: pbkdf
      Hash:       sha256
      PBKDF:      argon2id
      Time cost:  4
";
        assert!(check_argon2id(dump).is_ok());
        let argon2i = dump.replace("argon2id", "argon2i");
        assert!(check_argon2id(&argon2i)
            .err()
            .unwrap()
            .to_string()
            .contains("not argon2id"));
        assert!(check_argon2id("Version: 1\nPayload offset: 4096\n").is_err());
    }

    #[test]
    fn screens_render_at_console_and_tiny_sizes() {
        for (w, h) in [(160u16, 50u16), (80, 24), (40, 14), (20, 6)] {
            let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
            let mut app = reach_summary();
            terminal.draw(|f| draw(f, &app)).unwrap();
            app.begin_apply();
            terminal.draw(|f| draw(f, &app)).unwrap();
            app.apply_failed("rotating the disk key failed: boom");
            terminal.draw(|f| draw(f, &app)).unwrap();
        }
    }

    #[test]
    fn console_palette_is_ansi_256_only_at_every_size() {
        use ratatui::style::Color;
        for (w, h) in [(160u16, 50u16), (100, 30), (80, 25)] {
            let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
            let mut app = reach_summary();
            terminal.draw(|f| draw(f, &app)).unwrap();
            app.begin_apply();
            terminal.draw(|f| draw(f, &app)).unwrap();
            app.apply_failed("rotating the disk key failed: boom");
            terminal.draw(|f| draw(f, &app)).unwrap();
            let buf = terminal.backend().buffer();
            for y in 0..buf.area.height {
                for x in 0..buf.area.width {
                    let cell = &buf[(x, y)];
                    assert!(
                        matches!(cell.fg, Color::Reset | Color::Indexed(_)),
                        "{w}x{h} cell ({x},{y}) fg {:?} is not 256-color",
                        cell.fg
                    );
                    assert!(
                        matches!(cell.bg, Color::Reset | Color::Indexed(_)),
                        "{w}x{h} cell ({x},{y}) bg {:?} is not 256-color",
                        cell.bg
                    );
                }
            }
        }
    }

    #[test]
    fn the_field_screen_fits_the_boot_console_80x25() {
        let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer();
        let rows: Vec<String> = (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect();
        let all = rows.join("\n");
        assert!(all.contains("set your disk encryption passphrase"));
        assert!(rows.iter().any(|r| r.contains('\u{256d}')));
        assert!(rows.iter().any(|r| r.contains('\u{2570}')));
        assert!(rows[0].contains(art::ring_rows(25)[0].trim()));
    }

    #[test]
    fn welcome_screen_renders_the_official_copy() {
        let mut terminal = Terminal::new(TestBackend::new(160, 50)).unwrap();
        let app = Welcome::new();
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer();
        let all: String = (0..buf.area.height)
            .map(|y| {
                (0..buf.area.width)
                    .map(|x| buf[(x, y)].symbol())
                    .collect::<String>()
            })
            .collect();
        for expected in [
            "WELCOME TO OMBRA",
            "om\u{b7}bra  /'om.br\u{e4}/",
            "1. shadow.",
            "you were never here.",
            "enter",
            "begin",
        ] {
            assert!(all.contains(expected), "missing copy: {expected}");
        }
        assert!(!all.contains("two secrets protect it"));
    }

    fn buf_rows(buf: &ratatui::buffer::Buffer) -> Vec<String> {
        (0..buf.area.height)
            .map(|y| (0..buf.area.width).map(|x| buf[(x, y)].symbol()).collect())
            .collect()
    }

    fn cell(buf: &ratatui::buffer::Buffer, x: usize, y: usize) -> &ratatui::buffer::Cell {
        &buf[(x as u16, y as u16)]
    }

    #[test]
    fn field_screen_plain_register_white_title_on_the_box_edge_at_128x48() {
        let mut terminal = Terminal::new(TestBackend::new(128, 48)).unwrap();
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        let all = rows.join("\n");
        assert!(!all.contains("[+]"), "no [+] tags may render:\n{all}");
        assert!(!all.contains("[-]"), "no [-] tags may render:\n{all}");
        assert!(all.contains("set your disk encryption passphrase"));
        assert!(all.contains("LUKS2 \u{b7} AES-256-XTS \u{b7} argon2id"));

        let field_x = ((128u16 - theme::FIELD_WIDTH) / 2) as usize;
        let title_y = rows
            .iter()
            .position(|r| r.contains("set your disk"))
            .unwrap();
        let title_x = rows[title_y].find("set your disk").unwrap();
        assert_eq!(title_x, field_x, "title left-aligned to the box edge");
        assert_eq!(
            cell(&buf, field_x, title_y).fg,
            theme::TEXT,
            "title is WHITE"
        );
        assert_eq!(cell(&buf, field_x, title_y + 1).symbol(), "\u{256d}");
        let info_y = rows.iter().position(|r| r.contains("LUKS2")).unwrap();
        let info_x = rows[info_y].find("LUKS2").unwrap();
        assert_eq!(info_x, field_x, "info line left-aligned to the box edge");
        assert_eq!(cell(&buf, field_x, info_y).fg, theme::LABEL);
        assert_eq!(
            cell(&buf, field_x + 6, info_y).fg,
            theme::ACCENT,
            "middle dots are indigo"
        );
    }

    #[test]
    fn confirm_box_spawns_below_the_first_at_80x25() {
        let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
        let field_x = ((80u16 - theme::FIELD_WIDTH) / 2) as usize;
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");

        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        let title_y = rows
            .iter()
            .position(|r| r.contains("set your disk"))
            .unwrap();
        assert_eq!(
            cell(&buf, field_x, title_y + 1).symbol(),
            "\u{256d}",
            "box 1"
        );
        assert_ne!(
            cell(&buf, field_x, title_y + 4).symbol(),
            "\u{256d}",
            "no second box yet"
        );

        app.on_key(key(KeyCode::Enter));
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        assert_eq!(
            cell(&buf, field_x, title_y + 1).symbol(),
            "\u{256d}",
            "box 1 stays"
        );
        assert_eq!(
            cell(&buf, field_x, title_y + 4).symbol(),
            "\u{256d}",
            "box 2 spawned directly below"
        );
        let msg_y = rows
            .iter()
            .position(|r| r.contains("repeat it to confirm"))
            .unwrap();
        assert_eq!(msg_y, title_y + 7, "status line hugs box 2");
        assert_eq!(rows[msg_y].find("repeat it to confirm").unwrap(), field_x);
        assert_eq!(cell(&buf, field_x, msg_y).fg, theme::MUTED);
        assert!(!rows.join("\n").contains("[-]"));
    }

    #[test]
    fn validation_lines_are_plain_bad_red() {
        let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
        let field_x = ((80u16 - theme::FIELD_WIDTH) / 2) as usize;
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "short");
        app.on_key(key(KeyCode::Enter));
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        let msg_y = rows
            .iter()
            .position(|r| r.contains("use at least 8 characters"))
            .unwrap();
        assert_eq!(
            rows[msg_y].find("use at least 8 characters").unwrap(),
            field_x
        );
        assert_eq!(
            cell(&buf, field_x, msg_y).fg,
            theme::BAD,
            "validation is BAD red, no [-] tag"
        );
        assert!(!rows.join("\n").contains("[-]"));
        assert_eq!(app.active_flow().active_field().value(), "short");
    }

    #[test]
    fn the_static_info_line_retracts_once_the_confirm_box_is_up() {
        const LUKS2: &str = "LUKS2 \u{b7} AES-256-XTS \u{b7} argon2id";
        const ACCOUNT: &str = "the password for the account \"ombra\"";
        let mut terminal = Terminal::new(TestBackend::new(80, 25)).unwrap();
        let mut app = Welcome::new();
        app.on_key(key(KeyCode::Enter));
        type_into(&mut app, "sardines1");
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(
            all.contains(LUKS2),
            "tech line shows before the first box is accepted"
        );
        assert!(!all.contains("repeat it to confirm"));

        app.on_key(key(KeyCode::Enter));
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(all.contains("repeat it to confirm"));
        assert!(
            !all.contains(LUKS2),
            "the tech line must not repeat under the confirm box"
        );

        type_into(&mut app, "sardines1");
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(!all.contains(LUKS2));
        assert!(!all.contains("repeat it to confirm"));

        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.screen(), Screen::UserPassword);
        type_into(&mut app, "hunter2xyz");
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(all.contains(ACCOUNT));
        app.on_key(key(KeyCode::Enter));
        terminal.draw(|f| draw(f, &app)).unwrap();
        let all = buf_rows(terminal.backend().buffer()).join("\n");
        assert!(all.contains("repeat it to confirm"));
        assert!(
            !all.contains(ACCOUNT),
            "the account line must not repeat either"
        );
    }

    #[test]
    fn wordmark_rules_and_amber_warning_render_at_80x24() {
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        let mut app = Welcome::new();
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        let brand_y = rows.iter().position(|r| r.contains("O M B R A")).unwrap();
        let field_x = ((80u16 - theme::FIELD_WIDTH) / 2) as usize;
        assert_eq!(cell(&buf, field_x, brand_y).symbol(), "\u{2500}");
        assert_eq!(cell(&buf, field_x, brand_y).fg, theme::RULE);
        assert!(
            rows.iter().any(|r| r.contains(" enter  begin")),
            "keycap hint fits 80x24"
        );

        app.begin_apply();
        terminal.draw(|f| draw(f, &app)).unwrap();
        let buf = terminal.backend().buffer().clone();
        let rows = buf_rows(&buf);
        let y = rows
            .iter()
            .position(|r| r.contains("do not power off"))
            .unwrap();
        let x = rows[y].find("do not").unwrap();
        assert_eq!(cell(&buf, x, y).fg, theme::AMBER);
    }

    #[test]
    fn amnesic_boot_matches_whole_overlayroot_tokens() {
        assert!(amnesic_boot("quiet overlayroot=tmpfs splash"));
        assert!(amnesic_boot("overlayroot=tmpfs\n"));
        assert!(amnesic_boot("overlayroot=tmpfs:recurse=0"));
        assert!(amnesic_boot("overlayroot=disabled overlayroot=tmpfs"));
        assert!(!amnesic_boot("quiet overlayroot=disabled"));
        assert!(!amnesic_boot("overlayroot="));
        assert!(!amnesic_boot("xoverlayroot=tmpfs"));
        assert!(!amnesic_boot("foo=overlayroot=tmpfs"));
        assert!(!amnesic_boot("quiet splash"));
        assert!(!amnesic_boot(""));
    }

    #[test]
    fn the_persistent_notice_fits_80x24_and_80x25_and_restarts_on_enter() {
        for (w, h) in [(80u16, 24u16), (80, 25)] {
            let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
            let app = Welcome::needs_persistent();
            terminal.draw(|f| draw(f, &app)).unwrap();
            let rows = buf_rows(terminal.backend().buffer());
            let all = rows.join("\n");
            assert!(all.contains("restart in persistent mode"), "{w}x{h}");
            assert!(all.contains("first-time setup needs a disk that remembers."));
            assert!(all.contains("restart and choose Persistent at the boot menu."));
            assert!(
                rows.iter().any(|r| r.contains(" enter  restart")),
                "{w}x{h}"
            );
            assert!(rows.iter().any(|r| r.contains("O M B R A")));
        }
    }

    #[test]
    fn the_persistent_notice_only_answers_enter_with_restart() {
        let mut app = Welcome::needs_persistent();
        assert_eq!(app.screen(), Screen::NeedsPersistent);
        assert_eq!(app.on_key(key(KeyCode::Char('x'))), Action::None);
        assert_eq!(app.on_key(key(KeyCode::Esc)), Action::None);
        assert_eq!(app.screen(), Screen::NeedsPersistent);
        assert!(app.secrets().is_none());
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::Restart);
        app.begin_restart();
        assert_eq!(app.screen(), Screen::Rebooting);
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
    }
}
