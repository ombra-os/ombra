//! `ombra` — the desktop's connectivity face as a one-shot panel; draws on the MAIN screen so the final frame stays after exit.

use std::io;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::time::Duration;

use crossterm::cursor::{Hide, Show};
use crossterm::terminal::{Clear, ClearType};
use crossterm::ExecutableCommand;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::art;
use crate::theme;

// ---- the checks' fixed world ----

pub const GW: &str = "10.55.10.1";
pub const SOCKS_ADDR: &str = "10.55.10.1:9050";
pub const TOR_CHECK_URL: &str = "https://check.torproject.org/api/ip";
/// A REAL onion — only Tor's DNSPort automaps .onion names (into 10.66.*).
pub const DNS_PROBE_ONION: &str = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion";
pub const CURL_WRAP_TIMEOUT: &str = "45";
pub const CURL_MAX_TIME: &str = "30";
pub const DIG_TIME: &str = "12";
pub const WATCH_PERIOD: Duration = Duration::from_secs(30);
pub const LABEL_W: usize = 9;
const DOT_W: usize = 2;
pub const RULE_W: usize = 34;

// ---- verdicts ----

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Ok,
    Fail,
    Checking,
}

impl State {
    pub fn color(self) -> Style {
        match self {
            State::Ok => theme::fg(theme::GOOD),
            State::Fail => theme::fg(theme::BAD),
            State::Checking => theme::fg(theme::LABEL),
        }
    }

    pub fn tag(self) -> &'static str {
        match self {
            State::Ok => "[ok]",
            State::Fail => "[fail]",
            State::Checking => "[....]",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Section {
    pub label: &'static str,
    pub verdict: String,
    pub state: State,
}

impl Section {
    fn new(label: &'static str, verdict: impl Into<String>, state: State) -> Section {
        Section {
            label,
            verdict: verdict.into(),
            state,
        }
    }
}

pub fn gateway_section(ping_ok: bool) -> Section {
    if ping_ok {
        Section::new("gateway", "reachable", State::Ok)
    } else {
        Section::new("gateway", "unreachable", State::Fail)
    }
}

pub fn tor_section(body: &str) -> Section {
    if body.contains("\"IsTor\":true") {
        Section::new("tor", "exiting through tor", State::Ok)
    } else {
        Section::new("tor", "not exiting through tor", State::Fail)
    }
}

/// dns: an answer OUTSIDE 10.66.* is the alarm state — the onion resolved without Tor.
pub fn dns_section(first_answer: Option<&str>) -> Section {
    match first_answer {
        Some(a) if !a.is_empty() && a.starts_with("10.66.") => {
            Section::new("dns", "resolves via tor, .onion automaps", State::Ok)
        }
        Some(a) if !a.is_empty() => {
            Section::new("dns", "resolves but .onion automap broken", State::Fail)
        }
        _ => Section::new("dns", "gateway resolver not answering", State::Fail),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeKey {
    Gateway,
    Tor,
    Dns,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub gateway: Section,
    pub tor: Section,
    pub dns: Section,
}

impl Snapshot {
    pub fn checking() -> Snapshot {
        Snapshot {
            gateway: Section::new("gateway", "checking", State::Checking),
            tor: Section::new("tor", "checking", State::Checking),
            dns: Section::new("dns", "checking", State::Checking),
        }
    }

    pub fn apply(&mut self, key: ProbeKey, section: Section) {
        match key {
            ProbeKey::Gateway => self.gateway = section,
            ProbeKey::Tor => self.tor = section,
            ProbeKey::Dns => self.dns = section,
        }
    }

    pub fn is_checking(&self) -> bool {
        self.fails_or_pending() > 0
    }

    pub fn fails(&self) -> usize {
        [&self.gateway, &self.tor, &self.dns]
            .into_iter()
            .filter(|s| s.state == State::Fail)
            .count()
    }

    fn fails_or_pending(&self) -> usize {
        [&self.gateway, &self.tor, &self.dns]
            .into_iter()
            .filter(|s| s.state == State::Checking)
            .count()
    }

    /// While anything is in flight: "checking", never a success promise.
    pub fn summary(&self) -> (String, State) {
        if self.is_checking() {
            return ("checking".to_string(), State::Checking);
        }
        match self.fails() {
            0 => (
                "all traffic routes through tor (gateway)".to_string(),
                State::Ok,
            ),
            n => (format!("attention - {n} of 3 checks failed"), State::Fail),
        }
    }
}

// ---- the probes (exec seam) ----

pub trait ProbeRunner: Send + Sync + 'static {
    fn ping_gateway(&self) -> bool;

    /// Empty string = no answer; the slow-first-circuit retry belongs to the production impl.
    fn tor_body(&self) -> String;

    fn dns_first_answer(&self) -> Option<String>;
}

pub struct SystemRunner;

impl ProbeRunner for SystemRunner {
    fn ping_gateway(&self) -> bool {
        Command::new("ping")
            .args(["-c1", "-W3", GW])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    fn tor_body(&self) -> String {
        let mut body = socks_probe();
        if body.is_empty() {
            // one retry: a fresh first circuit is often slow
            body = socks_probe();
        }
        body
    }

    fn dns_first_answer(&self) -> Option<String> {
        let out = Command::new("dig")
            .args([
                format!("+time={DIG_TIME}"),
                "+tries=1".to_string(),
                "+short".to_string(),
                format!("@{GW}"),
                DNS_PROBE_ONION.to_string(),
                "A".to_string(),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        first_line(&String::from_utf8_lossy(&out.stdout))
    }
}

/// Outer timeout belt over curl; the retry belongs to the caller.
fn socks_probe() -> String {
    Command::new("timeout")
        .arg(CURL_WRAP_TIMEOUT)
        .arg("curl")
        .args([
            "-sS",
            "--max-time",
            CURL_MAX_TIME,
            "--socks5-hostname",
            SOCKS_ADDR,
            TOR_CHECK_URL,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).into_owned())
        .unwrap_or_default()
}

/// dig's `;;` chatter is never an answer; empty output is no answer.
fn first_line(s: &str) -> Option<String> {
    let line = s.lines().find(|l| !l.starts_with(';'))?;
    let t = line.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_owned())
    }
}

pub fn collect_snapshot(runner: &dyn ProbeRunner) -> Snapshot {
    let mut snap = Snapshot::checking();
    snap.apply(ProbeKey::Gateway, gateway_section(runner.ping_gateway()));
    snap.apply(ProbeKey::Tor, tor_section(&runner.tor_body()));
    snap.apply(
        ProbeKey::Dns,
        dns_section(runner.dns_first_answer().as_deref()),
    );
    snap
}

pub fn spawn_probes(runner: Arc<dyn ProbeRunner>) -> Receiver<(ProbeKey, Section)> {
    let (tx, rx) = mpsc::channel::<(ProbeKey, Section)>();
    fn launch(
        tx: mpsc::Sender<(ProbeKey, Section)>,
        name: &str,
        key: ProbeKey,
        job: impl FnOnce() -> Section + Send + 'static,
    ) {
        let _ = std::thread::Builder::new()
            .name(name.to_string())
            .spawn(move || {
                let _ = tx.send((key, job()));
            });
    }
    let r = runner.clone();
    launch(
        tx.clone(),
        "ombra-probe-gateway",
        ProbeKey::Gateway,
        move || gateway_section(r.ping_gateway()),
    );
    let r = runner.clone();
    launch(tx.clone(), "ombra-probe-tor", ProbeKey::Tor, move || {
        tor_section(&r.tor_body())
    });
    launch(tx, "ombra-probe-dns", ProbeKey::Dns, move || {
        dns_section(runner.dns_first_answer().as_deref())
    });
    rx
}

// ---- the panel ----

#[derive(Clone, Copy, Debug)]
pub struct PanelLayout {
    pub ring: Rect,
    pub brand: Rect,
    pub stack: Rect,
    pub footer: Rect,
}

impl PanelLayout {
    pub fn row(&self, i: u16) -> Rect {
        if i >= self.stack.height {
            return Rect {
                x: self.stack.x,
                y: self.stack.y,
                width: 0,
                height: 0,
            };
        }
        Rect {
            x: self.stack.x,
            y: self.stack.y + i,
            width: self.stack.width,
            height: 1,
        }
    }
}

/// The ring yields height first, then disappears; verdicts survive on any terminal.
pub fn layout(area: Rect, with_footer: bool) -> PanelLayout {
    const STACK_H: u16 = 5;
    let footer_h: u16 = if with_footer { 1 } else { 0 };
    let fixed = 1 /* brand */ + 1 /* gap */ + STACK_H + footer_h;
    let avail = area.height.saturating_sub(fixed);
    let ring_h = art::ring_height_for(ring_basis(area.height)).min(avail);
    let top = area.y + area.height.saturating_sub(ring_h + fixed) / 2;
    let ring = Rect {
        x: area.x,
        y: top,
        width: area.width,
        height: ring_h,
    };
    let brand = Rect {
        x: area.x,
        y: top + ring_h,
        width: area.width,
        height: 1,
    };
    let stack_y = brand.y.saturating_add(2);
    let stack = Rect {
        x: area.x,
        y: stack_y,
        width: area.width,
        height: STACK_H.min(area.bottom().saturating_sub(stack_y)),
    };
    let footer = Rect {
        x: area.x,
        y: stack_y + STACK_H,
        width: area.width,
        height: footer_h,
    }
    .intersection(area);
    PanelLayout {
        ring,
        brand,
        stack,
        footer,
    }
}

pub fn draw(f: &mut Frame, snap: &Snapshot, hint: Option<&str>) {
    let area = f.area();
    let l = layout(area, hint.is_some());
    if l.ring.height > 0 {
        f.render_widget(art::Ring::for_console(ring_basis(area.height)), l.ring);
    }

    let sections = [&snap.gateway, &snap.tor, &snap.dns];
    let colw = sections
        .iter()
        .map(|s| DOT_W + LABEL_W + s.verdict.chars().count())
        .max()
        .unwrap_or(0) as u16;
    let rule_w = colw.max(theme::FIELD_WIDTH).min(area.width);
    theme::put_wordmark(f, l.brand, rule_w);
    let x = area.x + area.width.saturating_sub(colw) / 2;
    for (i, sec) in sections.into_iter().enumerate() {
        let row = l.row(i as u16);
        if row.height == 0 {
            break;
        }
        let dot = match sec.state {
            State::Ok => theme::GOOD,
            State::Fail => theme::BAD,
            State::Checking => theme::AMBER,
        };
        let verdict = match sec.state {
            State::Ok => theme::TEXT,
            State::Fail => theme::BAD,
            State::Checking => theme::LABEL,
        };
        let line = Line::from(vec![
            Span::styled(format!("{} ", theme::DOT), theme::fg(dot)),
            Span::styled(
                format!("{:<width$}", sec.label, width = LABEL_W),
                theme::fg(theme::LABEL),
            ),
            Span::styled(sec.verdict.clone(), theme::fg(verdict)),
        ]);
        let rect = Rect {
            x,
            y: row.y,
            width: row.width,
            height: 1,
        };
        f.render_widget(Paragraph::new(line), rect);
    }

    let rule = l.row(3);
    if rule.height > 0 {
        let w = rule_w.min(rule.width);
        let r = theme::center_horiz(rule, w, 1);
        f.render_widget(
            Paragraph::new(Line::styled(
                theme::hairline(w as usize),
                theme::fg(theme::RULE),
            )),
            r,
        );
    }

    let (summary, state) = snap.summary();
    let summary_style = state.color().add_modifier(Modifier::BOLD);
    theme::put_centered(f, l.row(4), &summary, summary_style);

    if let Some(hint) = hint {
        theme::put_centered(f, l.footer, hint, theme::fg(theme::MUTED));
    }
}

// ---- plain-text fallback ----

/// The no-tty / --plain face: pure ASCII, no escape codes.
pub fn plain_text(snap: &Snapshot) -> String {
    let mut out = String::new();
    out.push_str(theme::BRAND);
    out.push('\n');
    out.push_str(&"-".repeat(RULE_W));
    out.push('\n');
    for sec in [&snap.gateway, &snap.tor, &snap.dns] {
        out.push_str(&format!(
            "{:<width$}{:<6} {}\n",
            sec.label,
            sec.state.tag(),
            sec.verdict,
            width = LABEL_W
        ));
    }
    out.push('\n');
    let (summary, _) = snap.summary();
    out.push_str(&summary);
    out.push('\n');
    out
}

// main screen only: the alternate-screen helpers clear on exit, which would wipe the panel

/// Prepare the main screen for the panel: full clear, cursor hidden.
/// The Linux VT draws the half-scale ring at any height; its fixed font makes the full ring huge.
fn ring_basis(height: u16) -> u16 {
    if std::env::var("TERM").is_ok_and(|t| t == "linux") {
        art::COMPACT_BELOW - 1
    } else {
        height
    }
}

pub fn enter(w: &mut dyn io::Write) -> io::Result<()> {
    crate::term::apply_console_palette(w)?;
    w.execute(Clear(ClearType::All))?;
    w.execute(Hide)?;
    w.flush()
}

/// Cursor visible, nothing erased — the last frame stays.
pub fn restore(w: &mut dyn io::Write) -> io::Result<()> {
    w.execute(Show)?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    struct Fake {
        ping: bool,
        tor: &'static str,
        dns: Option<&'static str>,
    }

    impl ProbeRunner for Fake {
        fn ping_gateway(&self) -> bool {
            self.ping
        }
        fn tor_body(&self) -> String {
            self.tor.to_string()
        }
        fn dns_first_answer(&self) -> Option<String> {
            self.dns.map(str::to_owned)
        }
    }

    fn fake_ok() -> Fake {
        Fake {
            ping: true,
            tor: "{\"IsTor\":true,\"IP\":\"185.65.134.72\"}",
            dns: Some("10.66.72.1"),
        }
    }

    fn snap_of(f: &Fake) -> Snapshot {
        collect_snapshot(f)
    }

    fn all_ok() -> Snapshot {
        snap_of(&fake_ok())
    }

    fn with_tor_fail(mut snap: Snapshot) -> Snapshot {
        snap.apply(ProbeKey::Tor, tor_section(""));
        snap
    }

    fn all_fail() -> Snapshot {
        let mut s = Snapshot::checking();
        s.apply(ProbeKey::Gateway, gateway_section(false));
        s.apply(ProbeKey::Tor, tor_section(""));
        s.apply(ProbeKey::Dns, dns_section(None));
        s
    }

    #[test]
    fn gateway_verdicts_are_reachable_or_unreachable() {
        let up = gateway_section(true);
        assert_eq!(
            (up.label, up.verdict.as_str(), up.state),
            ("gateway", "reachable", State::Ok)
        );
        let down = gateway_section(false);
        assert_eq!(
            (down.label, down.verdict.as_str(), down.state),
            ("gateway", "unreachable", State::Fail)
        );
    }

    #[test]
    fn tor_ok_only_on_the_exact_istor_true_substring() {
        let ok = tor_section("{\"IsTor\":true,\"IP\":\"1.2.3.4\"}");
        assert_eq!(
            (ok.label, ok.verdict.as_str(), ok.state),
            ("tor", "exiting through tor", State::Ok)
        );
        assert_eq!(tor_section("{\"IsTor\":true}").state, State::Ok);
    }

    #[test]
    fn tor_fails_on_false_empty_or_spaced_answers() {
        assert_eq!(
            tor_section("{\"IsTor\":false}").verdict,
            "not exiting through tor"
        );
        assert_eq!(tor_section("").state, State::Fail);
        assert_eq!(tor_section("{\"IsTor\": true}").state, State::Fail);
    }

    #[test]
    fn dns_ok_iff_first_answer_automaps_into_10_66() {
        let ok = dns_section(Some("10.66.72.1"));
        assert_eq!(
            (ok.label, ok.verdict.as_str(), ok.state),
            ("dns", "resolves via tor, .onion automaps", State::Ok)
        );
        assert_eq!(dns_section(Some("10.66.")).state, State::Ok);
        assert_eq!(dns_section(Some("1.2.3.4")).state, State::Fail);
    }

    #[test]
    fn dns_silent_gateway_is_not_answering() {
        let none = dns_section(None);
        assert_eq!(none.verdict, "gateway resolver not answering");
        assert_eq!(none.state, State::Fail);
        assert_eq!(
            dns_section(Some("")).verdict,
            "gateway resolver not answering"
        );
    }

    #[test]
    fn dns_broken_verdict_is_a_fixed_string() {
        assert_eq!(
            dns_section(Some("93.184.216.34")).verdict,
            "resolves but .onion automap broken"
        );
    }

    #[test]
    fn verdict_colors_reuse_the_crate_palette() {
        assert_eq!(State::Ok.color().fg, Some(theme::GOOD));
        assert_eq!(State::Fail.color().fg, Some(theme::BAD));
        assert_eq!(State::Checking.color().fg, Some(theme::LABEL));
    }

    #[test]
    fn checking_snapshot_never_promises_success() {
        let s = Snapshot::checking();
        assert_eq!(s.summary(), ("checking".to_string(), State::Checking));
    }

    #[test]
    fn partial_snapshots_still_say_checking() {
        let mut s = Snapshot::checking();
        s.apply(ProbeKey::Gateway, gateway_section(true));
        assert_eq!(s.summary().0, "checking");
    }

    #[test]
    fn summary_three_out_of_three_is_pinned() {
        assert_eq!(
            all_ok().summary(),
            (
                "all traffic routes through tor (gateway)".to_string(),
                State::Ok
            )
        );
    }

    #[test]
    fn summary_counts_failures() {
        assert_eq!(
            with_tor_fail(all_ok()).summary().0,
            "attention - 1 of 3 checks failed"
        );
        assert_eq!(all_fail().summary().0, "attention - 3 of 3 checks failed");
        assert_eq!(all_fail().summary().1, State::Fail);
    }

    #[test]
    fn apply_routes_each_probe_to_its_section() {
        let mut s = Snapshot::checking();
        s.apply(ProbeKey::Dns, dns_section(Some("10.66.1.2")));
        assert_eq!(s.dns.state, State::Ok);
        assert_eq!(s.gateway.state, State::Checking);
        assert_eq!(s.tor.state, State::Checking);
    }

    #[test]
    fn collect_snapshot_runs_all_three_probes() {
        let s = all_ok();
        assert_eq!(s.gateway.state, State::Ok);
        assert_eq!(s.tor.state, State::Ok);
        assert_eq!(s.dns.state, State::Ok);
        assert_eq!(s.fails(), 0);
        assert!(!s.is_checking());
    }

    #[test]
    fn spawn_probes_lands_all_three_sections() {
        let rx = spawn_probes(Arc::new(fake_ok()));
        let mut s = Snapshot::checking();
        for _ in 0..3 {
            let (key, section) = rx.recv().expect("probe result");
            s.apply(key, section);
        }
        assert!(rx.recv().is_err());
        assert_eq!(s, all_ok());
    }

    #[test]
    fn first_line_takes_only_the_first_line() {
        assert_eq!(
            first_line("10.66.1.2\n10.66.1.3\n"),
            Some("10.66.1.2".to_string())
        );
        assert_eq!(first_line(""), None);
        assert_eq!(first_line("\n"), None);
        assert_eq!(first_line("  10.66.1.2  \n"), Some("10.66.1.2".to_string()));
    }

    #[test]
    fn dig_chatter_is_never_an_answer() {
        assert_eq!(
            first_line(";; connection timed out; no servers could be reached"),
            None
        );
        assert_eq!(
            first_line(";; flags: qr rd ra;\n10.66.72.1\n"),
            Some("10.66.72.1".to_string())
        );
    }

    #[test]
    fn plain_text_three_out_of_three_is_pinned() {
        let expected = format!(
            "O M B R A\n{rule}\n\
             gateway  [ok]   reachable\n\
             tor      [ok]   exiting through tor\n\
             dns      [ok]   resolves via tor, .onion automaps\n\n\
             all traffic routes through tor (gateway)\n",
            rule = "-".repeat(RULE_W),
        );
        assert_eq!(plain_text(&all_ok()), expected);
    }

    #[test]
    fn plain_text_failure_shape_is_pinned() {
        let text = plain_text(&with_tor_fail(all_ok()));
        assert!(
            text.contains("tor      [fail] not exiting through tor\n"),
            "{text:?}"
        );
        assert!(
            text.contains("attention - 1 of 3 checks failed\n"),
            "{text:?}"
        );
        assert!(!text.contains('\x1b'));
        assert!(text.is_ascii());
    }

    fn render_at(w: u16, h: u16, snap: &Snapshot, hint: Option<&str>) -> String {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).expect("test backend");
        terminal.draw(|f| draw(f, snap, hint)).expect("draw");
        buffer_text(terminal.backend().buffer())
    }

    fn ring_at_cells(buf: &ratatui::buffer::Buffer) -> usize {
        let mut n = 0;
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                if buf[(x, y)].symbol() == "@" {
                    assert_eq!(
                        buf[(x, y)].fg,
                        theme::RING_BRIGHT,
                        "ring cells are two-tone"
                    );
                    n += 1;
                }
            }
        }
        n
    }

    #[test]
    fn panel_renders_ring_brand_sections_and_summary_at_80x25() {
        let mut terminal = Terminal::new(TestBackend::new(80, 25)).expect("test backend");
        terminal.draw(|f| draw(f, &all_ok(), None)).expect("draw");
        let buf = terminal.backend().buffer().clone();
        let compact: usize = art::ring_rows(25)
            .iter()
            .map(|l| l.matches('@').count())
            .sum();
        assert_eq!(ring_at_cells(&buf), compact, "compact ring fully visible");
        let text = buffer_text(&buf);
        for needle in [
            theme::BRAND,
            "gateway",
            "reachable",
            "tor",
            "exiting through tor",
            "dns",
            "resolves via tor, .onion automaps",
            "all traffic routes through tor (gateway)",
        ] {
            assert!(text.contains(needle), "missing {needle:?} in:\n{text}");
        }
    }

    fn buffer_text(buf: &ratatui::buffer::Buffer) -> String {
        let mut out = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    #[test]
    fn tall_console_shows_the_full_ring() {
        let mut terminal = Terminal::new(TestBackend::new(160, 50)).expect("test backend");
        terminal.draw(|f| draw(f, &all_ok(), None)).expect("draw");
        let buf = terminal.backend().buffer().clone();
        assert_eq!(
            ring_at_cells(&buf),
            art::RING_ART.matches('@').count(),
            "full ring visible"
        );
    }

    #[test]
    fn failing_summaries_render_at_their_counts() {
        let text = render_at(100, 30, &with_tor_fail(all_ok()), None);
        assert!(text.contains("attention - 1 of 3 checks failed"), "{text}");
        assert!(
            !text.contains("all traffic routes through tor (gateway)"),
            "{text}"
        );

        let text = render_at(100, 30, &all_fail(), None);
        assert!(text.contains("attention - 3 of 3 checks failed"), "{text}");
        assert!(text.contains("unreachable"), "{text}");
        assert!(text.contains("gateway resolver not answering"), "{text}");
    }

    #[test]
    fn checking_panel_renders_grey_checks_and_a_checking_summary() {
        let text = render_at(100, 30, &Snapshot::checking(), None);
        assert_eq!(
            text.matches("checking").count(),
            4,
            "three sections + summary:\n{text}"
        );
    }

    #[test]
    fn watch_hint_renders_as_a_footer() {
        let text = render_at(
            100,
            30,
            &all_ok(),
            Some("refreshing every 30s - ctrl-c to quit"),
        );
        assert!(
            text.contains("refreshing every 30s - ctrl-c to quit"),
            "{text}"
        );
    }

    #[test]
    fn tiny_and_narrow_terminals_do_not_panic() {
        let text = render_at(20, 6, &all_ok(), None);
        assert!(text.contains("reachable"), "{text}");
        let text = render_at(
            30,
            25,
            &snap_of(&Fake {
                ping: true,
                tor: "{\"IsTor\":false}",
                dns: Some("93.184.216.34"),
            }),
            None,
        );
        assert!(text.contains("gateway"), "{text}");
    }

    #[test]
    fn layout_is_pinned_at_the_common_sizes() {
        let l = layout(Rect::new(0, 0, 80, 25), false);
        assert_eq!(
            l.ring,
            Rect {
                x: 0,
                y: 3,
                width: 80,
                height: 12
            }
        );
        assert_eq!(
            l.brand,
            Rect {
                x: 0,
                y: 15,
                width: 80,
                height: 1
            }
        );
        assert_eq!(
            l.stack,
            Rect {
                x: 0,
                y: 17,
                width: 80,
                height: 5
            }
        );
        assert_eq!(l.row(4).y, 21, "summary row");
        assert_eq!(l.footer.height, 0, "no hint, no footer");

        let tall = layout(Rect::new(0, 0, 160, 50), true);
        assert_eq!(
            tall.ring,
            Rect {
                x: 0,
                y: 9,
                width: 160,
                height: 23
            }
        );
        assert_eq!(tall.brand.y, 32);
        assert_eq!(tall.stack.y, 34);
        assert_eq!(tall.footer.y, tall.stack.y + 5);
        assert_eq!(tall.footer.height, 1);
    }

    #[test]
    fn rows_clip_to_zero_height_past_the_stack() {
        let l = layout(Rect::new(0, 0, 80, 25), false);
        assert_eq!(l.row(4).height, 1);
        assert_eq!(l.row(5).height, 0);
        assert_eq!(l.row(99).height, 0);
    }

    #[test]
    fn enter_clears_then_hides_in_order() {
        let mut w: Vec<u8> = Vec::new();
        enter(&mut w).expect("enter");
        let s = String::from_utf8(w).expect("utf8");
        let clear = s.find("\x1b[2J").expect("full clear");
        let hide = s.find("\x1b[?25l").expect("cursor hide");
        assert!(clear < hide, "sequence was: {s:?}");
        assert!(!s.contains("1049"), "{s:?}");
    }

    #[test]
    fn restore_shows_the_cursor_and_never_erases_the_panel() {
        let mut w: Vec<u8> = Vec::new();
        restore(&mut w).expect("restore");
        let s = String::from_utf8(w).expect("utf8");
        assert!(s.contains("\x1b[?25h"), "cursor show: {s:?}");
        assert!(!s.contains("\x1b[2J"), "restore must not clear: {s:?}");
        assert!(
            !s.contains("1049"),
            "restore must not leave an alt screen: {s:?}"
        );
    }

    #[test]
    fn enter_then_restore_is_symmetric_and_leaves_the_frame() {
        let mut w: Vec<u8> = Vec::new();
        enter(&mut w).expect("enter");
        restore(&mut w).expect("restore");
        let s = String::from_utf8(w).expect("utf8");
        assert_eq!(s.matches("\x1b[?25l").count(), 1);
        assert_eq!(s.matches("\x1b[?25h").count(), 1);
        assert_eq!(
            s.matches("\x1b[2J").count(),
            1,
            "cleared once, on entry only"
        );
    }
}
