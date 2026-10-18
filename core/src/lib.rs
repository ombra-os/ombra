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
pub mod welcome;

/// Public-by-design build passphrase; its continued validity IS the first-boot marker.
pub const BUILD_PASSPHRASE: &str = "ombra-disk";
