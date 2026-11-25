//! Keyscript mode: cryptroot invokes once per passphrase attempt; the passphrase is one line on STDOUT, the TUI on /dev/tty1.

use std::fs;
use std::io::{self, Read as _, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crossterm::event::KeyEvent;
use zeroize::Zeroize;

use crate::input::{FieldEvent, SecretField, Severity};
use crate::theme;

pub const SPLASH: Duration = Duration::from_millis(1500);
pub const RETRY_MESSAGE: &str = "that passphrase didn't decrypt - try again";
pub const TOO_SHORT_MESSAGE: &str = "use at least 8 characters";
/// Enter on an empty unlock field (entering a passphrase has no length rule; choosing one does).
pub const EMPTY_MESSAGE: &str = "type your passphrase, then press enter";
pub const MARKER_PREFIX: &str = "askpass-attempts";

pub fn marker_path(name: Option<&str>) -> PathBuf {
    // the name comes from the environment: only a plain mapping name may become part of a path root writes to
    let name = name
        .filter(|n| !n.is_empty() && n.len() <= 64 && n.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.')) && !n.starts_with('.'))
        .unwrap_or("unknown");
    PathBuf::from("/run/ombra").join(format!("{MARKER_PREFIX}-{name}"))
}

pub fn read_attempts(marker: &Path) -> u32 {
    fs::read_to_string(marker)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

pub fn bump_attempts(marker: &Path) -> io::Result<u32> {
    let prev = read_attempts(marker);
    if let Some(parent) = marker.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(marker, format!("{}\n", prev.saturating_add(1)))?;
    Ok(prev)
}

// ---- the in-boot "build key is dead" record (keyscript writes, setup gate reads) ----

/// Root-only record: THIS boot's keyscript got cryptsetup's "no key matches" (exit 2) for the build key.
pub const DEAD_RECORD: &str = "/run/ombra/gate/build-key-dead";
pub const BOOT_ID: &str = "/proc/sys/kernel/random/boot_id";

/// The record binds the verdict to one boot and one block device (st_rdev).
pub fn dead_record_body(boot_id: &str, rdev: u64) -> Option<String> {
    let id = boot_id.trim();
    if id.is_empty() || id.contains(char::is_whitespace) {
        return None;
    }
    Some(format!("boot {id} dev {rdev}\n"))
}

/// This boot's body for `device`; None unless the boot id reads and `device` is a block device.
pub fn dead_record_body_for(device: &Path) -> Option<String> {
    let m = fs::metadata(device).ok()?;
    if !m.file_type().is_block_device() {
        return None;
    }
    dead_record_body(&fs::read_to_string(BOOT_ID).ok()?, m.rdev())
}

/// Only exit 2 is recorded; every other outcome clears the record so it can never vouch for a live key.
pub fn note_build_key_test(record: &Path, exit: Option<i32>, body: Option<&str>) -> bool {
    let dead = exit == Some(2);
    let written = match (dead, body) {
        (true, Some(b)) => write_dead_record(record, b).is_ok(),
        _ => false,
    };
    if !written {
        let _ = fs::remove_file(record);
    }
    dead
}

/// Dir 0700, file 0600, created fresh (never through a symlink).
pub fn write_dead_record(record: &Path, body: &str) -> io::Result<()> {
    let dir = record
        .parent()
        .ok_or_else(|| io::Error::other("record path has no directory"))?;
    if let Some(up) = dir.parent() {
        fs::create_dir_all(up)?;
    }
    match fs::DirBuilder::new().mode(0o700).create(dir) {
        Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
        _ => {}
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let _ = fs::remove_file(record);
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(record)?;
    f.write_all(body.as_bytes())
}

/// True only for a regular, single-link file owned by `owner` with no group/other bits, in a dir with the same
/// rule, on tmpfs, whose body is exactly `want`. Anything else means "derive".
pub fn dead_record_holds(
    record: &Path,
    want: &str,
    owner: u32,
    on_tmpfs: &dyn Fn(&fs::File) -> bool,
) -> bool {
    let private = |m: &fs::Metadata| m.uid() == owner && m.mode() & 0o077 == 0;
    let Some(dir) = record.parent() else {
        return false;
    };
    match fs::symlink_metadata(dir) {
        Ok(m) if m.is_dir() && private(&m) => {}
        _ => return false,
    }
    // O_NOFOLLOW: a symlink fails the open; O_NONBLOCK: a fifo cannot wedge the gate
    let Ok(f) = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(record)
    else {
        return false;
    };
    match f.metadata() {
        Ok(m) if m.file_type().is_file() && m.nlink() == 1 && private(&m) => {}
        _ => return false,
    }
    if !on_tmpfs(&f) {
        return false;
    }
    let mut body = String::new();
    f.take(256).read_to_string(&mut body).is_ok() && body == want
}

/// A record on a disk-backed /run could outlive its boot: only tmpfs counts.
#[cfg(target_os = "linux")]
pub fn on_tmpfs(f: &fs::File) -> bool {
    use std::os::unix::io::AsRawFd as _;
    const TMPFS_MAGIC: u64 = 0x0102_1994;
    // SAFETY: statfs is plain data; fstatfs only writes into it.
    let mut s: libc::statfs = unsafe { std::mem::zeroed() };
    #[allow(clippy::unnecessary_cast)] // f_type's width differs per libc
    let ok = unsafe { libc::fstatfs(f.as_raw_fd(), &mut s) } == 0 && s.f_type as u64 == TMPFS_MAGIC;
    ok
}

#[cfg(not(target_os = "linux"))]
pub fn on_tmpfs(_f: &fs::File) -> bool {
    false
}

/// Key goes to stdout as EXACT bytes, NO trailing newline.
pub fn write_key(stdout: &mut dyn Write, key: &[u8]) -> std::io::Result<()> {
    stdout.write_all(key)?;
    stdout.flush()
}

/// The prompt arrives after `--keyscript` or as positional argv[1]; never displayed.
pub fn prompt_from_args(args: &[String]) -> Option<String> {
    if let Some(pos) = args.iter().position(|a| a == "--keyscript") {
        return args.get(pos + 1).cloned();
    }
    args.iter().skip(1).find(|a| !a.starts_with('-')).cloned()
}

/// Keyscript mode: the `--keyscript` flag, CRYPTTAB_NAME in the env, or any non-flag argv.
pub fn is_keyscript_invocation(args: &[String], env_has_crypttab_name: bool) -> bool {
    args.iter().any(|a| a == "--keyscript")
        || env_has_crypttab_name
        || args.iter().skip(1).any(|a| !a.starts_with('-'))
}

/// The tty side of keyscript mode; tests substitute a scripted fake.
pub trait KeyscriptUi {
    fn draw_splash(&mut self, pulse: usize);
    fn draw_unlock(&mut self, field: &SecretField, message: Option<(&str, Severity)>);
    /// Next keystroke, or None on the poll tick.
    fn next_key(&mut self) -> io::Result<Option<KeyEvent>>;
    fn tick_wait(&mut self, d: Duration);
}

/// Writes the passphrase to `stdout` as EXACT bytes, no trailing newline; exit stays 0 on a wrong guess (cryptsetup re-invokes).
pub fn run(
    stdout: &mut dyn Write,
    marker: &Path,
    ui: &mut dyn KeyscriptUi,
    build_key: &str,
    splash: Duration,
    build_key_dead: &mut dyn FnMut() -> bool,
) -> io::Result<()> {
    // an unwritable counter must never re-offer the build key: fall to the prompt
    let mut attempt = match bump_attempts(marker) {
        Ok(prev) => prev.saturating_add(1),
        Err(_) => read_attempts(marker).saturating_add(2).max(2),
    };

    // a set-up machine skips the doomed build-key attempt: straight to the prompt
    if attempt == 1 {
        // the splash is up during the slow test, never a bare console
        ui.draw_splash(0);
        if build_key_dead() {
            let _ = fs::write(marker, "2\n");
            attempt = 2;
        }
    }

    if attempt == 1 {
        // silently offer the build key
        let frames = (splash.as_millis() / u128::from(theme::PULSE_MS)) as usize;
        for pulse in 0..frames {
            ui.draw_splash(pulse);
            ui.tick_wait(Duration::from_millis(theme::PULSE_MS));
        }
        write_key(stdout, build_key.as_bytes())?;
        return Ok(());
    }

    // 3+: the last try failed
    let retry_hint = attempt >= 3;
    let mut field = SecretField::for_unlock("passphrase");
    let mut feedback: Option<&'static str> = None;
    loop {
        let message = feedback.map(|m| (m, Severity::Bad)).or({
            if retry_hint {
                Some((RETRY_MESSAGE, Severity::Bad))
            } else {
                None
            }
        });
        ui.draw_unlock(&field, message);
        // no key: static caret, nothing to blink
        if let Some(key) = ui.next_key()? {
            match field.handle_key(key) {
                FieldEvent::Submitted => {
                    let mut secret = field.take();
                    let sent = write_key(stdout, secret.as_bytes());
                    // plain String is not zeroize-on-drop
                    secret.zeroize();
                    sent?;
                    return Ok(());
                }
                FieldEvent::TooShort => feedback = Some(EMPTY_MESSAGE),
                FieldEvent::Edited => feedback = None,
                FieldEvent::Ignored => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;

    use crossterm::event::{KeyCode, KeyModifiers};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn tempdir(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("ombra-keyscript-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// Scripted UI: fails fast when the key script runs dry.
    struct FakeUi {
        keys: VecDeque<KeyEvent>,
        splash_draws: usize,
        unlock_draws: usize,
        /// Field state at the FIRST draw: must be empty on every re-invocation.
        first_draw_empty: Option<bool>,
        last_message: Option<String>,
        /// Draws in order, shared with a test's build-key closure.
        log: Rc<RefCell<Vec<&'static str>>>,
    }

    impl FakeUi {
        fn scripted(keys: Vec<KeyEvent>) -> Self {
            FakeUi {
                keys: keys.into(),
                splash_draws: 0,
                unlock_draws: 0,
                first_draw_empty: None,
                last_message: None,
                log: Rc::default(),
            }
        }
        fn typed(s: &str) -> Vec<KeyEvent> {
            let mut v: Vec<_> = s.chars().map(KeyCode::Char).map(key).collect();
            v.push(key(KeyCode::Enter));
            v
        }
    }

    impl KeyscriptUi for FakeUi {
        fn draw_splash(&mut self, _pulse: usize) {
            self.splash_draws += 1;
            self.log.borrow_mut().push("splash");
        }
        fn draw_unlock(&mut self, field: &SecretField, message: Option<(&str, Severity)>) {
            self.unlock_draws += 1;
            self.log.borrow_mut().push("unlock");
            if self.first_draw_empty.is_none() {
                self.first_draw_empty = Some(field.is_empty());
            }
            self.last_message = message.map(|(m, _)| m.to_string());
        }
        fn next_key(&mut self) -> io::Result<Option<KeyEvent>> {
            self.keys
                .pop_front()
                .map(Some)
                .ok_or_else(|| io::Error::other("key script exhausted"))
        }
        fn tick_wait(&mut self, _d: Duration) {}
    }

    fn args_with_keyscript(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["ombra-askpass".to_string(), "--keyscript".to_string()];
        v.extend(extra.iter().map(|s| s.to_string()));
        v
    }

    #[test]
    fn first_invocation_prints_the_build_key_silently() {
        let dir = tempdir("first");
        let marker = dir.join("askpass-attempts-vda3_crypt");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(vec![]);

        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO).unwrap();

        assert_eq!(out, b"ombra-disk");
        // only the pre-test splash frame: a zero splash animates nothing
        assert_eq!(ui.splash_draws, 1);
        assert_eq!(ui.unlock_draws, 0);
        assert_eq!(read_attempts(&marker), 1);
    }

    #[test]
    fn a_dead_build_key_goes_straight_to_the_prompt_and_counts_as_attempt_two() {
        let dir = tempdir("dead");
        let marker = dir.join("askpass-attempts-x");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        run(
            &mut out,
            &marker,
            &mut ui,
            "ombra-disk",
            Duration::ZERO,
            &mut || true,
        )
        .unwrap();
        assert_eq!(out, b"sardines1");
        assert_eq!(ui.splash_draws, 1, "one static frame while the test runs");
        assert_eq!(ui.last_message, None);
        assert_eq!(read_attempts(&marker), 2);
    }

    #[test]
    fn splash_frames_follow_the_pulse_period() {
        let dir = tempdir("splash");
        let marker = dir.join("askpass-attempts-x");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(vec![]);
        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::from_millis(1100)).unwrap();
        let want = Duration::from_millis(1100).as_millis() as usize / theme::PULSE_MS as usize;
        // + the frame drawn before the build-key test
        assert_eq!(ui.splash_draws, want + 1);
        assert_eq!(out, b"ombra-disk");
    }

    #[test]
    fn second_invocation_is_interactive_without_retry_copy() {
        let dir = tempdir("second");
        let marker = dir.join("askpass-attempts-vda3_crypt");
        fs::write(&marker, "1\n").unwrap();

        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO).unwrap();

        assert_eq!(out, b"sardines1");
        assert!(ui.unlock_draws > 0);
        assert_eq!(ui.first_draw_empty, Some(true));
        assert_eq!(ui.last_message, None);
        assert_eq!(read_attempts(&marker), 2);
    }

    #[test]
    fn third_invocation_shows_the_retry_line() {
        let dir = tempdir("third");
        let marker = dir.join("askpass-attempts-vda3_crypt");
        fs::write(&marker, "2\n").unwrap();

        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO).unwrap();

        assert_eq!(out, b"sardines1");
        assert_eq!(ui.last_message.as_deref(), Some(RETRY_MESSAGE),);
        assert_eq!(read_attempts(&marker), 3);
    }

    #[test]
    fn a_short_passphrase_can_unlock() {
        // the 8-character rule is for choosing a passphrase; a disk keyed with a shorter one must still open
        let dir = tempdir("short");
        let marker = dir.join("askpass-attempts-x");
        fs::write(&marker, "2\n").unwrap();
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("abc"));
        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO).unwrap();
        assert_eq!(out, b"abc");
    }

    #[test]
    fn the_marker_name_cannot_leave_its_directory() {
        assert_eq!(marker_path(Some("cryptroot")), PathBuf::from("/run/ombra/askpass-attempts-cryptroot"));
        assert_eq!(marker_path(Some("nvme0n1p3_crypt")), PathBuf::from("/run/ombra/askpass-attempts-nvme0n1p3_crypt"));
        for bad in ["../../etc/x", "a/b", "", "..", ".hidden", "a b", "x\n"] {
            assert_eq!(marker_path(Some(bad)), PathBuf::from("/run/ombra/askpass-attempts-unknown"), "{bad:?}");
        }
        let dir = tempdir("sat");
        let m = dir.join("m");
        fs::write(&m, "4294967295\n").unwrap();
        assert_eq!(bump_attempts(&m).unwrap(), u32::MAX);
        assert_eq!(read_attempts(&m), u32::MAX);
    }

    #[test]
    fn field_feedback_wins_over_the_retry_line() {
        let dir = tempdir("feedback");
        let marker = dir.join("askpass-attempts-x");
        fs::write(&marker, "2\n").unwrap();

        let mut out: Vec<u8> = Vec::new();
        // Enter on an empty field: the field's own message, and nothing is sent
        let mut ui = FakeUi::scripted(FakeUi::typed(""));
        let res = keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO);
        assert!(res.is_err());
        assert_eq!(ui.last_message, Some(EMPTY_MESSAGE.to_string()));
        assert_eq!(out, b"");
    }

    #[test]
    fn an_unwritable_counter_falls_to_the_prompt_never_the_build_key() {
        let dir = tempdir("unwritable");
        // the marker path is a directory: the write fails, the read yields 0
        let marker = dir.join("askpass-attempts-x");
        fs::create_dir_all(&marker).unwrap();
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO).unwrap();
        assert_eq!(out, b"sardines1");
        assert!(ui.unlock_draws > 0);
        assert_eq!(ui.splash_draws, 0);
    }

    #[test]
    fn marker_counts_attempts_per_target() {
        let dir = tempdir("marker");
        let marker = dir.join("askpass-attempts-nvme0n1p3_crypt");
        assert_eq!(read_attempts(&marker), 0);
        assert_eq!(bump_attempts(&marker).unwrap(), 0);
        assert_eq!(bump_attempts(&marker).unwrap(), 1);
        assert_eq!(bump_attempts(&marker).unwrap(), 2);
        assert_eq!(read_attempts(&marker), 3);
    }

    #[test]
    fn marker_path_is_per_crypttab_target() {
        assert_eq!(
            marker_path(Some("vda3_crypt")),
            PathBuf::from("/run/ombra/askpass-attempts-vda3_crypt")
        );
        assert_eq!(
            marker_path(None),
            PathBuf::from("/run/ombra/askpass-attempts-unknown")
        );
    }

    #[test]
    fn prompt_argument_follows_the_mode_flag() {
        assert_eq!(
            prompt_from_args(&args_with_keyscript(&["Please unlock disk vda3_crypt"])),
            Some("Please unlock disk vda3_crypt".to_string())
        );
        assert_eq!(prompt_from_args(&args_with_keyscript(&[])), None);
        assert_eq!(prompt_from_args(&["ombra-askpass".to_string()]), None);
    }

    #[test]
    fn prompt_argument_is_also_the_positional_argv_form() {
        let cryptroot = vec![
            "ombra-askpass".to_string(),
            "Please unlock disk nvme0n1p4_crypt:".to_string(),
        ];
        assert_eq!(
            prompt_from_args(&cryptroot),
            Some("Please unlock disk nvme0n1p4_crypt:".to_string())
        );
        assert_eq!(
            prompt_from_args(&[
                "ombra-askpass".to_string(),
                "--quiet".to_string(),
                "prompt here".to_string()
            ]),
            Some("prompt here".to_string())
        );
        assert_eq!(
            prompt_from_args(&args_with_keyscript(&["flag prompt"])),
            Some("flag prompt".to_string())
        );
    }

    #[test]
    fn dispatch_covers_the_real_cryptroot_invocation() {
        let bare = || vec!["ombra-askpass".to_string()];
        let cryptroot = || {
            vec![
                "ombra-askpass".to_string(),
                "Please unlock disk nvme0n1p4_crypt:".to_string(),
            ]
        };
        assert!(!is_keyscript_invocation(&bare(), false));
        assert!(is_keyscript_invocation(&args_with_keyscript(&[]), false));
        assert!(is_keyscript_invocation(&bare(), true));
        assert!(is_keyscript_invocation(&cryptroot(), false));
        assert!(!is_keyscript_invocation(
            &["ombra-askpass".to_string(), "--quiet".to_string()],
            false
        ));
    }

    #[test]
    fn the_splash_is_drawn_before_the_build_key_test_then_the_prompt() {
        let dir = tempdir("order");
        let marker = dir.join("askpass-attempts-x");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        let log = Rc::clone(&ui.log);
        run(
            &mut out,
            &marker,
            &mut ui,
            "ombra-disk",
            Duration::ZERO,
            &mut || {
                log.borrow_mut().push("test");
                true
            },
        )
        .unwrap();
        let log = ui.log.borrow();
        assert_eq!(&log[..3], ["splash", "test", "unlock"]);
        assert!(log[3..].iter().all(|e| *e == "unlock"));
    }

    #[test]
    fn a_later_attempt_never_runs_the_test_or_draws_the_splash() {
        let dir = tempdir("later");
        let marker = dir.join("askpass-attempts-x");
        fs::write(&marker, "1\n").unwrap();
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        run(
            &mut out,
            &marker,
            &mut ui,
            "ombra-disk",
            Duration::ZERO,
            &mut || panic!("tested the build key on attempt two"),
        )
        .unwrap();
        assert_eq!(ui.splash_draws, 0);
    }

    // ---- the dead record ----

    fn uid() -> u32 {
        unsafe { libc::getuid() }
    }

    fn tmpfs_yes(_f: &fs::File) -> bool {
        true
    }

    /// A record dir as the keyscript leaves it, under a fresh test dir.
    fn record_in(tag: &str) -> PathBuf {
        tempdir(tag).join("gate").join("build-key-dead")
    }

    const BODY: &str = "boot 6f1c0a52-1b7e-4f43-9d0e-8a3c2b1d4e5f dev 64771\n";

    #[test]
    fn record_body_binds_boot_and_device_and_refuses_junk_ids() {
        assert_eq!(
            dead_record_body("6f1c0a52-1b7e-4f43-9d0e-8a3c2b1d4e5f\n", 64771).as_deref(),
            Some(BODY)
        );
        assert_eq!(dead_record_body("", 1), None);
        assert_eq!(dead_record_body("  \n", 1), None);
        assert_eq!(dead_record_body("a b", 1), None);
        assert_eq!(dead_record_body_for(Path::new("/nonexistent/dev/x")), None);
        // a regular file is not a block device
        let dir = tempdir("notblk");
        let f = dir.join("f");
        fs::write(&f, "x").unwrap();
        assert_eq!(dead_record_body_for(&f), None);
    }

    #[test]
    fn exit_two_writes_a_private_record_that_holds() {
        let rec = record_in("dead2");
        assert!(note_build_key_test(&rec, Some(2), Some(BODY)));
        let dm = fs::metadata(rec.parent().unwrap()).unwrap();
        assert_eq!(dm.mode() & 0o777, 0o700);
        let fm = fs::symlink_metadata(&rec).unwrap();
        assert_eq!(fm.mode() & 0o777, 0o600);
        assert!(dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
    }

    #[test]
    fn a_live_or_unknown_build_key_never_leaves_a_record() {
        for exit in [Some(0), Some(1), Some(3), Some(-1), None] {
            let rec = record_in("alive");
            // even a stale record from earlier in the boot is cleared
            write_dead_record(&rec, BODY).unwrap();
            assert!(!note_build_key_test(&rec, exit, Some(BODY)), "{exit:?}");
            assert!(!rec.exists(), "record survived exit {exit:?}");
            assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        }
        // dead, but no boot/device identity: still dead for the keyscript, but nothing recorded
        let rec = record_in("noid");
        assert!(note_build_key_test(&rec, Some(2), None));
        assert!(!rec.exists());
    }

    #[test]
    fn a_live_build_key_through_run_offers_the_key_and_records_nothing() {
        let dir = tempdir("runalive");
        let marker = dir.join("askpass-attempts-x");
        let rec = dir.join("gate").join("build-key-dead");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(vec![]);
        run(
            &mut out,
            &marker,
            &mut ui,
            "ombra-disk",
            Duration::ZERO,
            &mut || note_build_key_test(&rec, Some(0), Some(BODY)),
        )
        .unwrap();
        assert_eq!(out, b"ombra-disk");
        assert!(!rec.exists());
    }

    #[test]
    fn a_record_for_another_boot_or_device_does_not_hold() {
        let rec = record_in("otherboot");
        write_dead_record(&rec, BODY).unwrap();
        let other_boot = dead_record_body("00000000-0000-0000-0000-000000000000", 64771).unwrap();
        let other_dev = dead_record_body("6f1c0a52-1b7e-4f43-9d0e-8a3c2b1d4e5f", 64772).unwrap();
        assert!(!dead_record_holds(&rec, &other_boot, uid(), &tmpfs_yes));
        assert!(!dead_record_holds(&rec, &other_dev, uid(), &tmpfs_yes));
        assert!(dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
    }

    #[test]
    fn a_record_off_tmpfs_or_with_the_wrong_owner_does_not_hold() {
        let rec = record_in("owner");
        write_dead_record(&rec, BODY).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &|_| false));
        assert!(!dead_record_holds(
            &rec,
            BODY,
            uid().wrapping_add(1),
            &tmpfs_yes
        ));
    }

    #[test]
    fn a_record_with_group_or_other_bits_does_not_hold() {
        for mode in [0o640, 0o604, 0o644, 0o660] {
            let rec = record_in("mode");
            write_dead_record(&rec, BODY).unwrap();
            fs::set_permissions(&rec, fs::Permissions::from_mode(mode)).unwrap();
            assert!(
                !dead_record_holds(&rec, BODY, uid(), &tmpfs_yes),
                "{mode:o}"
            );
        }
        // the directory too
        let rec = record_in("dirmode");
        write_dead_record(&rec, BODY).unwrap();
        fs::set_permissions(rec.parent().unwrap(), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
    }

    #[test]
    fn a_symlinked_hardlinked_missing_or_odd_record_does_not_hold() {
        // symlink to a perfectly good record
        let real = record_in("symreal");
        write_dead_record(&real, BODY).unwrap();
        let rec = record_in("sym");
        let dir = rec.parent().unwrap();
        fs::DirBuilder::new().mode(0o700).create(dir).unwrap();
        std::os::unix::fs::symlink(&real, &rec).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        // a symlinked directory
        let rec = record_in("symdir");
        let top = rec.parent().unwrap().parent().unwrap();
        std::os::unix::fs::symlink(real.parent().unwrap(), top.join("gate")).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        // a second hard link
        let rec = record_in("hard");
        write_dead_record(&rec, BODY).unwrap();
        fs::hard_link(&rec, rec.with_file_name("again")).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        // missing
        let rec = record_in("missing");
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        // a directory in its place
        let rec = record_in("isdir");
        fs::DirBuilder::new()
            .mode(0o700)
            .recursive(true)
            .create(&rec)
            .unwrap();
        fs::set_permissions(rec.parent().unwrap(), fs::Permissions::from_mode(0o700)).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
        // trailing junk
        let rec = record_in("junk");
        write_dead_record(&rec, &format!("{BODY}x")).unwrap();
        assert!(!dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
    }

    #[test]
    fn writing_replaces_a_planted_symlink_instead_of_following_it() {
        let rec = record_in("plant");
        let dir = rec.parent().unwrap();
        fs::DirBuilder::new().mode(0o700).create(dir).unwrap();
        let target = dir.parent().unwrap().join("target");
        fs::write(&target, "untouched").unwrap();
        std::os::unix::fs::symlink(&target, &rec).unwrap();
        write_dead_record(&rec, BODY).unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
        assert!(dead_record_holds(&rec, BODY, uid(), &tmpfs_yes));
    }

    fn keyscript_run_for_test(
        marker: &Path,
        out: &mut Vec<u8>,
        ui: &mut FakeUi,
        splash: Duration,
    ) -> io::Result<()> {
        run(
            out,
            marker,
            ui,
            crate::BUILD_PASSPHRASE,
            splash,
            &mut || false,
        )
    }
}
