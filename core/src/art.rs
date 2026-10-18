//! The official ring, rendered two-tone: '@' cells bright cyan, every other non-space character dim.

use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::OnceLock;

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::Widget;

use crate::theme;

/// Official art, verbatim (source of truth: the shipped `ombra` RING_ART).
pub const RING_ART: &str = r"                .==========:
           :*#@@@@@@@@@@@@@@@@#*:
         %%@@@@@@@@@@@@@@@@@@@@@@@%
      .%@@@@@@%%-          -%%@@=   ..
    .#@@@@@%=.                   :%@@@*.
   -%@@@@%-                   :-=%@@@@@#:
  -@@@@@*                  .+     :@@@@@@-
 :@@@@@.                 %          @@@@@@:
.@@@@@+              .+:            .#@@@@@.
.@@@@@:            =-                :@@@@@.
%@@@@*.         + :                   -@@@@@
@@@@@=       =-.                      -@@@@@
%@@@@@:   :+                          -@@@@@
.@@@@@=--=                           :@@@@@.
.@@@@*=.                             +@@@@@.
 :#:. +:                            .@@@@@:
   :#@@@@                          @@@@@@-
   -%@@@@%-                      :%@@@@%-
    -#@@#=                    :*@@@@@@#-
      :   .#@@@#**        +*#@@@@@@@%:
         -@@@@@@@@@@@@@@@@@@@@@@@@%.
            -%@@@@@@@@@@@@@@@@%-
                 -********=";

/// (width, height) of the art in cells.
pub fn ring_size() -> (u16, u16) {
    static SIZE: OnceLock<(u16, u16)> = OnceLock::new();
    *SIZE.get_or_init(|| {
        let mut w = 0u16;
        let mut rows = 0u16;
        for line in RING_ART.lines() {
            rows += 1;
            w = w.max(line.chars().count() as u16);
        }
        (w, rows)
    })
}

/// Below this console-row count, the half-scale ring renders instead.
pub const COMPACT_BELOW: u16 = 40;

static PIXEL_MODE: AtomicBool = AtomicBool::new(false);
static LOGO_RECT: [AtomicU16; 4] = [AtomicU16::new(0), AtomicU16::new(0), AtomicU16::new(0), AtomicU16::new(0)];
/// Rows the emblem occupies when the framebuffer face is in charge.
pub const PIXEL_RING_ROWS: u16 = 10;

pub fn set_pixel_mode(on: bool) {
    PIXEL_MODE.store(on, Ordering::Relaxed);
}

/// Where the pixel face last asked for the emblem, in cells.
pub fn logo_rect() -> Option<Rect> {
    let r: Vec<u16> = LOGO_RECT.iter().map(|v| v.load(Ordering::Relaxed)).collect();
    (r[2] > 0 && r[3] > 0).then(|| Rect::new(r[0], r[1], r[2], r[3]))
}

pub fn ring_height_for(console_height: u16) -> u16 {
    if PIXEL_MODE.load(Ordering::Relaxed) {
        return PIXEL_RING_ROWS;
    }
    let (_, rows) = ring_size();
    if console_height < COMPACT_BELOW {
        (rows + 1) / 2
    } else {
        rows
    }
}

pub fn ring_rows(console_height: u16) -> Vec<String> {
    let rows: Vec<Vec<char>> = RING_ART.lines().map(|l| l.chars().collect()).collect();
    if console_height >= COMPACT_BELOW {
        return rows.into_iter().map(|r| r.into_iter().collect()).collect();
    }
    let width = rows.iter().map(Vec::len).max().unwrap_or(0);
    rows.chunks(2)
        .map(|pair| {
            (0..width.div_ceil(2))
                .map(|bx| {
                    let block = pair
                        .iter()
                        .flat_map(|r| (0..2).filter_map(move |dx| r.get(bx * 2 + dx).copied()))
                        .filter(|c| *c != ' ');
                    let cells: Vec<char> = block.collect();
                    if cells.contains(&'@') {
                        '@'
                    } else {
                        cells.first().copied().unwrap_or(' ')
                    }
                })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

pub fn render_for(area: Rect, buf: &mut Buffer, console_height: u16) {
    let area = area.intersection(buf.area);
    if area.is_empty() {
        return;
    }
    let (full_w, _h) = ring_size();
    let w = if console_height < COMPACT_BELOW { full_w.div_ceil(2) } else { full_w };
    let x0 = area.x + area.width.saturating_sub(w) / 2;
    for (ry, line) in ring_rows(console_height).iter().enumerate() {
        let y = area.y + ry as u16;
        if y >= area.bottom() {
            break;
        }
        for (rx, ch) in line.chars().enumerate() {
            let x = x0 + rx as u16;
            if x >= area.right() {
                break;
            }
            if ch == ' ' {
                continue;
            }
            let cell = &mut buf[(x, y)];
            cell.set_char(ch);
            cell.set_fg(if ch == '@' {
                theme::RING_BRIGHT
            } else {
                theme::RING_DIM
            });
        }
    }
}

pub fn render(area: Rect, buf: &mut Buffer) {
    render_for(area, buf, u16::MAX);
}

pub struct Ring {
    console_height: u16,
}

impl Ring {
    pub fn for_console(console_height: u16) -> Self {
        Ring { console_height }
    }
}

impl Widget for Ring {
    fn render(self, area: Rect, buf: &mut Buffer) {
        if PIXEL_MODE.load(Ordering::Relaxed) {
            for (slot, v) in LOGO_RECT.iter().zip([area.x, area.y, area.width, area.height]) {
                slot.store(v, Ordering::Relaxed);
            }
            return;
        }
        render_for(area, buf, self.console_height);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Color;

    #[test]
    fn ring_dimensions_match_official_art() {
        assert_eq!(ring_size(), (44, 23));
    }

    #[test]
    fn compact_ring_is_a_half_scale_in_both_axes() {
        assert_eq!(ring_height_for(COMPACT_BELOW - 1), 12);
        assert_eq!(ring_height_for(COMPACT_BELOW), 23);
        assert_eq!(ring_height_for(u16::MAX), 23);

        let compact = ring_rows(COMPACT_BELOW - 1);
        assert_eq!(compact.len(), 12);
        let width = compact.iter().map(|l| l.chars().count()).max().unwrap();
        assert!(width <= 22, "{width}");
        assert!(compact.iter().all(|l| !l.contains('\t')));
        let (ink_top, ink_bottom) = (
            compact[1].matches('@').count(),
            compact[compact.len() - 2].matches('@').count(),
        );
        assert!(ink_top > 0 && ink_bottom > 0);
        assert_eq!(ring_rows(COMPACT_BELOW).len(), 23);
    }

    #[test]
    fn compact_ring_renders_two_tone_centered_on_an_eighty_by_twenty_five_console() {
        let area = Rect::new(0, 0, 80, 25);
        let mut buf = Buffer::empty(area);
        render_for(area, &mut buf, 25);
        let x0 = (80 - 22) / 2;
        let bright = (0..80u16)
            .flat_map(|x| (0..12u16).map(move |y| (x, y)))
            .filter(|(x, y)| buf[(*x, *y)].symbol() == "@" && buf[(*x, *y)].fg == theme::RING_BRIGHT)
            .collect::<Vec<_>>();
        assert!(!bright.is_empty());
        assert!(bright.iter().all(|(x, _)| *x >= x0 && *x < x0 + 22));
        assert_eq!(buf[(0, 20)].symbol(), " ");
    }

    #[test]
    fn two_tone_cells_at_key_coordinates() {
        let area = Rect::new(0, 0, 60, 30);
        let mut buf = Buffer::empty(area);
        render(area, &mut buf);

        let lead = &buf[(8, 0)];
        assert_eq!(lead.symbol(), " ");
        assert_eq!(lead.fg, Color::Reset);
        assert_eq!(buf[(8 + 16, 0)].symbol(), ".");
        assert_eq!(buf[(8 + 16, 0)].fg, theme::RING_DIM);
        assert_eq!(buf[(8 + 17, 0)].symbol(), "=");
        assert_eq!(buf[(8 + 17, 0)].fg, theme::RING_DIM);

        assert_eq!(buf[(8 + 11, 1)].symbol(), ":");
        assert_eq!(buf[(8 + 11, 1)].fg, theme::RING_DIM);
        assert_eq!(buf[(8 + 14, 1)].symbol(), "@");
        assert_eq!(buf[(8 + 14, 1)].fg, theme::RING_BRIGHT);

        assert_eq!(buf[(8 + 17, 22)].symbol(), "-");
        assert_eq!(buf[(8 + 17, 22)].fg, theme::RING_DIM);
        assert_eq!(buf[(8 + 18, 22)].symbol(), "*");
    }

    #[test]
    fn centers_in_odd_widths_and_clips() {
        let area = Rect::new(0, 0, 51, 23);
        let mut buf = Buffer::empty(area);
        render(area, &mut buf);
        assert_eq!(buf[(3 + 16, 0)].symbol(), ".");

        // must not panic
        let narrow = Rect::new(0, 0, 20, 23);
        let mut nb = Buffer::empty(narrow);
        render(narrow, &mut nb);
        let clip = Rect::new(0, 0, 60, 10);
        let mut cb = Buffer::empty(clip);
        render(clip, &mut cb);
        assert_eq!(cb[(8 + 1, 9)].symbol(), "@");
        assert_eq!(cb[(8 + 1, 9)].fg, theme::RING_BRIGHT);
    }
}
