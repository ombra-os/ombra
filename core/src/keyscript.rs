//! Keyscript mode: cryptroot invokes once per passphrase attempt; the passphrase is one line on STDOUT, the TUI on /dev/tty1.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crossterm::event::KeyEvent;
use zeroize::Zeroize;

use crate::input::{FieldEvent, SecretField, Severity};
use crate::theme;

pub const SPLASH: Duration = Duration::from_millis(1500);
pub const RETRY_MESSAGE: &str = "that passphrase didn't decrypt - try again";
pub const TOO_SHORT_MESSAGE: &str = "use at least 8 characters";
pub const MARKER_PREFIX: &str = "askpass-attempts";

pub fn marker_path(name: Option<&str>) -> PathBuf {
    PathBuf::from("/run/ombra").join(format!("{MARKER_PREFIX}-{}", name.unwrap_or("unknown")))
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
    fs::write(marker, format!("{}\n", prev + 1))?;
    Ok(prev)
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
        Ok(prev) => prev + 1,
        Err(_) => read_attempts(marker).saturating_add(2).max(2),
    };

    // a set-up machine skips the doomed build-key attempt: straight to the prompt
    if attempt == 1 && build_key_dead() {
        let _ = fs::write(marker, "2\n");
        attempt = 2;
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
    let mut field = SecretField::new("passphrase");
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
        match ui.next_key()? {
            Some(key) => match field.handle_key(key) {
                FieldEvent::Submitted => {
                    let mut secret = field.take();
                    let sent = write_key(stdout, secret.as_bytes());
                    // plain String is not zeroize-on-drop
                    secret.zeroize();
                    sent?;
                    return Ok(());
                }
                FieldEvent::TooShort => feedback = Some(TOO_SHORT_MESSAGE),
                FieldEvent::Edited => feedback = None,
                FieldEvent::Ignored => {}
            },
            None => {} // static caret: nothing to blink
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    use crossterm::event::{KeyCode, KeyModifiers};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn tempdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ombra-keyscript-test-{tag}-{}", std::process::id()));
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
    }

    impl FakeUi {
        fn scripted(keys: Vec<KeyEvent>) -> Self {
            FakeUi {
                keys: keys.into(),
                splash_draws: 0,
                unlock_draws: 0,
                first_draw_empty: None,
                last_message: None,
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
        }
        fn draw_unlock(&mut self, field: &SecretField, message: Option<(&str, Severity)>) {
            self.unlock_draws += 1;
            if self.first_draw_empty.is_none() {
                self.first_draw_empty = Some(field.is_empty());
            }
            self.last_message = message.map(|(m, _)| m.to_string());
        }
        fn next_key(&mut self) -> io::Result<Option<KeyEvent>> {
            self.keys
                .pop_front()
                .map(Some)
                .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "key script exhausted"))
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
        assert_eq!(ui.splash_draws, 0);
        assert_eq!(ui.unlock_draws, 0);
        assert_eq!(read_attempts(&marker), 1);
    }

    #[test]
    fn a_dead_build_key_goes_straight_to_the_prompt_and_counts_as_attempt_two() {
        let dir = tempdir("dead");
        let marker = dir.join("askpass-attempts-x");
        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("sardines1"));
        run(&mut out, &marker, &mut ui, "ombra-disk", Duration::ZERO, &mut || true).unwrap();
        assert_eq!(out, b"sardines1");
        assert_eq!(ui.splash_draws, 0);
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
        assert_eq!(ui.splash_draws, want);
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
        assert_eq!(
            ui.last_message.as_deref(),
            Some(RETRY_MESSAGE),
        );
        assert_eq!(read_attempts(&marker), 3);
    }

    #[test]
    fn field_feedback_wins_over_the_retry_line() {
        let dir = tempdir("feedback");
        let marker = dir.join("askpass-attempts-x");
        fs::write(&marker, "2\n").unwrap();

        let mut out: Vec<u8> = Vec::new();
        let mut ui = FakeUi::scripted(FakeUi::typed("abc"));
        let res = keyscript_run_for_test(&marker, &mut out, &mut ui, Duration::ZERO);
        assert!(res.is_err());
        assert_eq!(ui.last_message, Some("use at least 8 characters".to_string()));
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
            &[ "ombra-askpass".to_string(), "--quiet".to_string() ],
            false
        ));
    }

    fn keyscript_run_for_test(
        marker: &Path,
        out: &mut Vec<u8>,
        ui: &mut FakeUi,
        splash: Duration,
    ) -> io::Result<()> {
        run(out, marker, ui, crate::BUILD_PASSPHRASE, splash, &mut || false)
    }
}
