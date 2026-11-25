//! ombra-boot: everything the user sees between power-on and the session.

pub mod art;
pub mod askpass;
pub mod fb;
pub mod input;
pub mod keyscript;
pub mod panel;
pub mod psf;
pub mod status;
pub mod term;
pub mod theme;
pub mod torctl;
pub mod tproxy;
pub mod welcome;

/// For the programs that hold a passphrase (unlock agent, first-use setup): no core dump, and no other process of the
/// same user may attach or read this one's memory. Best effort; failure changes nothing else.
pub fn no_core_dumps() {
    // SAFETY: both calls take plain values and a pointer to a local, fully initialised struct.
    unsafe {
        let zero = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        libc::setrlimit(libc::RLIMIT_CORE, &zero);
        #[cfg(target_os = "linux")]
        libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0);
    }
}

/// Public-by-design build passphrase; its continued validity IS the first-boot marker.
pub const BUILD_PASSPHRASE: &str = "ombra-disk";
