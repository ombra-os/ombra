//! Vendored PSF console font loader: every failure leaves the stock font in place and never touches the tty stream.

use std::io;
use std::os::unix::io::RawFd;

/// Vendored font: Terminus 8x16, PSF1, 512 glyphs (provenance in the ombra-assets README).
pub static BOOT_FONT: &[u8] = include_bytes!("../assets/Uni2-Terminus16.psf");

const PSF1_MAGIC: [u8; 2] = [0x36, 0x04];
const PSF1_MODE512: u8 = 0x01;
const PSF1_MODEHASTAB: u8 = 0x02;
const PSF1_MODEHASSEQ: u8 = 0x04;
const PSF1_MAXMODE: u8 = PSF1_MODE512 | PSF1_MODEHASTAB | PSF1_MODEHASSEQ;
/// Ends one glyph's Unicode list.
const PSF1_SEPARATOR: u16 = 0xFFFF;
/// Starts a combining sequence inside one glyph's list.
const PSF1_STARTSEQ: u16 = 0xFFFE;

/// The kernel's hard limits: cells up to 32x32, 256 or 512 glyphs.
const MAX_CELL: u32 = 32;
/// KDFONTOP pads every glyph to 32 rows regardless of real height.
const KERNEL_VPITCH: usize = 32;

// uapi/linux/kd.h ioctl numbers — stable for decades.
const KDFONTOP: u64 = 0x4B72;
const PIO_UNIMAP: u64 = 0x4B67;
const PIO_UNIMAPCLR: u64 = 0x4B68;
const KD_FONT_OP_SET: u32 = 0;

/// The ioctl request arg's C type differs by libc (musl: int, glibc: unsigned long); the values fit both.
#[cfg(all(target_os = "linux", target_env = "musl"))]
fn ioctl_request(r: u64) -> libc::c_int {
    r as libc::c_int
}
#[cfg(any(not(target_os = "linux"), not(target_env = "musl")))]
fn ioctl_request(r: u64) -> libc::c_ulong {
    r as libc::c_ulong
}

#[repr(C)]
struct ConsoleFontOp {
    op: u32,
    flags: u32,
    width: u32,
    height: u32,
    charcount: u32,
    /// KDFONTOP wire format: `charcount` glyphs, each 32 padded rows.
    data: *mut u8,
}

#[repr(C)]
struct UnimapInit {
    advised_hashsize: u16,
    advised_hashstep: u16,
    advised_hashlevel: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Unipair {
    unicode: u16,
    fontpos: u16,
}

#[repr(C)]
struct UnimapDesc {
    entry_ct: u16,
    entries: *mut Unipair,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PsfFont {
    pub width: u32,
    pub height: u32,
    /// 256 or 512 — the only counts the kernel accepts.
    pub glyph_count: usize,
    pub glyphs: Vec<u8>,
    /// Bytes per glyph per the header (= height for PSF1); not the kernel wire stride.
    pub glyph_bytes: usize,
    /// Kernel Unicode map: (fontpos, unicode) pairs.
    pub map: Vec<(u16, u16)>,
}

impl PsfFont {
    /// Any malformation is Err here, before the loader can touch an ioctl.
    pub fn parse(bytes: &[u8]) -> Result<PsfFont, &'static str> {
        if bytes.len() < 4 {
            return Err("truncated PSF header");
        }
        let [m0, m1, mode, charsize] = [bytes[0], bytes[1], bytes[2], bytes[3]];
        let rest = &bytes[4..];
        if [m0, m1] != PSF1_MAGIC {
            return Err("not a PSF1 font (bad magic)");
        }
        if mode > PSF1_MAXMODE {
            return Err("unsupported PSF1 mode bits");
        }
        if charsize == 0 {
            return Err("zero-size glyph rows");
        }
        let glyph_count = if mode & PSF1_MODE512 != 0 { 512 } else { 256 };
        // PSF1 rows are one byte: charsize is both glyph size and pixel height.
        let glyph_bytes = charsize as usize;
        let height = glyph_bytes as u32;
        if height > MAX_CELL {
            return Err("glyph cell taller than the kernel's 32-row limit");
        }
        let glyphs_bytes = glyph_count * glyph_bytes;
        let glyphs = rest.get(..glyphs_bytes).ok_or("truncated glyph data")?;
        if mode & PSF1_MODEHASTAB == 0 {
            // a mapless 512-glyph swap is how ASCII breaks; refuse the font
            return Err("font has no embedded Unicode table");
        }
        let table = rest.get(glyphs_bytes..).ok_or("truncated Unicode table")?;
        let map = parse_unimap(table, glyph_count)?;
        Ok(PsfFont {
            width: 8,
            height,
            glyph_count,
            glyphs: glyphs.to_vec(),
            glyph_bytes,
            map,
        })
    }

    /// Test-facing glyph lookup (coverage tests check shapes, not just map presence).
    pub fn glyph_for(&self, unicode: u16) -> Option<&[u8]> {
        let pos = self
            .map
            .iter()
            .find(|&&(_, u)| u == unicode)
            .map(|&(p, _)| p)?;
        let start = pos as usize * self.glyph_bytes;
        self.glyphs.get(start..start + self.glyph_bytes)
    }
}

/// Combining sequences of two or more members drop whole, like kbd's do_loadtable; the table must end at the buffer's end.
fn parse_unimap(table: &[u8], glyph_count: usize) -> Result<Vec<(u16, u16)>, &'static str> {
    let mut pairs = Vec::new();
    let mut cursor = 0usize;
    for fontpos in 0..glyph_count {
        // inseq: 0 = plain value, 1 = right after STARTSEQ, >=2 = appending
        let mut inseq: u32 = 0;
        let mut nodes: Vec<Vec<u16>> = Vec::new();
        loop {
            if cursor + 2 > table.len() {
                return Err("truncated Unicode table");
            }
            let v = u16::from_le_bytes([table[cursor], table[cursor + 1]]);
            cursor += 2;
            match v {
                PSF1_SEPARATOR => break,
                PSF1_STARTSEQ => inseq = 1,
                _ => {
                    if inseq < 2 {
                        nodes.push(vec![v]);
                        if inseq == 1 {
                            inseq = 2;
                        }
                    } else {
                        if let Some(last) = nodes.last_mut() {
                            last.push(v);
                        }
                        inseq += 1;
                    }
                }
            }
        }
        for node in nodes {
            if let [only] = node[..] {
                pairs.push((fontpos as u16, only));
            }
        }
    }
    if cursor != table.len() {
        return Err("trailing garbage after the Unicode table");
    }
    if pairs.len() > u16::MAX as usize {
        return Err("Unicode map larger than the kernel's 16-bit entry count");
    }
    Ok(pairs)
}

/// Load [`BOOT_FONT`] behind `console_fd`; never fails the caller and never writes to the tty stream.
pub fn load_boot_font(console_fd: RawFd, who: &str) {
    let note = match load(console_fd) {
        Ok(what) => what,
        Err(e) => {
            eprintln!("{who}: console font skipped: {e}");
            return;
        }
    };
    eprintln!("{who}: {note}");
}

/// Parse + three ioctls in kbd's order; every error path leaves the stock font in place.
pub fn load(console_fd: RawFd) -> Result<String, String> {
    let font = PsfFont::parse(BOOT_FONT).map_err(|e| format!("bad vendored font ({e})"))?;

    // KDFONTOP: rows go at the top of each 32-row slot; wrong stride = scrambled font.
    let count = font.glyph_count;
    let bytewidth = ((font.width + 7) / 8) as usize;
    let kcharsize = KERNEL_VPITCH * bytewidth;
    let mut buf = vec![0u8; kcharsize * count.max(128)];
    for (i, glyph) in font.glyphs.chunks(font.glyph_bytes).enumerate() {
        debug_assert!(glyph.len() <= kcharsize);
        buf[i * kcharsize..i * kcharsize + glyph.len()].copy_from_slice(glyph);
    }
    let cfo = ConsoleFontOp {
        op: KD_FONT_OP_SET,
        flags: 0,
        width: font.width,
        height: font.height,
        charcount: count as u32,
        data: buf.as_mut_ptr(),
    };
    // SAFETY: cfo/buf outlive the call; the kernel only reads the buffer.
    let rc = unsafe { libc::ioctl(console_fd, ioctl_request(KDFONTOP), &cfo) };
    if rc < 0 {
        let e = io::Error::last_os_error();
        return Err(format!(
            "font ioctl refused, stock font stays ({e}) — corners draw boxy"
        ));
    }

    // 2+3. UNIMAPCLR then UNIMAP; kbd-style ENOMEM retry at higher hash levels.
    let mut pairs: Vec<Unipair> = font
        .map
        .iter()
        .map(|&(fontpos, unicode)| Unipair { unicode, fontpos })
        .collect();
    for hashlevel in [0u16, 1, 4, 16] {
        let clear = UnimapInit {
            advised_hashsize: 0,
            advised_hashstep: 0,
            advised_hashlevel: hashlevel,
        };
        // SAFETY: clear outlives the call; the kernel only reads it.
        let rc = unsafe { libc::ioctl(console_fd, ioctl_request(PIO_UNIMAPCLR), &clear) };
        if rc < 0 {
            let e = io::Error::last_os_error();
            return Err(format!(
                "map clear refused, stock font stays ({e}) — corners draw boxy"
            ));
        }
        let desc = UnimapDesc {
            entry_ct: pairs.len() as u16,
            entries: pairs.as_mut_ptr(),
        };
        // SAFETY: desc/pairs outlive the call; the kernel reads in place.
        let rc = unsafe { libc::ioctl(console_fd, ioctl_request(PIO_UNIMAP), &desc) };
        if rc >= 0 {
            return Ok(format!(
                "boot font Terminus {}x{} loaded ({} glyphs, {} map entries)",
                font.width,
                font.height,
                count,
                pairs.len()
            ));
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::OutOfMemory {
            return Err(format!(
                "map load refused, stock font stays ({e}) — corners draw boxy"
            ));
        }
    }
    Err("map load refused after retries, stock font stays — corners draw boxy".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme;

    #[test]
    fn vendored_font_parses_to_terminus_8x16_512() {
        let f = PsfFont::parse(BOOT_FONT).expect("vendored font must parse");
        assert_eq!(f.width, 8);
        assert_eq!(f.height, 16);
        assert_eq!(f.glyph_count, 512);
        assert_eq!(f.glyphs.len(), 512 * 16);
        assert_eq!(f.glyph_bytes, 16);
        assert!(!f.map.is_empty());
        assert!(f
            .map
            .iter()
            .all(|&(pos, uni)| (pos as usize) < f.glyph_count && uni < PSF1_STARTSEQ));
    }

    /// Every glyph the boot TUIs draw plus printable ASCII must be in the map.
    #[test]
    fn vendored_font_covers_every_glyph_the_boot_uis_draw() {
        let f = PsfFont::parse(BOOT_FONT).expect("vendored font must parse");
        let mut wanted: Vec<char> = theme::boot_glyphs();
        wanted.extend('\u{0020}'..='\u{007e}');
        let missing: Vec<String> = wanted
            .iter()
            .filter(|&&c| !f.map.iter().any(|&(_, u)| u as u32 == c as u32))
            .map(|c| format!("U+{:04X}", *c as u32))
            .collect();
        assert!(missing.is_empty(), "boot font missing glyphs: {missing:?}");
    }

    /// Corners must be rounded, not box fakes: no ink above/below the curve.
    #[test]
    fn corner_glyphs_have_rounded_shapes_not_box_fakes() {
        let f = PsfFont::parse(BOOT_FONT).expect("vendored font must parse");
        let ink = |g: &[u8]| g.iter().any(|&b| b != 0);
        let blank_rows = |uni: u16, rows: std::ops::Range<usize>| -> bool {
            let g = f.glyph_for(uni).expect("map carries the corner");
            rows.clone().all(|r| !ink(&g[r..r + 1]))
        };
        assert!(blank_rows(0x256D, 0..6), "U+256D has ink above the curve");
        assert!(blank_rows(0x256E, 0..6), "U+256E has ink above the curve");
        assert!(blank_rows(0x2570, 8..16), "U+2570 has ink below the curve");
        assert!(blank_rows(0x256F, 8..16), "U+256F has ink below the curve");
        let caret = f.glyph_for(0x2588).expect("caret glyph");
        assert!(
            caret.iter().all(|&b| b == 0xFF),
            "caret is not a full block"
        );
        let dot_ink = f
            .glyph_for(0x00B7)
            .expect("mask glyph")
            .iter()
            .filter(|&&b| b != 0)
            .count();
        assert_eq!(dot_ink, 2, "the mask dot is not a small dot");
    }

    /// Every corruption shape must Err in the pure parser, before any ioctl.
    #[test]
    fn malformed_font_data_is_rejected_before_any_ioctl() {
        let good = BOOT_FONT;
        assert_eq!(PsfFont::parse(&[]), Err("truncated PSF header"));
        assert_eq!(PsfFont::parse(&good[..3]), Err("truncated PSF header"));

        let mut bad_magic = good.to_vec();
        bad_magic[0] = 0x37;
        assert_eq!(
            PsfFont::parse(&bad_magic),
            Err("not a PSF1 font (bad magic)")
        );

        let mut bad_mode = good.to_vec();
        bad_mode[2] = 0x08;
        assert_eq!(PsfFont::parse(&bad_mode), Err("unsupported PSF1 mode bits"));

        let mut zero_rows = good.to_vec();
        zero_rows[3] = 0;
        assert_eq!(PsfFont::parse(&zero_rows), Err("zero-size glyph rows"));

        let cut = &good[..4 + 100];
        assert_eq!(PsfFont::parse(cut), Err("truncated glyph data"));

        let mut no_tab = good.to_vec();
        no_tab[2] ^= PSF1_MODEHASTAB;
        assert_eq!(
            PsfFont::parse(&no_tab),
            Err("font has no embedded Unicode table")
        );

        let table_end = good.len();
        let cut_table = &good[..table_end - 2];
        assert_eq!(PsfFont::parse(cut_table), Err("truncated Unicode table"));

        let mut trailing = good.to_vec();
        trailing.extend_from_slice(&[0x41, 0x00]);
        assert_eq!(
            PsfFont::parse(&trailing),
            Err("trailing garbage after the Unicode table")
        );

        let mut giant = good.to_vec();
        giant[3] = 64;
        assert_eq!(
            PsfFont::parse(&giant),
            Err("glyph cell taller than the kernel's 32-row limit")
        );
    }

    /// Sequence collapse matches kbd's do_loadtable exactly.
    #[test]
    fn unimap_builder_collapses_sequences_like_kbd() {
        // glyph 2's two-member sequence drops; glyph 3's single member is kept
        let mut table: Vec<u8> = Vec::new();
        let push = |t: &mut Vec<u8>, v: u16| t.extend_from_slice(&v.to_le_bytes());
        push(&mut table, 0x0041);
        push(&mut table, PSF1_SEPARATOR);
        push(&mut table, 0x0042);
        push(&mut table, 0x0043);
        push(&mut table, PSF1_SEPARATOR);
        push(&mut table, PSF1_STARTSEQ);
        push(&mut table, 0x0065);
        push(&mut table, 0x0301);
        push(&mut table, PSF1_SEPARATOR);
        push(&mut table, PSF1_STARTSEQ);
        push(&mut table, 0x0066);
        push(&mut table, PSF1_SEPARATOR);
        push(&mut table, PSF1_SEPARATOR);
        let pairs = parse_unimap(&table, 5).expect("well-formed table");
        assert_eq!(
            pairs,
            vec![(0, 0x0041), (1, 0x0042), (1, 0x0043), (3, 0x0066)],
            "sequences collapse exactly like kbd's do_loadtable"
        );
    }

    #[test]
    fn refusal_errors_always_name_the_degradation() {
        // fd -1 fails every ioctl with EBADF
        let note = load(-1).unwrap_err();
        assert!(
            note.contains("stock font stays"),
            "refusal must promise the stock font stays: {note}"
        );
    }
}
