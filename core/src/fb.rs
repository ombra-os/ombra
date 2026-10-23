//! Pixel face for the boot TUIs: a ratatui backend that paints the cell grid onto the framebuffer.
//! Every failure to open the framebuffer leaves the text console path in charge.

use std::collections::HashMap;
use std::io::{self, Write};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicU32, Ordering};

use fontdue::{Font, FontSettings};
use ratatui::backend::{Backend, ClearType, CrosstermBackend, WindowSize};
use ratatui::buffer::Cell;
use ratatui::layout::{Position, Rect, Size};
use ratatui::style::{Color, Modifier};

use crate::art;
use crate::term::{self, TtyHandle};

static REGULAR_TTF: &[u8] = include_bytes!("../assets/OmbraUI-Regular.ttf");
static BOLD_TTF: &[u8] = include_bytes!("../assets/OmbraUI-Bold.ttf");
static LOGO_ALPHA: &[u8] = include_bytes!("../assets/logo-alpha.a8");
const LOGO_W: usize = 630;
const LOGO_H: usize = 640;

const INK: u32 = 0x0b0c11;
const TEXT_RGB: u32 = 0xf4f3ef;

/// (rows << 16 | cols) of the pixel grid once the framebuffer is in charge; 0 while the text console is.
static PIXEL_GRID: AtomicU32 = AtomicU32::new(0);

pub fn pixel_grid() -> Option<(u16, u16)> {
    let g = PIXEL_GRID.load(Ordering::Relaxed);
    (g != 0).then_some(((g >> 16) as u16, (g & 0xffff) as u16))
}

fn xterm_256(n: u8) -> u32 {
    match n {
        0..=15 => {
            const BASE: [u32; 16] = [
                0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
            ];
            BASE[n as usize]
        }
        16..=231 => {
            let i = n - 16;
            let level = |v: u8| if v == 0 { 0u32 } else { 55 + 40 * v as u32 };
            (level(i / 36) << 16) | (level(i / 6 % 6) << 8) | level(i % 6)
        }
        _ => {
            let v = 8 + 10 * (n as u32 - 232);
            (v << 16) | (v << 8) | v
        }
    }
}

/// The Ombra dusk palette for the theme's 256-color indices; every other color falls back to xterm's.
pub fn color_rgb(c: Color, foreground: bool) -> u32 {
    match c {
        Color::Reset => {
            if foreground {
                TEXT_RGB
            } else {
                INK
            }
        }
        Color::Rgb(r, g, b) => ((r as u32) << 16) | ((g as u32) << 8) | b as u32,
        Color::Indexed(189) | Color::Indexed(255) => TEXT_RGB,
        Color::Indexed(245) => 0x8b8d93,
        Color::Indexed(241) => 0x666973,
        Color::Indexed(78) => 0x56d68a,
        Color::Indexed(210) => 0xf0716b,
        Color::Indexed(221) => 0xf2c260,
        Color::Indexed(105) | Color::Indexed(103) => 0x8f9bff,
        Color::Indexed(60) => 0x363a56,
        Color::Indexed(236) => 0x1c1f2b,
        Color::Indexed(n) => xterm_256(n),
        Color::Black => 0x000000,
        Color::Red | Color::LightRed => 0xf0716b,
        Color::Green | Color::LightGreen => 0x56d68a,
        Color::Yellow | Color::LightYellow => 0xf2c260,
        Color::Blue | Color::LightBlue => 0x8f9bff,
        Color::Magenta | Color::LightMagenta => 0xb48fff,
        Color::Cyan | Color::LightCyan => 0x8fd6ff,
        Color::Gray => 0x8b8d93,
        Color::DarkGray => 0x666973,
        Color::White => TEXT_RGB,
    }
}

fn mix(fg: u32, bg: u32, alpha: u32) -> u32 {
    let ch = |shift: u32| {
        let f = (fg >> shift) & 0xff;
        let b = (bg >> shift) & 0xff;
        (f * alpha + b * (255 - alpha) + 127) / 255
    };
    (ch(16) << 16) | (ch(8) << 8) | ch(0)
}

struct Glyph {
    xmin: i32,
    top: i32,
    w: usize,
    h: usize,
    coverage: Vec<u8>,
}

/// Cell grid to pixels; independent of the device so it can be tested.
pub struct Renderer {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u32>,
    cw: usize,
    ch: usize,
    cols: u16,
    rows: u16,
    ox: usize,
    oy: usize,
    px_size: f32,
    baseline: f32,
    regular: Font,
    bold: Font,
    cache: HashMap<(char, bool), Glyph>,
}

impl Renderer {
    pub fn new(width: usize, height: usize) -> Option<Renderer> {
        let ch = ((height as f32 / 42.0).round() as usize).clamp(18, 44);
        let cw = ((ch as f32 * 0.55).round() as usize).max(8);
        let cols = (width / cw) as u16;
        let rows = (height / ch) as u16;
        if cols < 40 || rows < 16 {
            return None;
        }
        let regular = Font::from_bytes(REGULAR_TTF, FontSettings::default()).ok()?;
        let bold = Font::from_bytes(BOLD_TTF, FontSettings::default()).ok()?;
        let px_size = cw as f32 / 0.6;
        let lm = regular.horizontal_line_metrics(px_size)?;
        let baseline = (ch as f32 - (lm.ascent - lm.descent)) / 2.0 + lm.ascent;
        Some(Renderer {
            width,
            height,
            pixels: vec![INK; width * height],
            cw,
            ch,
            cols,
            rows,
            ox: (width - cols as usize * cw) / 2,
            oy: (height - rows as usize * ch) / 2,
            px_size,
            baseline,
            regular,
            bold,
            cache: HashMap::new(),
        })
    }

    pub fn grid(&self) -> (u16, u16) {
        (self.rows, self.cols)
    }

    pub fn clear(&mut self) {
        self.pixels.iter_mut().for_each(|p| *p = INK);
    }

    fn put(&mut self, x: i64, y: i64, col: u32, alpha: u32) {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height || alpha == 0 {
            return;
        }
        let i = y as usize * self.width + x as usize;
        self.pixels[i] = if alpha >= 255 {
            col
        } else {
            mix(col, self.pixels[i], alpha)
        };
    }

    fn fill(&mut self, x: i64, y: i64, w: i64, h: i64, col: u32) {
        for yy in y..y + h {
            for xx in x..x + w {
                self.put(xx, yy, col, 255);
            }
        }
    }

    fn glyph(&mut self, c: char, bold: bool) -> &Glyph {
        let px = self.px_size;
        let baseline = self.baseline;
        let font = if bold { &self.bold } else { &self.regular };
        self.cache.entry((c, bold)).or_insert_with(|| {
            let (m, coverage) = font.rasterize(c, px);
            Glyph {
                xmin: m.xmin,
                top: (baseline - (m.ymin + m.height as i32) as f32).round() as i32,
                w: m.width,
                h: m.height,
                coverage,
            }
        })
    }

    pub fn draw_cell(&mut self, x: u16, y: u16, cell: &Cell) {
        if x >= self.cols || y >= self.rows {
            return;
        }
        let mut fg = color_rgb(cell.fg, true);
        let mut bg = color_rgb(cell.bg, false);
        if cell.modifier.contains(Modifier::REVERSED) {
            std::mem::swap(&mut fg, &mut bg);
        }
        if cell.modifier.contains(Modifier::DIM) {
            fg = mix(fg, bg, 140);
        }
        let px = (self.ox + x as usize * self.cw) as i64;
        let py = (self.oy + y as usize * self.ch) as i64;
        let (cw, ch) = (self.cw as i64, self.ch as i64);
        self.fill(px, py, cw, ch, bg);
        let Some(c) = cell.symbol().chars().next() else {
            return;
        };
        if c == ' ' {
            return;
        }
        let t = (ch / 14).max(2);
        match c {
            '\u{2588}' => {
                let bar = (cw / 5).max(2);
                self.fill(px + (cw - bar) / 2, py + ch / 8, bar, ch * 3 / 4, fg);
            }
            '\u{00b7}' | '\u{25cf}' => {
                let r = if c == '\u{25cf}' {
                    ch as f32 * 0.26
                } else {
                    ch as f32 * 0.10
                };
                self.disc(
                    px as f32 + cw as f32 / 2.0,
                    py as f32 + ch as f32 / 2.0,
                    r,
                    fg,
                );
            }
            '\u{2500}'..='\u{257f}' => self.box_char(c, px, py, cw, ch, t, fg),
            _ => {
                let bold = cell.modifier.contains(Modifier::BOLD);
                let (gx, gy, gw, gh, cov) = {
                    let g = self.glyph(c, bold);
                    (g.xmin, g.top, g.w, g.h, g.coverage.clone())
                };
                for row in 0..gh {
                    for col in 0..gw {
                        let a = cov[row * gw + col] as u32;
                        self.put(
                            px + (gx + col as i32) as i64,
                            py + (gy + row as i32) as i64,
                            fg,
                            a,
                        );
                    }
                }
            }
        }
        if cell.modifier.contains(Modifier::UNDERLINED) {
            self.fill(px, py + ch - t, cw, t, fg);
        }
    }

    fn disc(&mut self, cx: f32, cy: f32, r: f32, col: u32) {
        let (x0, x1) = ((cx - r - 1.0).floor() as i64, (cx + r + 1.0).ceil() as i64);
        let (y0, y1) = ((cy - r - 1.0).floor() as i64, (cy + r + 1.0).ceil() as i64);
        for y in y0..=y1 {
            for x in x0..=x1 {
                let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                let a = (r - d + 0.5).clamp(0.0, 1.0);
                self.put(x, y, col, (a * 255.0) as u32);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn box_char(&mut self, c: char, px: i64, py: i64, cw: i64, ch: i64, t: i64, col: u32) {
        let (l, r, u, d, round) = match c {
            '\u{2500}' => (true, true, false, false, false),
            '\u{2502}' => (false, false, true, true, false),
            '\u{256d}' => (false, true, false, true, true),
            '\u{256e}' => (true, false, false, true, true),
            '\u{2570}' => (false, true, true, false, true),
            '\u{256f}' => (true, false, true, false, true),
            '\u{250c}' => (false, true, false, true, false),
            '\u{2510}' => (true, false, false, true, false),
            '\u{2514}' => (false, true, true, false, false),
            '\u{2518}' => (true, false, true, false, false),
            '\u{251c}' => (false, true, true, true, false),
            '\u{2524}' => (true, false, true, true, false),
            '\u{252c}' => (true, true, false, true, false),
            '\u{2534}' => (true, true, true, false, false),
            '\u{253c}' => (true, true, true, true, false),
            _ => return,
        };
        let cx = px + (cw - t) / 2;
        let cy = py + (ch - t) / 2;
        let rad = (cw / 2).min(ch / 2);
        if round {
            let (sx, sy) = (if r { 1 } else { -1 }, if d { 1 } else { -1 });
            let acx = (cx as f32 + t as f32 / 2.0) + (sx * rad) as f32;
            let acy = (cy as f32 + t as f32 / 2.0) + (sy * rad) as f32;
            for y in py..py + ch {
                for x in px..px + cw {
                    let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
                    if (fx - acx) * sx as f32 > 0.0 || (fy - acy) * sy as f32 > 0.0 {
                        continue;
                    }
                    let dist = ((fx - acx).powi(2) + (fy - acy).powi(2)).sqrt();
                    let a = (t as f32 / 2.0 + 0.5 - (dist - rad as f32).abs()).clamp(0.0, 1.0);
                    self.put(x, y, col, (a * 255.0) as u32);
                }
            }
            let v_from = if d { cy + t / 2 + rad } else { py };
            let v_to = if d { py + ch } else { cy + t / 2 - rad + t };
            self.fill(cx, v_from.min(v_to), t, (v_to - v_from).abs(), col);
            let h_from = if r { cx + t / 2 + rad } else { px };
            let h_to = if r { px + cw } else { cx + t / 2 - rad + t };
            self.fill(h_from.min(h_to), cy, (h_to - h_from).abs(), t, col);
            return;
        }
        if l {
            self.fill(px, cy, cx - px + t, t, col);
        }
        if r {
            self.fill(cx, cy, px + cw - cx, t, col);
        }
        if u {
            self.fill(cx, py, t, cy - py + t, col);
        }
        if d {
            self.fill(cx, cy, t, py + ch - cy, col);
        }
    }

    /// The emblem, supersampled into the middle of the ring rect (cells).
    pub fn blit_logo(&mut self, rect: Rect) {
        if rect.width == 0 || rect.height == 0 {
            return;
        }
        let area_h = rect.height as usize * self.ch;
        let th = (area_h * 9 / 10).clamp(16, LOGO_H);
        let tw = (th * LOGO_W / LOGO_H).max(1);
        let area_x = self.ox + rect.x as usize * self.cw;
        let area_y = self.oy + rect.y as usize * self.ch;
        let area_w = rect.width as usize * self.cw;
        let x0 = area_x + area_w.saturating_sub(tw) / 2;
        let y0 = area_y + area_h.saturating_sub(th) / 2;
        const SS: usize = 3;
        let at = |x: f32, y: f32| -> f32 {
            let x = x.clamp(0.0, (LOGO_W - 1) as f32);
            let y = y.clamp(0.0, (LOGO_H - 1) as f32);
            let (xi, yi) = (x as usize, y as usize);
            let (xn, yn) = ((xi + 1).min(LOGO_W - 1), (yi + 1).min(LOGO_H - 1));
            let (fx, fy) = (x - xi as f32, y - yi as f32);
            let p = |xx: usize, yy: usize| LOGO_ALPHA[yy * LOGO_W + xx] as f32;
            let top = p(xi, yi) * (1.0 - fx) + p(xn, yi) * fx;
            let bot = p(xi, yn) * (1.0 - fx) + p(xn, yn) * fx;
            top * (1.0 - fy) + bot * fy
        };
        let (sx, sy) = (LOGO_W as f32 / tw as f32, LOGO_H as f32 / th as f32);
        for dy in 0..th {
            for dx in 0..tw {
                let mut sum = 0.0f32;
                for j in 0..SS {
                    for i in 0..SS {
                        let u = (dx as f32 + (i as f32 + 0.5) / SS as f32) * sx - 0.5;
                        let v = (dy as f32 + (j as f32 + 0.5) / SS as f32) * sy - 0.5;
                        sum += at(u, v);
                    }
                }
                let a = (sum / (SS * SS) as f32).round() as u32;
                self.put((x0 + dx) as i64, (y0 + dy) as i64, TEXT_RGB, a);
            }
        }
    }
}

// ---- device ----

const FBIOGET_VSCREENINFO: u64 = 0x4600;
const FBIOGET_FSCREENINFO: u64 = 0x4602;
const KDSETMODE: u64 = 0x4B3A;
const KD_TEXT: libc::c_int = 0;
const KD_GRAPHICS: libc::c_int = 1;

#[cfg(all(target_os = "linux", target_env = "musl"))]
fn req(r: u64) -> libc::c_int {
    r as libc::c_int
}
#[cfg(any(not(target_os = "linux"), not(target_env = "musl")))]
fn req(r: u64) -> libc::c_ulong {
    r as libc::c_ulong
}

fn u32_at(buf: &[u8], off: usize) -> u32 {
    u32::from_ne_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]])
}

struct Fb {
    fd: RawFd,
    map: *mut u8,
    map_len: usize,
    stride: usize,
    shifts: [u32; 3],
}

impl Fb {
    fn open() -> Option<(Fb, usize, usize)> {
        use std::os::unix::io::IntoRawFd as _;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/fb0")
            .ok()?;
        let fd = file.into_raw_fd();
        let mut var = [0u8; 256];
        let mut fix = [0u8; 256];
        // SAFETY: both buffers exceed the kernel structs they receive.
        let ok = unsafe {
            libc::ioctl(fd, req(FBIOGET_VSCREENINFO), var.as_mut_ptr()) == 0
                && libc::ioctl(fd, req(FBIOGET_FSCREENINFO), fix.as_mut_ptr()) == 0
        };
        let (w, h) = (u32_at(&var, 0) as usize, u32_at(&var, 4) as usize);
        let bpp = u32_at(&var, 24);
        let (red, green, blue) = (u32_at(&var, 32), u32_at(&var, 44), u32_at(&var, 56));
        let (rl, gl, bl) = (u32_at(&var, 36), u32_at(&var, 48), u32_at(&var, 60));
        let stride = u32_at(&fix, 48) as usize;
        if !ok || bpp != 32 || (rl, gl, bl) != (8, 8, 8) || w == 0 || h == 0 || stride < w * 4 {
            // SAFETY: fd came from into_raw_fd above.
            unsafe { libc::close(fd) };
            return None;
        }
        let map_len = stride * h;
        // SAFETY: shared mapping of the device's visible pixels.
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                map_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        if map == libc::MAP_FAILED {
            // SAFETY: as above.
            unsafe { libc::close(fd) };
            return None;
        }
        Some((
            Fb {
                fd,
                map: map as *mut u8,
                map_len,
                stride,
                shifts: [red, green, blue],
            },
            w,
            h,
        ))
    }

    fn present(&mut self, r: &Renderer) {
        let [rs, gs, bs] = self.shifts;
        for y in 0..r.height {
            let row = &r.pixels[y * r.width..(y + 1) * r.width];
            // SAFETY: y*stride + w*4 <= map_len by construction in open().
            let dst = unsafe {
                std::slice::from_raw_parts_mut(self.map.add(y * self.stride) as *mut u32, r.width)
            };
            for (d, &p) in dst.iter_mut().zip(row) {
                *d = (((p >> 16) & 0xff) << rs) | (((p >> 8) & 0xff) << gs) | ((p & 0xff) << bs);
            }
        }
    }
}

impl Drop for Fb {
    fn drop(&mut self) {
        // SAFETY: map/map_len/fd are exactly what open() created.
        unsafe {
            libc::munmap(self.map as *mut libc::c_void, self.map_len);
            libc::close(self.fd);
        }
    }
}

pub struct PixelBackend {
    fb: Fb,
    renderer: Renderer,
    tty: TtyHandle,
    cursor: Position,
}

impl PixelBackend {
    fn open(tty: TtyHandle) -> Result<PixelBackend, TtyHandle> {
        let Some((fb, w, h)) = Fb::open() else {
            return Err(tty);
        };
        let Some(renderer) = Renderer::new(w, h) else {
            return Err(tty);
        };
        // SAFETY: plain mode switch on the tty fd we own.
        unsafe { libc::ioctl(tty.raw_fd(), req(KDSETMODE), KD_GRAPHICS) };
        let (rows, cols) = renderer.grid();
        PIXEL_GRID.store(((rows as u32) << 16) | cols as u32, Ordering::Relaxed);
        art::set_pixel_mode(true);
        Ok(PixelBackend {
            fb,
            renderer,
            tty,
            cursor: Position::new(0, 0),
        })
    }
}

impl Drop for PixelBackend {
    fn drop(&mut self) {
        PIXEL_GRID.store(0, Ordering::Relaxed);
        art::set_pixel_mode(false);
        // SAFETY: restores the mode set in open().
        unsafe { libc::ioctl(self.tty.raw_fd(), req(KDSETMODE), KD_TEXT) };
        let _ = self.tty.write_all(b"\x1b[2J\x1b[H");
    }
}

impl Backend for PixelBackend {
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        for (x, y, cell) in content {
            self.renderer.draw_cell(x, y, cell);
        }
        Ok(())
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        Ok(())
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        Ok(())
    }

    fn get_cursor_position(&mut self) -> io::Result<Position> {
        Ok(self.cursor)
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        self.cursor = position.into();
        Ok(())
    }

    fn clear(&mut self) -> io::Result<()> {
        self.renderer.clear();
        Ok(())
    }

    fn clear_region(&mut self, _clear_type: ClearType) -> io::Result<()> {
        self.clear()
    }

    fn size(&self) -> io::Result<Size> {
        let (rows, cols) = self.renderer.grid();
        Ok(Size::new(cols, rows))
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        let (rows, cols) = self.renderer.grid();
        Ok(WindowSize {
            columns_rows: Size::new(cols, rows),
            pixels: Size::new(self.renderer.width as u16, self.renderer.height as u16),
        })
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Some(rect) = art::logo_rect() {
            self.renderer.blit_logo(rect);
        }
        self.fb.present(&self.renderer);
        Ok(())
    }
}

/// Pixel when the framebuffer allows it, the text console otherwise.
pub enum UiBackend {
    Text(CrosstermBackend<Box<dyn Write>>),
    Pixel(Box<PixelBackend>),
}

/// Takes the boot tty and returns the backend plus its grid (rows, cols).
pub fn open_backend(tty: TtyHandle, who: &str) -> io::Result<(UiBackend, (u16, u16))> {
    match PixelBackend::open(tty) {
        Ok(p) => {
            let grid = p.renderer.grid();
            Ok((UiBackend::Pixel(Box::new(p)), grid))
        }
        Err(mut tty) => {
            crate::psf::load_boot_font(tty.raw_fd(), who);
            let grid = tty.measure();
            let mut writer: Box<dyn Write> = Box::new(tty);
            term::apply_console_palette(writer.as_mut())?;
            term::enter_screen(writer.as_mut())?;
            Ok((UiBackend::Text(CrosstermBackend::new(writer)), grid))
        }
    }
}

impl Write for UiBackend {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            UiBackend::Text(b) => b.write(buf),
            UiBackend::Pixel(_) => Ok(buf.len()),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => Write::flush(b),
            UiBackend::Pixel(_) => Ok(()),
        }
    }
}

impl Backend for UiBackend {
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        match self {
            UiBackend::Text(b) => b.draw(content),
            UiBackend::Pixel(b) => b.draw(content),
        }
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => b.hide_cursor(),
            UiBackend::Pixel(b) => b.hide_cursor(),
        }
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => b.show_cursor(),
            UiBackend::Pixel(b) => b.show_cursor(),
        }
    }

    fn get_cursor_position(&mut self) -> io::Result<Position> {
        match self {
            UiBackend::Text(b) => b.get_cursor_position(),
            UiBackend::Pixel(b) => b.get_cursor_position(),
        }
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => b.set_cursor_position(position),
            UiBackend::Pixel(b) => b.set_cursor_position(position),
        }
    }

    fn clear(&mut self) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => b.clear(),
            UiBackend::Pixel(b) => b.clear(),
        }
    }

    fn clear_region(&mut self, clear_type: ClearType) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => b.clear_region(clear_type),
            UiBackend::Pixel(b) => b.clear_region(clear_type),
        }
    }

    fn size(&self) -> io::Result<Size> {
        match self {
            UiBackend::Text(b) => b.size(),
            UiBackend::Pixel(b) => b.size(),
        }
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        match self {
            UiBackend::Text(b) => b.window_size(),
            UiBackend::Pixel(b) => b.window_size(),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            UiBackend::Text(b) => Backend::flush(b),
            UiBackend::Pixel(b) => Backend::flush(b.as_mut()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Style;

    fn cell(sym: &str, style: Style) -> Cell {
        let mut c = Cell::default();
        c.set_symbol(sym);
        c.set_style(style);
        c
    }

    #[test]
    fn grid_follows_the_framebuffer_size() {
        let r = Renderer::new(1280, 800).unwrap();
        let (rows, cols) = r.grid();
        assert!(rows >= 30 && cols >= 90, "{rows}x{cols}");
        assert!(Renderer::new(320, 200).is_none());
    }

    #[test]
    fn a_letter_paints_foreground_pixels_over_ink() {
        let mut r = Renderer::new(1280, 800).unwrap();
        r.draw_cell(3, 3, &cell("A", Style::new().fg(Color::Indexed(255))));
        let lit = r.pixels.iter().filter(|p| **p != INK).count();
        assert!(lit > 20, "{lit}");
    }

    #[test]
    fn the_palette_is_exact_for_the_theme_colors() {
        assert_eq!(color_rgb(Color::Indexed(105), true), 0x8f9bff);
        assert_eq!(color_rgb(Color::Indexed(78), true), 0x56d68a);
        assert_eq!(color_rgb(Color::Reset, false), INK);
    }

    #[test]
    fn border_cells_draw_lines_not_font_glyphs() {
        let mut r = Renderer::new(1280, 800).unwrap();
        let st = Style::new().fg(Color::Indexed(105));
        for sym in [
            "\u{2500}", "\u{2502}", "\u{256d}", "\u{256e}", "\u{2570}", "\u{256f}",
        ] {
            r.clear();
            r.draw_cell(5, 5, &cell(sym, st));
            assert!(r.pixels.iter().any(|p| *p == 0x8f9bff), "{sym}");
        }
    }

    #[test]
    fn the_logo_lands_inside_its_rect() {
        let mut r = Renderer::new(1280, 800).unwrap();
        let rect = Rect::new(10, 4, 60, 8);
        r.blit_logo(rect);
        let lit: Vec<usize> = r
            .pixels
            .iter()
            .enumerate()
            .filter(|(_, p)| **p != INK)
            .map(|(i, _)| i)
            .collect();
        assert!(lit.len() > 500);
        let (cw, ch) = (r.cw, r.ch);
        let (x0, x1) = (r.ox + 10 * cw, r.ox + 70 * cw);
        let (y0, y1) = (r.oy + 4 * ch, r.oy + 12 * ch);
        assert!(lit.iter().all(|i| {
            let (x, y) = (i % r.width, i / r.width);
            x >= x0 && x < x1 && y >= y0 && y < y1
        }));
    }
}
