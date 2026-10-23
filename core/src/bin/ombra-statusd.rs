//! ombra-statusd — the desktop's Tor-status daemon. Verdict only: no exit IP, no probe body, no log output.

use std::path::PathBuf;
use std::process::ExitCode;

use ombra_boot::status::{self, ExecProbes};

const USAGE: &str = "\
usage: ombra-statusd [--once | --probe] [--socket PATH] [--cache PATH]

  (default)   daemon: serve one JSON status line per connection on the
              status socket ($XDG_RUNTIME_DIR/ombra-status.sock, fallback
              /tmp/ombra-status-$UID.sock), probes refreshed at most
              once per 30 s in the background
  --once      print one JSON status line to stdout; probe only if the
              cache is stale (TTL 30 s); honors OMBRA_STATUS_FORCE_CACHE
  --probe     print one JSON status line; always fresh probes, no cache
  --socket P  daemon socket path override (tests)
  --cache P   --once cache file override (tests)
  -h, --help  this text

schema: {\"state\":\"ok|semi|fail|unknown\",\"gateway\":bool,\"tor\":bool,
         \"dns\":bool,\"timesync\":\"ok|stale|unknown\",\"checked_unix\":u64,
         \"tooltip\":\"...\"}  — no exit IP is ever included";

enum Mode {
    Daemon {
        socket: Option<PathBuf>,
        cache: Option<PathBuf>,
    },
    Once {
        cache: Option<PathBuf>,
    },
    Probe,
    Help,
}

#[derive(Clone, Copy, PartialEq)]
enum Flavor {
    Daemon,
    Once,
    Probe,
    Help,
}

fn parse_args<I>(args: I) -> Result<Mode, String>
where
    I: IntoIterator<Item = String>,
{
    use Flavor::*;
    let mut flavor = Daemon;
    let mut socket = None;
    let mut cache = None;
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "-h" | "--help" => flavor = Help,
            "--once" => flavor = Once,
            "--probe" => flavor = Probe,
            "--socket" => {
                let path = iter
                    .next()
                    .ok_or_else(|| "--socket needs a PATH argument".to_string())?;
                socket = Some(PathBuf::from(path));
            }
            "--cache" => {
                let path = iter
                    .next()
                    .ok_or_else(|| "--cache needs a PATH argument".to_string())?;
                cache = Some(PathBuf::from(path));
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if socket.is_some() && flavor != Daemon {
        return Err("--socket only applies to daemon mode".into());
    }
    Ok(match flavor {
        Help => Mode::Help,
        Probe => Mode::Probe,
        Once => Mode::Once { cache },
        Daemon => Mode::Daemon { socket, cache },
    })
}

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)) {
        Ok(Mode::Help) => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Ok(mode) => match run(mode) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("ombra-statusd: {e:#}");
                ExitCode::FAILURE
            }
        },
        Err(msg) => {
            eprintln!("ombra-statusd: {msg}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn run(mode: Mode) -> anyhow::Result<()> {
    match mode {
        Mode::Help => Ok(()),
        Mode::Daemon { socket, cache } => {
            let socket = socket.unwrap_or_else(status::socket_path);
            let cache = cache.unwrap_or_else(status::default_cache_path);
            status::daemon(&socket, &cache)
        }
        Mode::Once { cache } => {
            let cache = cache.unwrap_or_else(status::default_cache_path);
            let force =
                status::env_forces_cache(std::env::var_os(status::FORCE_CACHE_ENV).as_deref());
            let mut probes = ExecProbes;
            let snap = status::once_snapshot(&mut probes, &cache, status::now_unix(), force);
            println!("{}", snap.to_json());
            Ok(())
        }
        Mode::Probe => {
            let mut probes = ExecProbes;
            let snap = status::refresh(&mut probes);
            println!("{}", snap.to_json());
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn bare_invocation_is_the_daemon() {
        assert!(matches!(
            parse_args(args(&[])),
            Ok(Mode::Daemon {
                socket: None,
                cache: None
            })
        ));
    }

    #[test]
    fn flags_pick_their_modes_and_overrides() {
        let mode = parse_args(args(&["--socket", "/tmp/x.sock"])).unwrap();
        assert!(
            matches!(mode, Mode::Daemon { socket: Some(p), .. } if p == PathBuf::from("/tmp/x.sock"))
        );

        assert!(matches!(parse_args(args(&["--probe"])), Ok(Mode::Probe)));

        let mode = parse_args(args(&["--once", "--cache", "/tmp/c.json"])).unwrap();
        assert!(matches!(mode, Mode::Once { cache: Some(p) } if p == PathBuf::from("/tmp/c.json")));

        // flag order does not matter
        let mode = parse_args(args(&["--cache", "/tmp/c.json", "--once"])).unwrap();
        assert!(matches!(mode, Mode::Once { cache: Some(p) } if p == PathBuf::from("/tmp/c.json")));

        assert!(matches!(parse_args(args(&["-h"])), Ok(Mode::Help)));
    }

    #[test]
    fn bad_usage_is_a_usage_error_not_a_crash() {
        assert!(parse_args(args(&["--wat"])).is_err());
        assert!(parse_args(args(&["--socket"])).is_err());
        assert!(parse_args(args(&["--cache"])).is_err());
        assert!(parse_args(args(&["--once", "--socket", "/tmp/x"])).is_err());
    }
}
