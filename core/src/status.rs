//! ombra-statusd — the desktop's Tor-status engine. Probe bodies are checked and dropped:
//! no exit IP is ever logged or served. Snapshot schema pinned byte-for-byte by tests.

use std::fs;
use std::io::{Read as _, Write as _};
use std::net::Shutdown;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};

pub const GATEWAY: &str = "10.55.10.1";
pub const GATEWAY_SOCKS: &str = "10.55.10.1:9050";
pub const ONION_PROBE: &str = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion";
pub const CACHE_TTL_SECS: u64 = 30;
pub const WARMUP_SECS: u64 = 120;
pub const WARMUP_RETRY_SECS: u64 = 3;
pub const FORCE_CACHE_ENV: &str = "OMBRA_STATUS_FORCE_CACHE";
pub const TIMESYNC_STATE_FILES: &[&str] = &["/run/ombra/timesync", "/var/lib/ombra/timesync"];

/// Kill deadlines so a hung probe never wedges the daemon.
const PING_DEADLINE: Duration = Duration::from_secs(10);
const CURL_DEADLINE: Duration = Duration::from_secs(45);
const DIG_DEADLINE: Duration = Duration::from_secs(15);
const REQUEST_WINDOW: Duration = Duration::from_millis(250);
const TICK: Duration = Duration::from_millis(1000);
const ACCEPT_POLL: Duration = Duration::from_millis(50);

// ---- verdicts ----

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ok,
    Semi,
    Fail,
    Unknown,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Ok => "ok",
            State::Semi => "semi",
            State::Fail => "fail",
            State::Unknown => "unknown",
        }
    }

    pub fn parse(s: &str) -> Option<State> {
        match s {
            "ok" => Some(State::Ok),
            "semi" => Some(State::Semi),
            "fail" => Some(State::Fail),
            "unknown" => Some(State::Unknown),
            _ => None,
        }
    }
}

pub fn state_from_probes(gateway: bool, tor: bool, dns: bool) -> State {
    match usize::from(gateway) + usize::from(tor) + usize::from(dns) {
        3 => State::Ok,
        1 | 2 => State::Semi,
        _ => State::Fail,
    }
}

/// Clock verdict; never part of the LED state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimesyncVerdict {
    Ok,
    Stale,
    Unknown,
}

impl TimesyncVerdict {
    pub fn as_str(self) -> &'static str {
        match self {
            TimesyncVerdict::Ok => "ok",
            TimesyncVerdict::Stale => "stale",
            TimesyncVerdict::Unknown => "unknown",
        }
    }

    pub fn parse(s: &str) -> Option<TimesyncVerdict> {
        match s {
            "ok" => Some(TimesyncVerdict::Ok),
            "stale" => Some(TimesyncVerdict::Stale),
            "unknown" => Some(TimesyncVerdict::Unknown),
            _ => None,
        }
    }
}

pub fn timesync_from_content(content: Option<&str>) -> TimesyncVerdict {
    content
        .and_then(|text| text.lines().next())
        .map(|line| line.trim().to_ascii_lowercase())
        .and_then(|line| TimesyncVerdict::parse(&line))
        .unwrap_or(TimesyncVerdict::Unknown)
}

pub fn timesync_from_files<'a>(paths: impl IntoIterator<Item = &'a Path>) -> TimesyncVerdict {
    for path in paths {
        if let Ok(text) = fs::read_to_string(path) {
            return timesync_from_content(Some(&text));
        }
    }
    TimesyncVerdict::Unknown
}

pub fn read_timesync() -> TimesyncVerdict {
    timesync_from_files(TIMESYNC_STATE_FILES.iter().map(Path::new))
}

/// Fixed per-state strings; no exit IP ever.
pub fn tooltip_for(state: State) -> &'static str {
    match state {
        State::Ok => "Ombra: all systems nominal — all traffic routes through Tor (gateway)",
        State::Semi => "Ombra: partial connectivity — gateway reachable, Tor path degraded",
        State::Fail => "Ombra: ATTENTION — Tor connectivity check failed",
        State::Unknown => "Ombra: checking connectivity…",
    }
}

// ---- snapshot ----

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub state: State,
    pub gateway: bool,
    pub tor: bool,
    pub dns: bool,
    pub timesync: TimesyncVerdict,
    /// Epoch seconds of the last real probe run; 0 = never.
    pub checked_unix: u64,
}

impl Snapshot {
    pub fn never_probed(timesync: TimesyncVerdict) -> Snapshot {
        Snapshot {
            state: State::Unknown,
            gateway: false,
            tor: false,
            dns: false,
            timesync,
            checked_unix: 0,
        }
    }

    /// Field order is pinned byte-for-byte (tests).
    pub fn to_json(&self) -> String {
        format!(
            "{{\"state\":\"{state}\",\"gateway\":{gateway},\"tor\":{tor},\
             \"dns\":{dns},\"timesync\":\"{timesync}\",\"checked_unix\":{checked},\
             \"tooltip\":\"{tooltip}\"}}",
            state = self.state.as_str(),
            gateway = self.gateway,
            tor = self.tor,
            dns = self.dns,
            timesync = self.timesync.as_str(),
            checked = self.checked_unix,
            tooltip = tooltip_for(self.state),
        )
    }
}

/// Strict: unknown words or wrong-typed fields mean None.
pub fn parse_snapshot(line: &str) -> Option<Snapshot> {
    let v: serde_json::Value = serde_json::from_str(line.trim()).ok()?;
    Some(Snapshot {
        state: State::parse(v.get("state")?.as_str()?)?,
        gateway: v.get("gateway")?.as_bool()?,
        tor: v.get("tor")?.as_bool()?,
        dns: v.get("dns")?.as_bool()?,
        timesync: TimesyncVerdict::parse(v.get("timesync")?.as_str()?)?,
        checked_unix: v.get("checked_unix")?.as_u64()?,
    })
}

// ---- probes ----

pub trait Probes {
    fn gateway_link(&mut self) -> bool;
    fn tor_through_gateway(&mut self) -> bool;
    fn gateway_dns_onion(&mut self) -> bool;
}

pub struct ExecProbes;

impl Probes for ExecProbes {
    fn gateway_link(&mut self) -> bool {
        // ping, not a 9050 connect: link state must stay distinct from the Tor probe
        matches!(
            run_captured("ping", &["-c1", "-W3", GATEWAY], PING_DEADLINE),
            Some((true, _))
        )
    }

    fn tor_through_gateway(&mut self) -> bool {
        // body substring, not exit status; body dropped here
        run_captured(
            "curl",
            &[
                "-sS",
                "--max-time",
                "40",
                "--socks5-hostname",
                GATEWAY_SOCKS,
                "https://check.torproject.org/api/ip",
            ],
            CURL_DEADLINE,
        )
        .map_or(false, |(_, body)| body.contains("\"IsTor\":true"))
    }

    fn gateway_dns_onion(&mut self) -> bool {
        // first answer line must land in 10.66.0.0/16; answer dropped here
        run_captured(
            "dig",
            &[
                "+time=12",
                "+tries=1",
                "+short",
                &format!("@{GATEWAY}"),
                ONION_PROBE,
                "A",
            ],
            DIG_DEADLINE,
        )
        .map_or(false, |(_, out)| {
            out.lines()
                .next()
                .map_or(false, |l| l.trim().starts_with("10.66."))
        })
    }
}

/// Kill the child at `deadline` no matter what; the pipe is read only after exit (probe outputs are tiny).
fn run_captured(program: &str, args: &[&str], deadline: Duration) -> Option<(bool, String)> {
    let mut child = std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut out = String::new();
                if let Some(mut pipe) = child.stdout.take() {
                    let _ = pipe.read_to_string(&mut out);
                }
                return Some((status.success(), out));
            }
            Ok(None) => {
                if started.elapsed() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait(); // reap, don't leak a zombie
                    return None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

// ---- refresh ----

pub fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Stamped when the probes FINISH: a slow refresh must not make the cache instantly stale.
pub fn refresh(probes: &mut dyn Probes) -> Snapshot {
    // the Tor and DNS probes only travel through the gateway: no link, no wait
    let gateway = probes.gateway_link();
    let results = if gateway {
        (
            gateway,
            probes.tor_through_gateway(),
            probes.gateway_dns_onion(),
        )
    } else {
        (false, false, false)
    };
    refresh_with(results, read_timesync(), now_unix())
}

pub fn refresh_with(
    results: (bool, bool, bool),
    timesync: TimesyncVerdict,
    snapshot_unix: u64,
) -> Snapshot {
    let (gateway, tor, dns) = results;
    Snapshot {
        state: state_from_probes(gateway, tor, dns),
        gateway,
        tor,
        dns,
        timesync,
        checked_unix: snapshot_unix,
    }
}

// ---- the --once cache ----

pub fn default_cache_path() -> PathBuf {
    default_cache_path_for(std::env::var_os("XDG_RUNTIME_DIR").as_deref(), uid())
}

pub fn default_cache_path_for(xdg_runtime_dir: Option<&std::ffi::OsStr>, uid: u32) -> PathBuf {
    match xdg_runtime_dir {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("ombra-status.cache"),
        _ => PathBuf::from("/tmp").join(format!("ombra-status-{uid}.cache")),
    }
}

pub fn env_forces_cache(value: Option<&std::ffi::OsStr>) -> bool {
    value.map_or(false, |v| !v.is_empty())
}

fn fresh_cache_snapshot(cache: &Path, now: u64) -> Option<Snapshot> {
    let snap = read_cache_snapshot(cache)?;
    (now.saturating_sub(snap.checked_unix) < CACHE_TTL_SECS).then_some(snap)
}

fn read_cache_snapshot(cache: &Path) -> Option<Snapshot> {
    parse_snapshot(&fs::read_to_string(cache).ok()?)
}

/// forced ⇒ cache however old (no probing); else fresh cache; else probe and serve fresh.
pub fn once_snapshot(
    probes: &mut dyn Probes,
    cache: &Path,
    now: u64,
    force_cache: bool,
) -> Snapshot {
    if force_cache {
        return read_cache_snapshot(cache)
            .unwrap_or_else(|| Snapshot::never_probed(read_timesync()));
    }
    if let Some(cached) = fresh_cache_snapshot(cache, now) {
        return cached;
    }
    let snap = refresh(probes);
    let _ = fs::write(cache, snap.to_json());
    snap
}

// ---- daemon ----

pub fn socket_path() -> PathBuf {
    socket_path_for(std::env::var_os("XDG_RUNTIME_DIR").as_deref(), uid())
}

pub fn socket_path_for(xdg_runtime_dir: Option<&std::ffi::OsStr>, uid: u32) -> PathBuf {
    match xdg_runtime_dir {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir).join("ombra-status.sock"),
        _ => PathBuf::from("/tmp").join(format!("ombra-status-{uid}.sock")),
    }
}

fn uid() -> u32 {
    unsafe { libc::getuid() }
}

/// Re-probe quickly until the first all-clear after start, then on the steady TTL.
pub fn probe_interval(state: State, since_start: Duration) -> Duration {
    if state != State::Ok && since_start < Duration::from_secs(WARMUP_SECS) {
        Duration::from_secs(WARMUP_RETRY_SECS)
    } else {
        Duration::from_secs(CACHE_TTL_SECS)
    }
}

/// Bind first (clients get a clean `unknown`, never a refused connection); refresh and persist in the background.
pub fn daemon(socket: &Path, cache: &Path) -> Result<()> {
    let snapshot = Arc::new(Mutex::new(Snapshot::never_probed(read_timesync())));
    let listener = bind_socket(socket)?;
    let running = Arc::new(AtomicBool::new(true));
    daemon_on(listener, snapshot, running, Box::new(ExecProbes), cache)
}

fn daemon_on(
    listener: UnixListener,
    snapshot: Arc<Mutex<Snapshot>>,
    running: Arc<AtomicBool>,
    probes: Box<dyn Probes + Send>,
    cache: &Path,
) -> Result<()> {
    let cache = cache.to_path_buf();
    let refresher = {
        let snapshot = Arc::clone(&snapshot);
        let running = Arc::clone(&running);
        std::thread::Builder::new()
            .name("ombra-status-refresh".into())
            .spawn(move || {
                let mut probes = probes;
                // monotonic anchor: immune to clock steps
                let started = Instant::now();
                let mut last = Option::<(Instant, State)>::None;
                while running.load(Ordering::Relaxed) {
                    let due = last.map_or(true, |(at, state)| {
                        at.elapsed() >= probe_interval(state, started.elapsed())
                    });
                    if due {
                        let (snap, line) = {
                            let s = refresh(&mut *probes);
                            let line = s.to_json();
                            (s, line)
                        };
                        let state = snap.state;
                        *lock(&snapshot) = snap;
                        let _ = fs::write(&cache, line);
                        last = Some((Instant::now(), state));
                    }
                    std::thread::sleep(TICK);
                }
            })
            .context("spawning the refresh thread")?
    };

    let result = serve_loop(listener, &snapshot, &running);
    running.store(false, Ordering::Relaxed);
    let _ = refresher.join();
    result
}

/// Poisoning is not a status failure; recover the data and keep serving.
fn lock(snapshot: &Mutex<Snapshot>) -> MutexGuard<'_, Snapshot> {
    snapshot
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Mode 0600; a leftover socket file is removed unless a live peer answers.
pub fn bind_socket(path: &Path) -> Result<UnixListener> {
    let listener = match UnixListener::bind(path) {
        Ok(l) => l,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            if UnixStream::connect(path).is_ok() {
                bail!(
                    "another ombra-statusd is already serving {}",
                    path.display()
                );
            }
            let _ = fs::remove_file(path);
            UnixListener::bind(path).with_context(|| format!("binding {}", path.display()))?
        }
        Err(e) => return Err(e).with_context(|| format!("binding {}", path.display())),
    };
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    Ok(listener)
}

pub fn serve_loop(
    listener: UnixListener,
    snapshot: &Mutex<Snapshot>,
    running: &AtomicBool,
) -> Result<()> {
    listener
        .set_nonblocking(true)
        .context("arming the listener")?;
    while running.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => handle_connection(stream, snapshot),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(ACCEPT_POLL);
            }
            Err(e) => return Err(e).context("accepting a status client"),
        }
    }
    Ok(())
}

/// Any client input means the same thing: send the snapshot line, close.
fn handle_connection(mut stream: UnixStream, snapshot: &Mutex<Snapshot>) {
    stream.set_read_timeout(Some(REQUEST_WINDOW)).ok();
    let mut request = [0u8; 64];
    let _ = stream.read(&mut request);
    let mut line = lock(snapshot).to_json();
    line.push('\n');
    let _ = stream.write_all(line.as_bytes());
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    struct FakeProbes {
        triple: (bool, bool, bool),
        calls: Cell<u32>,
    }

    impl FakeProbes {
        fn all_ok() -> FakeProbes {
            FakeProbes {
                triple: (true, true, true),
                calls: Cell::new(0),
            }
        }
        fn counting(probes_run: u32) -> FakeProbes {
            let triple = match probes_run {
                3 => (true, true, true),
                2 => (true, true, false),
                1 => (true, false, false),
                _ => (false, false, false),
            };
            FakeProbes {
                triple,
                calls: Cell::new(0),
            }
        }
        fn bump(&self) {
            self.calls.set(self.calls.get() + 1);
        }
    }

    impl Probes for FakeProbes {
        fn gateway_link(&mut self) -> bool {
            self.bump();
            self.triple.0
        }
        fn tor_through_gateway(&mut self) -> bool {
            self.bump();
            self.triple.1
        }
        fn gateway_dns_onion(&mut self) -> bool {
            self.bump();
            self.triple.2
        }
    }

    fn tempdir(tag: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("ombra-status-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn snapshot(g: bool, t: bool, d: bool, state: State, timesync: TimesyncVerdict) -> Snapshot {
        Snapshot {
            state,
            gateway: g,
            tor: t,
            dns: d,
            timesync,
            checked_unix: 1_700_000_000,
        }
    }

    #[test]
    fn state_mapping_matches_the_script_counts() {
        assert_eq!(state_from_probes(true, true, true), State::Ok);
        assert_eq!(state_from_probes(false, true, true), State::Semi);
        assert_eq!(state_from_probes(true, false, true), State::Semi);
        assert_eq!(state_from_probes(true, true, false), State::Semi);
        assert_eq!(state_from_probes(true, false, false), State::Semi);
        assert_eq!(state_from_probes(false, true, false), State::Semi);
        assert_eq!(state_from_probes(false, false, true), State::Semi);
        assert_eq!(state_from_probes(false, false, false), State::Fail);
    }

    #[test]
    fn refresh_runs_all_three_probes_and_maps_the_verdict() {
        let mut probes = FakeProbes::counting(2);
        let snap = refresh(&mut probes);
        assert_eq!(probes.calls.get(), 3);
        assert_eq!(snap.state, State::Semi);
        assert!(snap.gateway && snap.tor && !snap.dns);
        assert!(snap.checked_unix > 0 && snap.checked_unix <= now_unix());
    }

    #[test]
    fn refresh_with_assembles_a_snapshot_from_supplied_results() {
        let snap = refresh_with((true, true, false), TimesyncVerdict::Stale, 500);
        assert_eq!(snap.state, State::Semi);
        assert_eq!(snap.timesync, TimesyncVerdict::Stale);
        assert_eq!(snap.checked_unix, 500);
    }

    /// THE byte contract for clients; changes here are schema bumps.
    #[test]
    fn json_schema_is_pinned_golden_ok() {
        let snap = snapshot(true, true, true, State::Ok, TimesyncVerdict::Ok);
        assert_eq!(
            snap.to_json(),
            "{\"state\":\"ok\",\"gateway\":true,\"tor\":true,\"dns\":true,\
              \"timesync\":\"ok\",\"checked_unix\":1700000000,\
              \"tooltip\":\"Ombra: all systems nominal — all traffic routes through Tor (gateway)\"}"
        );
    }

    #[test]
    fn json_schema_is_pinned_golden_never_probed() {
        assert_eq!(
            Snapshot::never_probed(TimesyncVerdict::Unknown).to_json(),
            "{\"state\":\"unknown\",\"gateway\":false,\"tor\":false,\"dns\":false,\
              \"timesync\":\"unknown\",\"checked_unix\":0,\
              \"tooltip\":\"Ombra: checking connectivity…\"}"
        );
    }

    #[test]
    fn snapshot_lines_round_trip_through_the_parser() {
        for snap in [
            snapshot(true, true, true, State::Ok, TimesyncVerdict::Ok),
            snapshot(true, true, false, State::Semi, TimesyncVerdict::Stale),
            snapshot(false, false, false, State::Fail, TimesyncVerdict::Unknown),
            Snapshot::never_probed(TimesyncVerdict::Unknown),
        ] {
            assert_eq!(parse_snapshot(&snap.to_json()), Some(snap));
        }
    }

    #[test]
    fn parser_rejects_garbage_wrong_types_and_unknown_words() {
        assert_eq!(parse_snapshot(""), None);
        assert_eq!(parse_snapshot("ok"), None);
        assert_eq!(parse_snapshot("not json {"), None);
        assert_eq!(
            parse_snapshot(
                "{\"state\":5,\"gateway\":true,\"tor\":true,\"dns\":true,\
                            \"timesync\":\"ok\",\"checked_unix\":1}"
            ),
            None
        );
        assert_eq!(
            parse_snapshot(
                "{\"state\":\"mega\",\"gateway\":true,\"tor\":true,\"dns\":true,\
                            \"timesync\":\"ok\",\"checked_unix\":1}"
            ),
            None
        );
        assert_eq!(
            parse_snapshot(
                "{\"state\":\"ok\",\"gateway\":true,\"tor\":true,\"dns\":true,\
                            \"timesync\":\"ok\"}"
            ),
            None
        );
        let snap = parse_snapshot(
            "{\"state\":\"ok\",\"gateway\":true,\"tor\":true,\"dns\":true,\
              \"timesync\":\"ok\",\"checked_unix\":1,\"tooltip\":\"RUN sudo evil\"}",
        )
        .unwrap();
        assert_eq!(tooltip_for(snap.state), tooltip_for(State::Ok));
    }

    #[test]
    fn tooltips_match_the_script_strings() {
        assert_eq!(
            tooltip_for(State::Ok),
            "Ombra: all systems nominal — all traffic routes through Tor (gateway)"
        );
        assert_eq!(
            tooltip_for(State::Semi),
            "Ombra: partial connectivity — gateway reachable, Tor path degraded"
        );
        assert_eq!(
            tooltip_for(State::Fail),
            "Ombra: ATTENTION — Tor connectivity check failed"
        );
        assert_eq!(tooltip_for(State::Unknown), "Ombra: checking connectivity…");
    }

    /// Tooltips are inserted verbatim into JSON: escape-free and address-free by contract.
    #[test]
    fn tooltips_stay_escape_free_and_exit_ip_free() {
        for state in [State::Ok, State::Semi, State::Fail, State::Unknown] {
            let tip = tooltip_for(state);
            assert!(!tip.contains('"'), "{tip:?} must not contain a quote");
            assert!(!tip.contains('\\'), "{tip:?} must not contain a backslash");
            assert!(!tip.contains('\n'), "{tip:?} must not contain a newline");
            let words: Vec<&str> = tip.split_whitespace().collect();
            for w in words {
                assert!(
                    w.chars().filter(|c| c.is_ascii_digit()).count() < 3,
                    "{tip:?} must not carry an address-like token ({w})"
                );
            }
        }
    }

    #[test]
    fn once_probes_when_the_cache_is_missing_then_serves_it_fresh() {
        let dir = tempdir("fresh");
        let cache = dir.join("cache");
        let mut probes = FakeProbes::all_ok();

        let first = once_snapshot(&mut probes, &cache, 0, false);
        assert_eq!(probes.calls.get(), 3, "no cache: all three probes ran");
        assert_eq!(
            fs::read_to_string(&cache).unwrap(),
            first.to_json(),
            "the cache file IS the snapshot line"
        );
        assert!(first.checked_unix > 0 && first.checked_unix <= now_unix());

        let t = first.checked_unix;
        let fresh = once_snapshot(&mut probes, &cache, t + CACHE_TTL_SECS - 1, false);
        assert_eq!(
            probes.calls.get(),
            3,
            "TTL-1 s old: still fresh, no re-probe"
        );
        assert_eq!(fresh, first);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn once_reprobes_once_the_ttl_expires() {
        let dir = tempdir("stale");
        let cache = dir.join("cache");
        let mut probes = FakeProbes::all_ok();

        let first = once_snapshot(&mut probes, &cache, 0, false);
        let t = first.checked_unix;
        let later = once_snapshot(&mut probes, &cache, t + CACHE_TTL_SECS, false);
        assert_eq!(probes.calls.get(), 6, "TTL reached: re-probed");
        assert_eq!(
            fs::read_to_string(&cache).unwrap(),
            later.to_json(),
            "the cache follows the fresh snapshot"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn forced_cache_serves_any_age_without_probing() {
        let dir = tempdir("forced");
        let cache = dir.join("cache");
        let mut probes = FakeProbes::all_ok();

        let first = once_snapshot(&mut probes, &cache, 0, false);
        let forced = once_snapshot(&mut probes, &cache, first.checked_unix + 999_999, true);
        assert_eq!(probes.calls.get(), 3, "forced: no probes, however old");
        assert_eq!(forced, first, "the ancient snapshot is served");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn forced_cache_with_no_cache_is_unknown_and_never_probes() {
        let dir = tempdir("forced-none");
        let cache = dir.join("absent");
        let mut probes = FakeProbes::all_ok();

        let snap = once_snapshot(&mut probes, &cache, 0, true);
        assert_eq!(
            probes.calls.get(),
            0,
            "the script's escape hatch forbids probing"
        );
        assert_eq!(snap.state, State::Unknown);
        assert!(!snap.gateway && !snap.tor && !snap.dns);
        assert_eq!(snap.checked_unix, 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_cache_is_ignored_and_reprobed() {
        let dir = tempdir("corrupt");
        let cache = dir.join("cache");
        fs::write(&cache, "ok\n").unwrap();
        let mut probes = FakeProbes::all_ok();

        let snap = once_snapshot(&mut probes, &cache, 0, false);
        assert_eq!(probes.calls.get(), 3);
        assert_eq!(snap.state, State::Ok);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn once_output_shape_is_the_pinned_line() {
        let dir = tempdir("once-shape");
        let cache = dir.join("cache");
        let mut probes = FakeProbes::counting(3);

        let snap = once_snapshot(&mut probes, &cache, 0, false);
        let line = snap.to_json();
        assert_eq!(
            line.lines().count(),
            1,
            "one line, no trailing newline baked in"
        );

        let rest = line
            .strip_prefix(
                "{\"state\":\"ok\",\"gateway\":true,\"tor\":true,\"dns\":true,\"timesync\":\"",
            )
            .unwrap_or_else(|| panic!("field order/spelling drifted: {line}"));
        let (timesync, rest) = rest
            .split_once("\",\"checked_unix\":")
            .unwrap_or_else(|| panic!("no checked_unix field: {line}"));
        assert!(
            ["ok", "stale", "unknown"].contains(&timesync),
            "timesync must be a verdict word, got {timesync:?}"
        );
        let (stamp, tooltip) = rest
            .split_once(",\"tooltip\":\"")
            .unwrap_or_else(|| panic!("no tooltip field: {line}"));
        assert!(
            !stamp.is_empty() && stamp.chars().all(|c| c.is_ascii_digit()),
            "checked_unix must be an integer, got {stamp:?}"
        );
        assert_eq!(
            tooltip,
            "Ombra: all systems nominal — all traffic routes through Tor (gateway)\"}"
        );

        assert!(parse_snapshot(&line).is_some());
        let cached = once_snapshot(&mut probes, &cache, snap.checked_unix + 1, false);
        assert_eq!(cached.to_json(), line);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn env_forces_cache_like_the_script_escape_hatch() {
        assert!(env_forces_cache(Some(std::ffi::OsStr::new("1"))));
        assert!(env_forces_cache(Some(std::ffi::OsStr::new("yes"))));
        assert!(!env_forces_cache(Some(std::ffi::OsStr::new(""))));
        assert!(!env_forces_cache(None));
    }

    #[test]
    fn socket_and_cache_paths_follow_xdg_with_uid_fallback() {
        use std::ffi::OsStr;
        let xdg = Some(OsStr::new("/run/user/1000"));
        assert_eq!(
            socket_path_for(xdg, 1000),
            PathBuf::from("/run/user/1000/ombra-status.sock")
        );
        assert_eq!(
            default_cache_path_for(xdg, 1000),
            PathBuf::from("/run/user/1000/ombra-status.cache")
        );
        assert_eq!(
            socket_path_for(None, 42),
            PathBuf::from("/tmp/ombra-status-42.sock")
        );
        assert_eq!(
            default_cache_path_for(None, 42),
            PathBuf::from("/tmp/ombra-status-42.cache")
        );
        assert_eq!(
            socket_path_for(Some(OsStr::new("")), 7),
            PathBuf::from("/tmp/ombra-status-7.sock")
        );
    }

    #[test]
    fn timesync_reads_the_verdict_word_and_never_fails() {
        assert_eq!(timesync_from_content(Some("ok\n")), TimesyncVerdict::Ok);
        assert_eq!(
            timesync_from_content(Some("stale\n")),
            TimesyncVerdict::Stale
        );
        assert_eq!(timesync_from_content(Some("  OK  \n")), TimesyncVerdict::Ok);
        assert_eq!(
            timesync_from_content(Some("junk\n")),
            TimesyncVerdict::Unknown
        );
        assert_eq!(timesync_from_content(Some("")), TimesyncVerdict::Unknown);
        assert_eq!(timesync_from_content(None), TimesyncVerdict::Unknown);
    }

    #[test]
    fn timesync_state_files_first_existing_file_wins() {
        let dir = tempdir("timesync");
        let run = dir.join("run");
        let var = dir.join("var");
        fs::create_dir_all(&run).unwrap();
        fs::create_dir_all(&var).unwrap();

        let paths = [run.join("timesync"), var.join("timesync")];

        assert_eq!(
            timesync_from_files(paths.iter().map(|p| p.as_path())),
            TimesyncVerdict::Unknown
        );
        fs::write(&paths[1], "stale\n").unwrap();
        assert_eq!(
            timesync_from_files(paths.iter().map(|p| p.as_path())),
            TimesyncVerdict::Stale
        );
        fs::write(&paths[0], "ok\n").unwrap();
        assert_eq!(
            timesync_from_files(paths.iter().map(|p| p.as_path())),
            TimesyncVerdict::Ok
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn socket_round_trip_serves_the_snapshot_line() {
        let dir = tempdir("sock");
        let path = dir.join("s.sock"); // AF_UNIX path caps
        let shared = Arc::new(Mutex::new(snapshot(
            true,
            true,
            true,
            State::Ok,
            TimesyncVerdict::Ok,
        )));
        let running = Arc::new(AtomicBool::new(true));
        let listener = bind_socket(&path).unwrap();
        let server = {
            let shared = Arc::clone(&shared);
            let running = Arc::clone(&running);
            std::thread::spawn(move || {
                serve_loop(listener, &shared, &running).unwrap();
            })
        };

        let mut c1 = UnixStream::connect(&path).unwrap();
        c1.write_all(b"GET\n").unwrap();
        let mut line1 = String::new();
        c1.read_to_string(&mut line1).unwrap();
        let parsed = parse_snapshot(&line1).expect("a parseable snapshot line");
        assert_eq!(parsed.state, State::Ok);
        assert!(parsed.gateway && parsed.tor && parsed.dns);
        assert!(
            line1.ends_with('\n'),
            "exactly one line, newline-terminated"
        );
        assert_eq!(line1.lines().count(), 1);

        let mut c2 = UnixStream::connect(&path).unwrap();
        let mut line2 = String::new();
        c2.read_to_string(&mut line2).unwrap();
        assert_eq!(line2, line1, "same snapshot whichever client style");

        *lock(&shared) = snapshot(false, false, false, State::Fail, TimesyncVerdict::Unknown);
        let mut c3 = UnixStream::connect(&path).unwrap();
        let mut line3 = String::new();
        c3.read_to_string(&mut line3).unwrap();
        assert_eq!(parse_snapshot(&line3).unwrap().state, State::Fail);

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        running.store(false, Ordering::Relaxed);
        server.join().unwrap();
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn probing_is_quick_only_while_warming_up_and_not_ok() {
        let early = Duration::from_secs(10);
        let late = Duration::from_secs(WARMUP_SECS + 1);
        assert_eq!(
            probe_interval(State::Unknown, early),
            Duration::from_secs(WARMUP_RETRY_SECS)
        );
        assert_eq!(
            probe_interval(State::Fail, early),
            Duration::from_secs(WARMUP_RETRY_SECS)
        );
        assert_eq!(
            probe_interval(State::Semi, early),
            Duration::from_secs(WARMUP_RETRY_SECS)
        );
        assert_eq!(
            probe_interval(State::Ok, early),
            Duration::from_secs(CACHE_TTL_SECS)
        );
        assert_eq!(
            probe_interval(State::Fail, late),
            Duration::from_secs(CACHE_TTL_SECS)
        );
    }

    #[test]
    fn bind_refuses_to_fight_a_live_daemon_but_clears_a_dead_socket() {
        let dir = tempdir("bind");
        let path = dir.join("s.sock");

        let live = UnixListener::bind(&path).unwrap();
        let err = bind_socket(&path).unwrap_err();
        assert!(
            err.to_string().contains("already serving"),
            "a live peer must be reported, got: {err:#}"
        );

        drop(live);
        let mut rebound = bind_socket(&path);
        for _ in 0..50 {
            if rebound.is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
            rebound = bind_socket(&path);
        }
        assert!(
            rebound.is_ok(),
            "a stale socket file gets cleared: {rebound:?}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    struct GatedProbes {
        gate: Arc<AtomicBool>,
    }

    impl Probes for GatedProbes {
        fn gateway_link(&mut self) -> bool {
            while !self.gate.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(10));
            }
            true
        }
        fn tor_through_gateway(&mut self) -> bool {
            true
        }
        fn gateway_dns_onion(&mut self) -> bool {
            true
        }
    }

    #[test]
    fn daemon_serves_unknown_then_the_refresh_lands_then_stops() {
        let dir = tempdir("daemon");
        let path = dir.join("d.sock");
        let cache = dir.join("d.cache");
        let listener = bind_socket(&path).unwrap();
        let snapshot = Arc::new(Mutex::new(Snapshot::never_probed(TimesyncVerdict::Unknown)));
        let running = Arc::new(AtomicBool::new(true));
        let gate = Arc::new(AtomicBool::new(false));
        let server = {
            let (snapshot, running, gate) = (
                Arc::clone(&snapshot),
                Arc::clone(&running),
                Arc::clone(&gate),
            );
            let cache = cache.clone();
            std::thread::spawn(move || {
                daemon_on(
                    listener,
                    snapshot,
                    running,
                    Box::new(GatedProbes { gate }),
                    &cache,
                )
            })
        };

        let mut c = UnixStream::connect(&path).unwrap();
        let mut line = String::new();
        c.read_to_string(&mut line).unwrap();
        assert_eq!(parse_snapshot(&line).unwrap().state, State::Unknown);

        gate.store(true, Ordering::Relaxed);
        std::thread::sleep(TICK * 2);
        let mut c = UnixStream::connect(&path).unwrap();
        let mut line = String::new();
        c.read_to_string(&mut line).unwrap();
        assert_eq!(parse_snapshot(&line).unwrap().state, State::Ok);

        let persisted = read_cache_snapshot(&cache).unwrap();
        assert_eq!(persisted.state, State::Ok);

        running.store(false, Ordering::Relaxed);
        server.join().unwrap().unwrap();
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[ignore = "needs the real 10.55.10.1 gateway; dev machines have none"]
    fn live_probes_against_a_real_gateway() {
        let mut probes = ExecProbes;
        let snap = refresh(&mut probes);
        let line = snap.to_json();
        assert!(parse_snapshot(&line).is_some());
        eprintln!("live snapshot: {line}");
    }
}
