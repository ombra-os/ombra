//! Passphrase widget: framed input field, '·' dot bullets, quality floor, confirm/retry; secret bytes zeroize on drop.

use std::collections::VecDeque;
use std::fmt;
use std::io::{self, Read};
use std::os::unix::io::{AsRawFd, RawFd};
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::{Block, BorderType, Widget};
use zeroize::Zeroize;

use crate::term::TtyHandle;
use crate::theme;

/// Quality floor enforced on submit.
pub const MIN_LEN: usize = 8;
/// Longest typed secret; the buffer is allocated once at this size so it never reallocates.
pub const MAX_LEN: usize = 128;

/// Secret bytes: zeroized when dropped, redacted in Debug, never logged.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SecretBuf(String);

impl Drop for SecretBuf {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl SecretBuf {
    pub fn new(s: impl Into<String>) -> Self {
        SecretBuf(s.into())
    }

    pub fn with_capacity(n: usize) -> Self {
        SecretBuf(String::with_capacity(n))
    }

    fn push(&mut self, c: char) {
        self.0.push(c);
    }

    fn pop(&mut self) {
        self.0.pop();
    }

    fn wipe(&mut self) {
        self.0.zeroize();
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Move the value out, leaving an empty (already harmless) buffer.
    pub fn take(&mut self) -> String {
        std::mem::take(&mut self.0)
    }
}

impl fmt::Debug for SecretBuf {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[secret]")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldEvent {
    Edited,
    Submitted,
    TooShort,
    Ignored,
}

/// One framed passphrase entry field.
pub struct SecretField {
    value: SecretBuf,
    placeholder: &'static str,
    /// Caret blink phase; only consulted while the field is empty.
    caret_on: bool,
    /// Shortest input Enter accepts: MIN_LEN when a passphrase is being chosen, 1 when one is being entered.
    min_len: usize,
}

impl SecretField {
    pub fn new(placeholder: &'static str) -> Self {
        SecretField {
            value: SecretBuf::with_capacity(MAX_LEN),
            placeholder,
            caret_on: true,
            min_len: MIN_LEN,
        }
    }

    /// A field for ENTERING an existing passphrase (disk unlock, resume): any non-empty input may be submitted. The
    /// 8-character rule belongs to choosing a passphrase; applied to unlocking, it would make a disk whose passphrase
    /// was set shorter by other means impossible to open.
    pub fn for_unlock(placeholder: &'static str) -> Self {
        SecretField {
            min_len: 1,
            ..SecretField::new(placeholder)
        }
    }

    pub fn set_caret(&mut self, on: bool) {
        self.caret_on = on;
    }

    pub fn is_empty(&self) -> bool {
        self.value.is_empty()
    }

    pub fn len(&self) -> usize {
        self.value.expose().chars().count()
    }

    pub fn value(&self) -> &str {
        self.value.expose()
    }

    pub fn clear(&mut self) {
        self.value.wipe();
    }

    pub fn take(&mut self) -> String {
        std::mem::replace(&mut self.value, SecretBuf::with_capacity(MAX_LEN)).take()
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> FieldEvent {
        match key.code {
            KeyCode::Enter => {
                if self.len() < self.min_len {
                    FieldEvent::TooShort
                } else {
                    FieldEvent::Submitted
                }
            }
            KeyCode::Backspace if !self.value.is_empty() => {
                self.value.pop();
                FieldEvent::Edited
            }
            // Printable ASCII only: the initramfs unlock cannot type anything else; Ctrl/Alt chords are shortcuts.
            KeyCode::Char(c)
                if matches!(c, ' '..='~')
                    && self.value.expose().len() < MAX_LEN
                    && !key.modifiers.contains(KeyModifiers::CONTROL)
                    && !key.modifiers.contains(KeyModifiers::ALT) =>
            {
                self.value.push(c);
                FieldEvent::Edited
            }
            _ => FieldEvent::Ignored,
        }
    }
}

impl Widget for &SecretField {
    /// Rounded frame; placeholder when empty; one '·' per typed char; caret only while empty (blinks via `set_caret`).
    fn render(self, area: Rect, buf: &mut Buffer) {
        let area = area.intersection(buf.area);
        if area.is_empty() {
            return;
        }
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(theme::fg(theme::FIELD_FRAME));
        let inner = block.inner(area);
        block.render(area, buf);
        if inner.width == 0 || inner.height == 0 {
            return;
        }
        let pad = u16::from(inner.width > 4);
        let max = inner.right() - pad;
        let mut x = inner.x + pad;
        let y = inner.y;
        if self.value.is_empty() {
            if self.caret_on && x < max {
                buf[(x, y)].set_char(theme::CARET);
                buf[(x, y)].set_fg(theme::RING_BRIGHT);
                x += 1;
            }
            let n = self.placeholder.chars().count() as u16;
            let avail = max.saturating_sub(x);
            let start = x + avail.saturating_sub(n) / 2;
            for (px, ch) in (start..max).zip(self.placeholder.chars()) {
                buf[(px, y)].set_char(ch);
                buf[(px, y)].set_fg(theme::MUTED);
            }
        } else {
            for _ in 0..self.len() {
                if x >= max {
                    break;
                }
                buf[(x, y)].set_char(theme::MASK); // ·
                buf[(x, y)].set_fg(theme::RING_BRIGHT);
                x += 1;
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    Bad,
    Muted,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FlowEvent {
    Editing,
    TooShort,
    Mismatch,
    Completed(SecretBuf),
}

/// Enter-twice flow over two fields with inline status messages.
pub struct SecretFlow {
    first: SecretField,
    second: SecretField,
    on_second: bool,
    message: Option<(String, Severity)>,
    /// A value the caller forbids for the first field (the public build passphrase must not become the user's own).
    forbidden: Option<&'static str>,
}

impl SecretFlow {
    pub fn new(placeholder: &'static str, confirm_placeholder: &'static str) -> Self {
        SecretFlow {
            first: SecretField::new(placeholder),
            second: SecretField::new(confirm_placeholder),
            on_second: false,
            message: None,
            forbidden: None,
        }
    }

    pub fn forbid(&mut self, value: &'static str) {
        self.forbidden = Some(value);
    }

    pub fn on_second(&self) -> bool {
        self.on_second
    }

    pub fn active_field(&self) -> &SecretField {
        if self.on_second {
            &self.second
        } else {
            &self.first
        }
    }

    pub fn set_caret(&mut self, on: bool) {
        self.first.set_caret(on);
        self.second.set_caret(on);
    }

    pub fn first_field(&self) -> &SecretField {
        &self.first
    }

    pub fn second_field(&self) -> &SecretField {
        &self.second
    }

    pub fn message(&self) -> Option<(&str, Severity)> {
        self.message.as_ref().map(|(m, s)| (m.as_str(), *s))
    }

    pub fn reset(&mut self) {
        self.first.clear();
        self.second.clear();
        self.on_second = false;
        self.message = None;
    }

    pub fn handle_key(&mut self, key: KeyEvent) -> FlowEvent {
        let ev = if self.on_second {
            self.second.handle_key(key)
        } else {
            self.first.handle_key(key)
        };
        match ev {
            FieldEvent::Ignored => FlowEvent::Editing,
            FieldEvent::Edited => {
                self.message = None;
                FlowEvent::Editing
            }
            FieldEvent::TooShort => {
                self.message = Some(("use at least 8 characters".to_string(), Severity::Bad));
                FlowEvent::TooShort
            }
            FieldEvent::Submitted => {
                let v = self.active_field().value();
                if v != v.trim() {
                    self.message =
                        Some(("no leading or trailing spaces".to_string(), Severity::Bad));
                    return FlowEvent::TooShort;
                }
                if !self.on_second {
                    if let Some(bad) = self.forbidden {
                        if v == bad {
                            self.message = Some((
                                "that is the public build passphrase - choose your own".to_string(),
                                Severity::Bad,
                            ));
                            return FlowEvent::TooShort;
                        }
                    }
                }
                if !self.on_second {
                    self.on_second = true;
                    self.message = Some(("repeat it to confirm".to_string(), Severity::Muted));
                    FlowEvent::Editing
                } else if self.first.value == self.second.value {
                    let secret = SecretBuf::new(self.first.take());
                    FlowEvent::Completed(secret)
                } else {
                    self.reset();
                    self.message = Some((
                        "those didn't match - set them again".to_string(),
                        Severity::Bad,
                    ));
                    FlowEvent::Mismatch
                }
            }
        }
    }
}

// ---- keyboard bytes ----

/// One raw keyboard byte -> a field key; read from an fd WE opened — boot contexts have no controlling terminal.
pub fn byte_to_key(b: u8) -> Option<KeyEvent> {
    match b {
        b'\r' | b'\n' => Some(KeyEvent::new(KeyCode::Enter, KeyModifiers::empty())),
        0x7f | 0x08 => Some(KeyEvent::new(KeyCode::Backspace, KeyModifiers::empty())),
        c if c.is_ascii_graphic() || c == b' ' => Some(KeyEvent::new(
            KeyCode::Char(c as char),
            KeyModifiers::empty(),
        )),
        _ => None,
    }
}

/// Swallows escape and CSI/SS3 sequences (arrow keys etc.) so their trailing bytes never become text.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub enum EscState {
    #[default]
    Idle,
    Esc,
    /// Just after `ESC [`: a second `[` here is the Linux console's function-key form (`ESC [ [ A`..`E`).
    CsiStart,
    Csi,
    /// After `ESC [ [`: exactly one more byte belongs to the sequence.
    LinuxFn,
}

impl EscState {
    pub fn feed(&mut self, b: u8) -> Option<KeyEvent> {
        match *self {
            EscState::Idle if b == 0x1b => {
                *self = EscState::Esc;
                None
            }
            EscState::Idle => byte_to_key(b),
            EscState::Esc => {
                *self = match b {
                    b'[' => EscState::CsiStart,
                    b'O' => EscState::Csi,
                    0x1b => EscState::Esc,
                    _ => EscState::Idle,
                };
                None
            }
            EscState::CsiStart if b == b'[' => {
                *self = EscState::LinuxFn;
                None
            }
            EscState::LinuxFn => {
                *self = EscState::Idle;
                None
            }
            EscState::CsiStart | EscState::Csi => {
                *self = EscState::Csi;
                if (0x40..=0x7e).contains(&b) {
                    *self = EscState::Idle;
                }
                None
            }
        }
    }
}

/// Typed characters must not outlive their use: overwrite each event in place (volatile, so the stores are never
/// elided before the buffer is freed). Stack copies made while a key is handled are out of reach.
pub fn wipe_keys<'a>(keys: impl IntoIterator<Item = &'a mut KeyEvent>) {
    let blank = KeyEvent::new(KeyCode::Null, KeyModifiers::empty());
    for k in keys {
        // SAFETY: k is a valid, aligned, exclusive reference; KeyEvent is Copy, so overwriting drops nothing.
        unsafe { std::ptr::write_volatile(k, blank) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Push without leaving a stale copy behind: on growth the old buffer is wiped before it is freed.
fn push_wiped(keys: &mut Vec<KeyEvent>, k: KeyEvent) {
    if keys.len() == keys.capacity() {
        let mut grown = Vec::with_capacity(keys.capacity().saturating_mul(2).max(16));
        grown.extend_from_slice(keys);
        wipe_keys(keys.iter_mut());
        *keys = grown;
    }
    keys.push(k);
}

/// Drain everything queued right now, in arrival order; never blocks (O_NONBLOCK is the caller's contract).
/// The caller wipes the returned keys (`wipe_keys`) once handled.
pub fn drain_keys(r: &mut dyn Read) -> io::Result<Vec<KeyEvent>> {
    drain_keys_with(r, &mut EscState::default())
}

fn drain_keys_with(r: &mut dyn Read, esc: &mut EscState) -> io::Result<Vec<KeyEvent>> {
    let mut keys = Vec::new();
    let mut chunk = [0u8; 64];
    let res = loop {
        match r.read(&mut chunk) {
            Ok(0) => break Ok(()),
            Ok(n) => {
                for k in chunk[..n].iter().filter_map(|&b| esc.feed(b)) {
                    push_wiped(&mut keys, k);
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => break Ok(()),
            Err(e) => break Err(e),
        }
    };
    chunk.zeroize();
    match res {
        Ok(()) => Ok(keys),
        Err(e) => {
            wipe_keys(keys.iter_mut());
            Err(e)
        }
    }
}

/// Owns a fresh nonblocking read fd (a separate open, so its flags never leak onto the drawing fd).
pub struct KeyReader<R: Read> {
    reader: Option<R>,
    /// The reader's own fd when pollable: waits block in poll(2) instead of sleeping in slices.
    wait_fd: Option<RawFd>,
    pending: VecDeque<KeyEvent>,
    esc: EscState,
}

/// Sleep slice for readers without a pollable fd, and the back-off when poll reports ready but yields no key.
const KEY_SLICE: Duration = Duration::from_millis(40);

impl<R: Read + AsRawFd> KeyReader<R> {
    /// The fd stays valid for the reader's life: the reader is owned here and never replaced.
    pub fn pollable(reader: Option<R>) -> Self {
        let fd = reader.as_ref().map(AsRawFd::as_raw_fd);
        let mut kr = KeyReader::new(reader);
        kr.wait_fd = fd;
        kr
    }
}

impl<R: Read> KeyReader<R> {
    pub fn new(reader: Option<R>) -> Self {
        KeyReader {
            reader,
            wait_fd: None,
            pending: VecDeque::new(),
            esc: EscState::default(),
        }
    }

    /// Blocks until input is readable or `d` passes; true when poll reported the fd ready.
    /// No pollable fd: one sleep slice. Hangup/error stays "ready" forever, so it sleeps a slice instead of spinning.
    pub fn wait(&self, d: Duration) -> bool {
        let Some(fd) = self.wait_fd else {
            std::thread::sleep(KEY_SLICE.min(d));
            return false;
        };
        let ms = d.as_nanos().div_ceil(1_000_000).min(i32::MAX as u128) as i32;
        let mut p = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd for the duration of the call.
        let n = unsafe { libc::poll(&mut p, 1, ms) };
        if n < 0 || (n > 0 && p.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0) {
            std::thread::sleep(KEY_SLICE.min(d));
            return false;
        }
        n > 0
    }

    /// The caller wipes the returned keys (`wipe_keys`) once handled.
    pub fn drain_available(&mut self) -> io::Result<Vec<KeyEvent>> {
        let mut keys = Vec::with_capacity(self.pending.len());
        keys.extend(self.pending.iter().copied());
        wipe_keys(self.pending.iter_mut());
        self.pending.clear();
        if let Some(r) = self.reader.as_mut() {
            match drain_keys_with(r, &mut self.esc) {
                Ok(mut fresh) => {
                    for &k in &fresh {
                        push_wiped(&mut keys, k);
                    }
                    wipe_keys(fresh.iter_mut());
                }
                Err(e) => {
                    wipe_keys(keys.iter_mut());
                    return Err(e);
                }
            }
        }
        Ok(keys)
    }

    pub fn next_key(&mut self, budget: Duration) -> io::Result<Option<KeyEvent>> {
        if let Some(slot) = self.pending.front_mut() {
            let k = *slot;
            wipe_keys(std::iter::once(slot));
            self.pending.pop_front();
            return Ok(Some(k));
        }
        if let Some(k) = self.refill()? {
            return Ok(Some(k));
        }
        let start = Instant::now();
        while let Some(left) = budget.checked_sub(start.elapsed()).filter(|d| !d.is_zero()) {
            let ready = self.wait(left);
            if let Some(k) = self.refill()? {
                return Ok(Some(k));
            }
            if ready {
                // readable yet no key (escape bytes, EOF): back off a slice rather than spin
                std::thread::sleep(KEY_SLICE.min(budget.saturating_sub(start.elapsed())));
            }
        }
        Ok(None)
    }

    fn refill(&mut self) -> io::Result<Option<KeyEvent>> {
        let mut keys = self.drain_available()?;
        let first = keys.first().copied();
        if let Some(rest) = keys.get(1..) {
            // pending was just wiped and emptied, so growing it here copies no stale keys
            self.pending.reserve(rest.len());
            self.pending.extend(rest.iter().copied());
        }
        wipe_keys(keys.iter_mut());
        Ok(first)
    }
}

impl<R: Read> Drop for KeyReader<R> {
    fn drop(&mut self) {
        wipe_keys(self.pending.iter_mut());
    }
}

impl KeyReader<std::fs::File> {
    pub fn from_tty(handle: &TtyHandle) -> Self {
        KeyReader::pollable(handle.open_reader())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    fn type_str(field: &mut SecretField, s: &str) {
        for c in s.chars() {
            assert_eq!(field.handle_key(key(KeyCode::Char(c))), FieldEvent::Edited);
        }
    }

    #[test]
    fn typing_backspace_and_floor() {
        let mut f = SecretField::new("passphrase");
        type_str(&mut f, "abcdefg");
        assert_eq!(f.len(), 7);
        assert_eq!(f.handle_key(key(KeyCode::Enter)), FieldEvent::TooShort);
        assert_eq!(f.value(), "abcdefg");
        type_str(&mut f, "h");
        assert_eq!(f.handle_key(key(KeyCode::Enter)), FieldEvent::Submitted);
        f.handle_key(key(KeyCode::Backspace));
        assert_eq!(f.value(), "abcdefg");
    }

    #[test]
    fn only_printable_ascii_is_accepted() {
        let mut f = SecretField::new("passphrase");
        for c in ['é', '日', '\u{1f600}', '\t', '\u{7f}', '\n'] {
            assert_eq!(
                f.handle_key(key(KeyCode::Char(c))),
                FieldEvent::Ignored,
                "{c:?}"
            );
        }
        assert!(f.is_empty());
        type_str(&mut f, " ~!az");
        assert_eq!(f.value(), " ~!az");
    }

    #[test]
    fn navigation_keys_never_insert_text() {
        let mut f = SecretField::new("passphrase");
        type_str(&mut f, "abc");
        for code in [
            KeyCode::Left,
            KeyCode::Right,
            KeyCode::Up,
            KeyCode::Down,
            KeyCode::Esc,
            KeyCode::Tab,
            KeyCode::Home,
            KeyCode::Delete,
        ] {
            assert_eq!(f.handle_key(key(code)), FieldEvent::Ignored);
        }
        assert_eq!(f.value(), "abc");
    }

    #[test]
    fn length_is_capped_and_the_buffer_never_reallocates() {
        let mut f = SecretField::new("passphrase");
        let base = f.value().as_ptr();
        for _ in 0..MAX_LEN {
            assert_eq!(f.handle_key(key(KeyCode::Char('a'))), FieldEvent::Edited);
        }
        assert_eq!(f.handle_key(key(KeyCode::Char('b'))), FieldEvent::Ignored);
        assert_eq!(f.len(), MAX_LEN);
        assert_eq!(f.value().as_ptr(), base);
        f.handle_key(key(KeyCode::Backspace));
        assert_eq!(f.handle_key(key(KeyCode::Char('b'))), FieldEvent::Edited);
        assert_eq!(f.value().as_ptr(), base);
        let taken = f.take();
        assert_eq!(taken.len(), MAX_LEN);
        assert!(f.is_empty());
        type_str(&mut f, "again");
        assert_eq!(f.value(), "again");
    }

    #[test]
    fn arrow_and_escape_sequences_are_swallowed_whole() {
        let mut r = ScriptedRead {
            chunks: [
                Ok(b"ab\x1b[Acd\x1bOBef\x1b[1;5Cgh\x1bxij\r".to_vec()),
                dry(),
            ]
            .into(),
        };
        let keys = drain_keys(&mut r).unwrap();
        let typed: String = keys
            .iter()
            .filter_map(|k| match k.code {
                KeyCode::Char(c) => Some(c),
                _ => None,
            })
            .collect();
        assert_eq!(typed, "abcdefghij");
    }

    #[test]
    fn an_escape_sequence_split_across_reads_is_still_swallowed() {
        let mut kr = KeyReader::new(Some(ScriptedRead {
            chunks: [
                Ok(b"a\x1b".to_vec()),
                dry(),
                Ok(b"[".to_vec()),
                dry(),
                Ok(b"Db".to_vec()),
                dry(),
            ]
            .into(),
        }));
        let mut typed = String::new();
        for _ in 0..3 {
            for k in kr.drain_available().unwrap() {
                if let KeyCode::Char(c) = k.code {
                    typed.push(c);
                }
            }
        }
        assert_eq!(typed, "ab");
    }

    #[test]
    fn control_chords_are_ignored() {
        let mut f = SecretField::new("passphrase");
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert_eq!(f.handle_key(ctrl_c), FieldEvent::Ignored);
        assert!(f.is_empty());
    }

    #[test]
    fn placeholder_vs_dots_rendering() {
        use ratatui::backend::TestBackend;
        use ratatui::Terminal;

        let area = Rect::new(7, 2, theme::FIELD_WIDTH, 3);
        let mut terminal = Terminal::new(TestBackend::new(60, 8)).unwrap();

        let f = SecretField::new("passphrase");
        terminal
            .draw(|frame| frame.render_widget(&f, area))
            .unwrap();
        let buf = terminal.backend().buffer();
        assert_eq!(buf[(7, 2)].symbol(), "\u{256d}"); // ╭
        assert_eq!(buf[(52, 2)].symbol(), "\u{256e}"); // ╮
        assert_eq!(buf[(7, 4)].symbol(), "\u{2570}"); // ╰
        assert_eq!(buf[(25, 3)].symbol(), "p");
        assert_eq!(buf[(25, 3)].fg, theme::MUTED);
        assert_eq!(buf[(34, 3)].symbol(), "e");

        assert_eq!(buf[(8, 3)].symbol(), " ", "inner padding");
        assert_eq!(buf[(9, 3)].symbol(), "\u{2588}", "caret on while empty");
        let mut dark = SecretField::new("passphrase");
        dark.set_caret(false);
        terminal
            .draw(|frame| frame.render_widget(&dark, area))
            .unwrap();
        let buf = terminal.backend().buffer();
        for x in 8..52 {
            assert_ne!(
                buf[(x, 3)].symbol(),
                "\u{2588}",
                "caret painted while dark at x={x}"
            );
        }
        assert_eq!(buf[(25, 3)].symbol(), "p");

        let mut f = SecretField::new("passphrase");
        type_str(&mut f, "abc");
        terminal
            .draw(|frame| frame.render_widget(&f, area))
            .unwrap();
        let buf = terminal.backend().buffer();
        for x in 9..12 {
            assert_eq!(buf[(x, 3)].symbol(), "\u{00b7}", "not a dot at x={x}");
            assert_eq!(buf[(x, 3)].fg, theme::RING_BRIGHT);
        }
        assert_eq!(buf[(12, 3)].symbol(), " ", "no caret block after the dots");
        let mut lit = SecretField::new("passphrase");
        type_str(&mut lit, "abc");
        lit.set_caret(true);
        terminal
            .draw(|frame| frame.render_widget(&lit, area))
            .unwrap();
        let buf = terminal.backend().buffer();
        for x in 8..52 {
            assert_ne!(
                buf[(x, 3)].symbol(),
                "\u{2588}",
                "caref returned over typed dots at x={x}"
            );
        }
        for x in 8..52 {
            assert_ne!(buf[(x, 3)].symbol(), "=", "'=' bullet regressed at x={x}");
        }
    }

    #[test]
    fn confirm_flow_completes_only_on_match() {
        let mut flow = SecretFlow::new("passphrase", "repeat passphrase");
        assert!(!flow.on_second());
        for c in "sardines1".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::Editing);
        assert!(flow.on_second());
        for c in "sardines2".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::Mismatch);
        assert!(!flow.on_second());
        assert_eq!(
            flow.message(),
            Some(("those didn't match - set them again", Severity::Bad))
        );
        assert!(flow.active_field().is_empty());

        for c in "sardines1".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        flow.handle_key(key(KeyCode::Enter));
        for c in "sardines1".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        match flow.handle_key(key(KeyCode::Enter)) {
            FlowEvent::Completed(sec) => assert_eq!(sec.expose(), "sardines1"),
            other => panic!("expected completion, got {other:?}"),
        }
    }

    #[test]
    fn too_short_sets_inline_message_and_keeps_text() {
        let mut flow = SecretFlow::new("passphrase", "repeat passphrase");
        for c in "short".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::TooShort);
        assert_eq!(
            flow.message(),
            Some(("use at least 8 characters", Severity::Bad))
        );
        assert_eq!(flow.active_field().value(), "short");
    }

    #[test]
    fn the_public_build_passphrase_is_forbidden_for_a_new_secret() {
        let mut flow = SecretFlow::new("passphrase", "repeat passphrase");
        flow.forbid("ombra-disk");
        for c in "ombra-disk".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::TooShort);
        assert!(!flow.on_second(), "must NOT spawn the confirm box");
        assert_eq!(
            flow.message(),
            Some((
                "that is the public build passphrase - choose your own",
                Severity::Bad
            ))
        );
        for c in "not-the-public-one".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::Editing);
        assert!(flow.on_second());
    }

    #[test]
    fn edge_spaces_are_rejected_on_submit() {
        let mut flow = SecretFlow::new("passphrase", "repeat passphrase");
        for c in " spaced123 ".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        assert_eq!(flow.handle_key(key(KeyCode::Enter)), FlowEvent::TooShort);
        assert_eq!(
            flow.message(),
            Some(("no leading or trailing spaces", Severity::Bad))
        );
        assert_eq!(flow.active_field().value(), " spaced123 ");
    }

    #[test]
    fn reset_clears_values_stage_and_message() {
        let mut flow = SecretFlow::new("passphrase", "repeat passphrase");
        for c in "longenough1".chars() {
            flow.handle_key(key(KeyCode::Char(c)));
        }
        flow.handle_key(key(KeyCode::Enter));
        assert!(flow.on_second());
        flow.reset();
        assert!(!flow.on_second());
        assert!(flow.message().is_none());
        assert!(flow.active_field().is_empty());
    }

    #[test]
    fn secret_buf_debug_is_redacted_and_take_zeroizes_source() {
        let mut s = SecretBuf::new("topsecret");
        assert_eq!(format!("{s:?}"), "[secret]");
        assert_eq!(s.as_bytes(), b"topsecret");
        let moved = s.take();
        assert_eq!(moved, "topsecret");
        assert!(s.is_empty());
        let mut f = SecretField::new("p");
        type_str(&mut f, "topsecret");
        f.clear();
        assert!(f.is_empty());
    }

    fn raw_key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::empty())
    }

    #[test]
    fn byte_to_key_maps_the_boot_keyboard_bytes() {
        assert_eq!(byte_to_key(b'\r'), Some(raw_key(KeyCode::Enter)));
        assert_eq!(byte_to_key(b'\n'), Some(raw_key(KeyCode::Enter)));
        assert_eq!(byte_to_key(0x7f), Some(raw_key(KeyCode::Backspace)));
        assert_eq!(byte_to_key(0x08), Some(raw_key(KeyCode::Backspace)));
        assert_eq!(byte_to_key(b'a'), Some(raw_key(KeyCode::Char('a'))));
        assert_eq!(byte_to_key(b'Z'), Some(raw_key(KeyCode::Char('Z'))));
        assert_eq!(byte_to_key(b'5'), Some(raw_key(KeyCode::Char('5'))));
        assert_eq!(byte_to_key(b' '), Some(raw_key(KeyCode::Char(' '))));
        assert_eq!(byte_to_key(0x01), None);
        assert_eq!(byte_to_key(0x1b), None);
    }

    /// Scripted reader: queued chunks in order, then WouldBlock forever.
    struct ScriptedRead {
        chunks: VecDeque<io::Result<Vec<u8>>>,
    }

    impl Read for ScriptedRead {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            match self.chunks.front_mut() {
                None => Err(io::Error::new(io::ErrorKind::WouldBlock, "queue dry")),
                Some(Err(_)) => match self.chunks.pop_front() {
                    Some(Err(e)) => Err(e),
                    _ => unreachable!("front was an Err"),
                },
                Some(Ok(data)) => {
                    let n = data.len().min(buf.len());
                    buf[..n].copy_from_slice(&data[..n]);
                    data.drain(..n);
                    if data.is_empty() {
                        self.chunks.pop_front();
                    }
                    Ok(n)
                }
            }
        }
    }

    fn dry() -> io::Result<Vec<u8>> {
        Err(io::Error::new(io::ErrorKind::WouldBlock, "dry"))
    }

    #[test]
    fn drain_keys_takes_a_pasted_passphrase_in_one_call() {
        let mut r = ScriptedRead {
            chunks: [Ok(b"sardines1\r".to_vec()), dry()].into(),
        };
        let keys = drain_keys(&mut r).unwrap();
        let typed: String = keys
            .iter()
            .filter_map(|k| match k.code {
                KeyCode::Char(c) => Some(c),
                _ => None,
            })
            .collect();
        assert_eq!(typed, "sardines1");
        assert_eq!(keys.last().unwrap().code, KeyCode::Enter);
        assert!(drain_keys(&mut r).unwrap().is_empty());
    }

    #[test]
    fn drain_keys_keeps_order_across_chunks_and_retries_interrupted() {
        let mut r = ScriptedRead {
            chunks: [
                Ok(b"sard".to_vec()),
                Ok(b"ines1".to_vec()),
                Err(io::Error::new(io::ErrorKind::Interrupted, "signal")),
                Ok(b"\r".to_vec()),
                dry(),
            ]
            .into(),
        };
        let keys = drain_keys(&mut r).unwrap();
        assert_eq!(keys.len(), 10, "all bytes, in arrival order");
        assert_eq!(keys.last().unwrap().code, KeyCode::Enter);
    }

    #[test]
    fn drain_keys_propagates_real_errors() {
        let mut r = ScriptedRead {
            chunks: [Err(io::Error::other("boom"))].into(),
        };
        assert!(drain_keys(&mut r).is_err());
    }

    #[test]
    fn keyreader_serves_a_paste_without_lagging_the_poll() {
        let mut kr = KeyReader::new(Some(ScriptedRead {
            chunks: [Ok(b"sardines1\r".to_vec()), dry()].into(),
        }));
        let mut typed = String::new();
        for _ in 0..9 {
            match kr.next_key(Duration::ZERO).unwrap().expect("queued key") {
                KeyEvent {
                    code: KeyCode::Char(c),
                    ..
                } => typed.push(c),
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(typed, "sardines1");
        assert_eq!(
            kr.next_key(Duration::ZERO).unwrap().unwrap().code,
            KeyCode::Enter
        );
    }

    #[test]
    fn keyreader_reports_no_key_after_the_budget_on_a_silent_tty() {
        let mut kr = KeyReader::<ScriptedRead>::new(Some(ScriptedRead {
            chunks: VecDeque::new(),
        }));
        let start = Instant::now();
        assert_eq!(kr.next_key(Duration::from_millis(80)).unwrap(), None);
        assert!(start.elapsed() >= Duration::from_millis(80));
        assert!(
            start.elapsed() < Duration::from_secs(2),
            "bounded waits only"
        );
    }

    #[test]
    fn keyreader_picks_up_a_key_arriving_mid_budget() {
        let mut kr = KeyReader::new(Some(ScriptedRead {
            chunks: [dry(), Ok(b"x".to_vec()), dry()].into(),
        }));
        let k = kr
            .next_key(Duration::from_secs(2))
            .unwrap()
            .expect("key arrives");
        assert_eq!(k.code, KeyCode::Char('x'));
    }

    #[test]
    fn a_long_paste_survives_buffer_growth_in_order_and_wiping_blanks_it() {
        let pasted: Vec<u8> = (0..200u8).map(|i| b'a' + i % 26).collect();
        let mut r = ScriptedRead {
            chunks: [Ok(pasted.clone()), dry()].into(),
        };
        let mut keys = drain_keys(&mut r).unwrap();
        let typed: Vec<u8> = keys
            .iter()
            .map(|k| match k.code {
                KeyCode::Char(c) => c as u8,
                other => panic!("unexpected {other:?}"),
            })
            .collect();
        assert_eq!(typed, pasted);
        wipe_keys(keys.iter_mut());
        assert!(keys.iter().all(|k| k.code == KeyCode::Null));
    }

    #[test]
    fn keyreader_leaves_no_served_key_in_its_queue() {
        let mut kr = KeyReader::new(Some(ScriptedRead {
            chunks: [Ok(b"pw".to_vec()), dry()].into(),
        }));
        assert_eq!(
            kr.next_key(Duration::ZERO).unwrap().unwrap().code,
            KeyCode::Char('p')
        );
        // the queued 'w' is still served, and nothing typed stays behind once it is
        assert_eq!(
            kr.next_key(Duration::ZERO).unwrap().unwrap().code,
            KeyCode::Char('w')
        );
        assert!(kr.pending.is_empty());
    }

    /// A real pipe behind the reader, counting read(2) calls: a poll wait reads only when woken.
    struct CountingPipe {
        file: std::fs::File,
        reads: std::rc::Rc<std::cell::Cell<usize>>,
    }

    impl Read for CountingPipe {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.reads.set(self.reads.get() + 1);
            self.file.read(buf)
        }
    }

    impl AsRawFd for CountingPipe {
        fn as_raw_fd(&self) -> RawFd {
            self.file.as_raw_fd()
        }
    }

    /// (nonblocking read end wrapped in a counting reader, its read counter, write end)
    #[allow(clippy::type_complexity)]
    fn counting_pipe() -> (
        KeyReader<CountingPipe>,
        std::rc::Rc<std::cell::Cell<usize>>,
        std::fs::File,
    ) {
        use std::os::unix::io::FromRawFd as _;
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        unsafe {
            let fl = libc::fcntl(fds[0], libc::F_GETFL);
            assert_eq!(libc::fcntl(fds[0], libc::F_SETFL, fl | libc::O_NONBLOCK), 0);
        }
        let reads = std::rc::Rc::new(std::cell::Cell::new(0));
        let rx = CountingPipe {
            file: unsafe { std::fs::File::from_raw_fd(fds[0]) },
            reads: std::rc::Rc::clone(&reads),
        };
        let tx = unsafe { std::fs::File::from_raw_fd(fds[1]) };
        (KeyReader::pollable(Some(rx)), reads, tx)
    }

    #[test]
    fn a_pollable_reader_wakes_on_the_keypress_not_on_a_slice() {
        use std::io::Write as _;
        let (mut kr, reads, mut tx) = counting_pipe();
        let writer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            tx.write_all(b"x").unwrap();
            tx
        });
        let start = Instant::now();
        let k = kr
            .next_key(Duration::from_secs(5))
            .unwrap()
            .expect("key arrives");
        assert_eq!(k.code, KeyCode::Char('x'));
        assert!(start.elapsed() < Duration::from_secs(2), "woke on the byte");
        // one dry refill up front, then one wake: 40 ms slicing would have read ~8 times
        assert!(
            reads.get() <= 4,
            "{} reads: the wait is polling",
            reads.get()
        );
        drop(writer.join().unwrap());
    }

    #[test]
    fn a_pollable_reader_sleeps_the_whole_budget_on_a_silent_tty() {
        let (mut kr, reads, _tx) = counting_pipe();
        let start = Instant::now();
        assert_eq!(kr.next_key(Duration::from_millis(200)).unwrap(), None);
        assert!(start.elapsed() >= Duration::from_millis(200));
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(reads.get() <= 4, "{} reads on a silent tty", reads.get());
    }

    #[test]
    fn a_hung_up_reader_backs_off_instead_of_spinning() {
        let (mut kr, reads, tx) = counting_pipe();
        drop(tx);
        let start = Instant::now();
        assert_eq!(kr.next_key(Duration::from_millis(200)).unwrap(), None);
        assert!(start.elapsed() >= Duration::from_millis(200));
        // slices only: a spin would read thousands of times
        assert!(reads.get() <= 20, "{} reads after hangup", reads.get());
    }

    #[test]
    fn a_pollable_reader_still_serves_a_paste_in_order_and_leaves_nothing_queued() {
        use std::io::Write as _;
        let (mut kr, _reads, mut tx) = counting_pipe();
        tx.write_all(b"pw\r").unwrap();
        let codes: Vec<KeyCode> = (0..3)
            .map(|_| kr.next_key(Duration::from_secs(1)).unwrap().unwrap().code)
            .collect();
        assert_eq!(
            codes,
            [KeyCode::Char('p'), KeyCode::Char('w'), KeyCode::Enter]
        );
        assert!(kr.pending.is_empty());
    }

    #[test]
    fn keyreader_without_a_reader_only_reports_the_poll_tick() {
        let mut kr: KeyReader<std::io::Empty> = KeyReader::new(None);
        let start = Instant::now();
        assert_eq!(kr.next_key(Duration::from_millis(60)).unwrap(), None);
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn an_unlock_field_takes_any_non_empty_passphrase() {
        let mut f = SecretField::for_unlock("passphrase");
        assert_eq!(f.handle_key(key(KeyCode::Enter)), FieldEvent::TooShort, "empty is still refused");
        f.handle_key(key(KeyCode::Char('x')));
        assert_eq!(f.handle_key(key(KeyCode::Enter)), FieldEvent::Submitted);
        // choosing a passphrase keeps the 8-character rule
        let mut c = SecretField::new("passphrase");
        for ch in "1234567".chars() {
            c.handle_key(key(KeyCode::Char(ch)));
        }
        assert_eq!(c.handle_key(key(KeyCode::Enter)), FieldEvent::TooShort);
    }

    #[test]
    fn linux_console_function_keys_leave_no_stray_letter() {
        // F1..F5 arrive as ESC [ [ A..E: the final letter must not become text
        for last in *b"ABCDE" {
            let mut st = EscState::default();
            let out: Vec<_> = [0x1b, b'[', b'[', last, b'z'].iter().filter_map(|b| st.feed(*b)).collect();
            assert_eq!(out.len(), 1, "only the z after the sequence is a key");
            assert_eq!(out[0].code, KeyCode::Char('z'));
        }
        // ordinary CSI sequences still end at their final byte
        let mut st = EscState::default();
        let out: Vec<_> = [0x1b, b'[', b'1', b'5', b'~', b'q'].iter().filter_map(|b| st.feed(*b)).collect();
        assert_eq!(out.len(), 1);
        let mut st = EscState::default();
        let out: Vec<_> = [0x1b, b'[', b'A', b'q'].iter().filter_map(|b| st.feed(*b)).collect();
        assert_eq!(out.len(), 1);
    }
}
