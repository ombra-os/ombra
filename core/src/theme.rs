//! Palette, spacing and the shared vertical layout for both boot TUIs; the background is never painted.

use ratatui::layout::{Alignment, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;

use crate::art;

// 256-color values ONLY: boot consoles do not reliably do truecolor.
pub const RING_BRIGHT: Color = Color::Indexed(189);
pub const RING_DIM: Color = Color::Indexed(103);
pub const TEXT: Color = Color::Indexed(255);
pub const LABEL: Color = Color::Indexed(245);
pub const MUTED: Color = Color::Indexed(241);
pub const GOOD: Color = Color::Indexed(78);
pub const BAD: Color = Color::Indexed(210);
pub const FIELD_FRAME: Color = Color::Indexed(105);
pub const ACCENT: Color = FIELD_FRAME;
pub const RULE: Color = Color::Indexed(60);
pub const AMBER: Color = Color::Indexed(221);
pub const KEYCAP_BG: Color = Color::Indexed(236);

/// Terminal default; we never paint a background.
pub const BG: Color = Color::Reset;

// ---- layout rules
pub const BRAND: &str = "O M B R A";
pub const FIELD_WIDTH: u16 = 46;
pub const RING_TOP_PCT: u16 = 25;
pub const KEY_POLL_MS: u64 = 530;
pub const PULSE_MS: u64 = 220;
pub const CARET_BLINK_MS: u64 = 530;

pub fn fg(c: Color) -> Style {
    Style::new().fg(c)
}

// boot consoles render glyphs via the loaded console font, not UTF-8; [`boot_glyphs`] is the coverage contract

/// The passphrase mask: one per typed character.
pub const MASK: char = '\u{00b7}';
/// The idle caret, painted only while the field is empty.
pub const CARET: char = '\u{2588}';
pub const DOT: char = '\u{25cf}';
pub const ELLIPSIS: char = '\u{2026}';
pub const HAIRLINE: char = '\u{2500}';
pub const SEP: char = '\u{00b7}';

/// Every glyph the boot TUIs can draw — derived from ratatui, never hand-copied.
pub fn boot_glyphs() -> Vec<char> {
    let b = ratatui::widgets::BorderType::border_symbols(ratatui::widgets::BorderType::Rounded);
    let mut set: Vec<char> = vec![MASK, CARET, DOT, ELLIPSIS, HAIRLINE];
    for s in [
        b.top_left,
        b.top_right,
        b.bottom_left,
        b.bottom_right,
        b.vertical_left,
        b.vertical_right,
        b.horizontal_top,
        b.horizontal_bottom,
    ] {
        set.extend(s.chars());
    }
    set.sort_unstable();
    set.dedup();
    set
}

pub fn brand_style() -> Style {
    Style::new().fg(TEXT).add_modifier(Modifier::BOLD)
}

#[derive(Clone, Copy, Debug)]
pub struct ScreenLayout {
    pub ring: Rect,
    pub brand: Rect,
    pub title: Rect,
    pub content: Rect,
    pub footer: Rect,
}

pub fn line_rect(base: Rect, x: u16, y: u16) -> Rect {
    let w = base.right().saturating_sub(x);
    Rect {
        x,
        y,
        width: w,
        height: 1,
    }
    .intersection(base)
}

pub fn put_left(f: &mut Frame, r: Rect, text: &str, style: Style) {
    let r = r.intersection(f.area());
    if r.height == 0 || r.width == 0 {
        return;
    }
    let p = Paragraph::new(Line::styled(text.to_string(), style));
    f.render_widget(p, r);
}

pub fn layout(area: Rect) -> ScreenLayout {
    // footer lifted above the bottom edge; every band clamps above it
    let bottom = area.bottom();
    let footer_lift = if area.height >= 30 { 3 } else { 1 };
    let footer_y = bottom.saturating_sub(1 + footer_lift).max(area.y + 4);
    let clamp_above = |r: Rect| -> Rect {
        if r.y >= footer_y {
            Rect {
                x: r.x,
                y: footer_y,
                width: r.width,
                height: 0,
            }
        } else {
            Rect {
                height: r.height.min(footer_y - r.y),
                ..r
            }
        }
    };
    let ring_h = art::ring_height_for(area.height).min(area.height);
    const CONTENT_MIN: u16 = 9; // title + box + confirm box + info line
    let stack = ring_h + 4 + CONTENT_MIN + 1 + footer_lift;
    let top = area.y + (area.height * RING_TOP_PCT / 100).min(area.height.saturating_sub(stack));
    let ring = clamp_above(Rect {
        x: area.x,
        y: top,
        width: area.width,
        height: ring_h,
    });
    let brand = clamp_above(Rect {
        x: area.x,
        y: top + ring_h,
        width: area.width,
        height: 1,
    });
    let title = clamp_above(Rect {
        x: area.x,
        y: brand.y.saturating_add(2),
        width: area.width,
        height: 1,
    });
    let content_y = title.y.saturating_add(2);
    let content_h = bottom.saturating_sub(content_y + 1); // keep 1 footer row
    let content = clamp_above(Rect {
        x: area.x,
        y: content_y,
        width: area.width,
        height: content_h,
    });
    let footer = Rect {
        x: area.x,
        y: footer_y,
        width: area.width,
        height: 1,
    };
    ScreenLayout {
        ring,
        brand,
        title,
        content,
        footer,
    }
}

/// Fits `text` into `max` cells, ending in an ellipsis when it had to cut.
pub fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    if max == 0 {
        return String::new();
    }
    let mut out: String = text.chars().take(max - 1).collect();
    while out.ends_with(' ') {
        out.pop();
    }
    out.push(ELLIPSIS);
    out
}

pub fn hairline(n: usize) -> String {
    HAIRLINE.to_string().repeat(n)
}

/// Terms in label gray joined by indigo middle dots.
pub fn dotted_line(terms: &[&str]) -> Line<'static> {
    let mut spans = Vec::new();
    for (i, t) in terms.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(format!(" {SEP} "), fg(ACCENT)));
        }
        spans.push(Span::styled(t.to_string(), fg(LABEL)));
    }
    Line::from(spans)
}

/// Keycap hints: key in off-white on a dim cap, action in muted gray.
pub fn hint_line(hints: &[(&str, &str)]) -> Line<'static> {
    let mut spans = Vec::new();
    for (i, (key, action)) in hints.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(format!("  {SEP}  "), fg(ACCENT)));
        }
        spans.push(Span::styled(
            format!(" {key} "),
            Style::new().fg(TEXT).bg(KEYCAP_BG),
        ));
        spans.push(Span::styled(format!(" {action}"), fg(MUTED)));
    }
    Line::from(spans)
}

/// `──── O M B R A ────` at exactly `w` cells; None when the row cannot hold it.
pub fn wordmark_line(w: u16) -> Option<Line<'static>> {
    let mark = BRAND.chars().count() + 2;
    let w = w as usize;
    if w < mark + 4 {
        return None;
    }
    let left = (w - mark) / 2;
    let right = w - mark - left;
    Some(Line::from(vec![
        Span::styled(hairline(left), fg(RULE)),
        Span::styled(format!(" {BRAND} "), brand_style()),
        Span::styled(hairline(right), fg(RULE)),
    ]))
}

/// The wordmark between hairlines `w` wide, centered; plain centered brand when it does not fit.
pub fn put_wordmark(f: &mut Frame, row: Rect, w: u16) {
    match wordmark_line(w.min(row.width)) {
        Some(line) if row.width >= w => {
            let r = center_horiz(row, w, 1);
            let r = r.intersection(f.area());
            if r.width > 0 && r.height > 0 {
                f.render_widget(Paragraph::new(line), r);
            }
        }
        _ => put_centered(f, row, BRAND, brand_style()),
    }
}

pub fn put_line(f: &mut Frame, r: Rect, line: Line<'static>) {
    let r = r.intersection(f.area());
    if r.height == 0 || r.width == 0 {
        return;
    }
    f.render_widget(Paragraph::new(line), r);
}

pub fn put_line_centered(f: &mut Frame, r: Rect, line: Line<'static>) {
    let r = r.intersection(f.area());
    if r.height == 0 || r.width == 0 {
        return;
    }
    f.render_widget(Paragraph::new(line.alignment(Alignment::Center)), r);
}

pub fn put_hints(f: &mut Frame, r: Rect, hints: &[(&str, &str)]) {
    put_line_centered(f, r, hint_line(hints));
}

/// `● text` with the dot in `color` and the text in `text_style`.
pub fn status_line(color: Color, text: &str, text_style: Style) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("{DOT} "), fg(color)),
        Span::styled(text.to_string(), text_style),
    ])
}

/// A centered column of left-aligned lines.
pub fn put_block(f: &mut Frame, area: Rect, lines: &[(&str, Style)]) {
    let w = lines
        .iter()
        .filter(|(t, _)| !t.is_empty())
        .map(|(t, _)| t.chars().count())
        .max()
        .unwrap_or(0) as u16;
    if w == 0 || w > area.width || area.height == 0 {
        return;
    }
    let x = area.x + (area.width - w) / 2;
    for (i, (text, style)) in lines.iter().enumerate() {
        if i as u16 >= area.height {
            break;
        }
        if text.is_empty() {
            continue; // spacing row
        }
        let row = Rect {
            x,
            y: area.y + i as u16,
            width: w,
            height: 1,
        };
        let p = Paragraph::new(Line::styled(*text, *style));
        f.render_widget(p, row);
    }
}

pub fn put_centered(f: &mut Frame, r: Rect, text: &str, style: Style) {
    let r = r.intersection(f.area());
    if r.height == 0 || r.width == 0 {
        return;
    }
    let p = Paragraph::new(Line::styled(text.to_string(), style)).alignment(Alignment::Center);
    f.render_widget(p, r);
}

pub fn center_horiz(outer: Rect, w: u16, h: u16) -> Rect {
    Rect {
        x: outer.x + outer.width.saturating_sub(w) / 2,
        y: outer.y,
        width: w.min(outer.width),
        height: h.min(outer.height),
    }
}

/// 1-row slice of a band; zero-height when it would leave the band.
pub fn row_in(r: Rect, offset: u16) -> Rect {
    if offset >= r.height {
        return Rect {
            x: r.x,
            y: r.y,
            width: r.width,
            height: 0,
        };
    }
    Rect {
        x: r.x,
        y: r.y + offset,
        width: r.width,
        height: 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composition_a_ring_top_center_text_stacked_beneath() {
        let area = Rect::new(0, 0, 128, 48);
        let l = layout(area);
        assert_eq!(
            l.ring.y + l.ring.height,
            31,
            "ring band above the text stack"
        );
        assert_eq!(l.brand.y, l.ring.bottom(), "brand directly under the ring");
        assert!(l.title.y > l.brand.y, "title below the brand");
        assert_eq!(
            l.title.width, area.width,
            "centered chrome spans the console"
        );
        assert_eq!(l.title.x, area.x, "title is not beside a left ring column");
        let small = layout(Rect::new(0, 0, 90, 30));
        assert!(small.title.y > small.brand.y);
    }

    #[test]
    fn ring_top_sits_at_about_twenty_five_percent() {
        let area = Rect::new(0, 0, 160, 50);
        let l = layout(area);
        assert_eq!(l.ring.y, 10);
        assert_eq!(l.ring.height, 23);
        assert_eq!(l.brand.y, 33);
        assert_eq!(l.content.height, 9);
        assert_eq!(l.footer.y, 46);
    }

    #[test]
    fn tiny_screens_do_not_panic() {
        let l = layout(Rect::new(0, 0, 20, 6));
        assert_eq!(l.ring.y, 0);
        assert_eq!(l.ring.height, 4);
        assert_eq!(l.brand.height, 0);
        assert_eq!(l.title.height, 0);
        assert_eq!(l.content.height, 0);
        assert_eq!(
            l.footer,
            ratatui::layout::Rect {
                x: 0,
                y: 4,
                width: 20,
                height: 1
            }
        );
    }

    #[test]
    fn short_consoles_get_the_compact_ring_and_full_stack() {
        let l = layout(Rect::new(0, 0, 100, 30));
        assert_eq!(l.ring.y, 1);
        assert_eq!(l.ring.height, 12);
        assert_eq!(l.brand.y, 13);
        assert_eq!(l.title.y, 15);
        assert_eq!(l.title.height, 1);
        assert_eq!(l.content.y, 17);
        assert_eq!(l.content.height, 9);
        assert_eq!(l.footer.y, 26);
    }

    #[test]
    fn the_boot_console_is_eighty_by_twenty_five() {
        let l = layout(Rect::new(0, 0, 80, 25));
        assert_eq!(l.ring.y, 0);
        assert_eq!(l.ring.height, 12);
        assert_eq!(l.brand.y, 12);
        assert_eq!(l.title.y, 14);
        assert_eq!(l.title.height, 1);
        assert_eq!(l.content.y, 16);
        assert_eq!(l.content.height, 7);
        assert_eq!(l.footer.y, 23);
        assert_eq!(l.footer.height, 1);
    }

    #[test]
    fn palette_is_fixed_ansi_256_indexed_never_truecolor() {
        for c in [
            RING_BRIGHT,
            RING_DIM,
            TEXT,
            LABEL,
            MUTED,
            GOOD,
            BAD,
            FIELD_FRAME,
            RULE,
            AMBER,
            KEYCAP_BG,
        ] {
            assert!(
                matches!(c, Color::Indexed(_)),
                "palette color {c:?} is not a 256-color (Indexed) value"
            );
        }
    }

    #[test]
    fn center_horiz_centers() {
        let outer = Rect::new(0, 3, 80, 10);
        let r = center_horiz(outer, FIELD_WIDTH, 3);
        assert_eq!(r.x, 17);
        assert_eq!(r.y, 3);
        assert_eq!(r.width, 46);
    }

    #[test]
    fn boot_glyph_set_is_the_mask_caret_dot_ellipsis_and_rounded_frame() {
        let glyphs = boot_glyphs();
        for c in [
            '\u{256d}', '\u{256e}', '\u{256f}', '\u{2570}', '\u{2500}', '\u{2502}',
        ] {
            assert!(glyphs.contains(&c), "boot glyphs missing the frame's {c:?}");
        }
        assert!(glyphs.contains(&MASK));
        assert!(glyphs.contains(&CARET));
        assert!(glyphs.contains(&DOT) && glyphs.contains(&ELLIPSIS));
        assert_eq!(glyphs.len(), 10, "boot glyph set grew: {glyphs:?}");
    }

    #[test]
    fn truncate_cuts_with_an_ellipsis_and_never_exceeds_the_width() {
        assert_eq!(truncate("short", 10), "short");
        assert_eq!(truncate("exactly ten", 11), "exactly ten");
        let t = truncate("a long error that cannot fit", 12);
        assert_eq!(t.chars().count(), 12);
        assert!(t.ends_with(ELLIPSIS));
        assert_eq!(truncate("trail ing", 6), format!("trail{ELLIPSIS}"));
        assert_eq!(truncate("anything", 0), "");
        assert_eq!(truncate("anything", 1), ELLIPSIS.to_string());
    }

    #[test]
    fn wordmark_spans_exactly_its_width_with_the_mark_centered() {
        let line = wordmark_line(FIELD_WIDTH).expect("fits");
        let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text.chars().count(), FIELD_WIDTH as usize);
        assert!(text.contains(" O M B R A "));
        assert!(text.starts_with(HAIRLINE) && text.ends_with(HAIRLINE));
        assert_eq!(line.spans[0].style.fg, Some(RULE));
        assert_eq!(line.spans[1].style.fg, Some(TEXT));
        assert!(wordmark_line(12).is_none());
    }

    #[test]
    fn hints_render_keycaps_and_muted_actions() {
        let line = hint_line(&[("enter", "continue"), ("esc", "back")]);
        let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, format!(" enter  continue  {SEP}   esc  back"));
        assert_eq!(line.spans[0].style.bg, Some(KEYCAP_BG));
        assert_eq!(line.spans[0].style.fg, Some(TEXT));
        assert_eq!(line.spans[1].style.fg, Some(MUTED));
        assert_eq!(line.spans[2].style.fg, Some(ACCENT));
    }

    #[test]
    fn dotted_line_colors_terms_and_dots_separately() {
        let line = dotted_line(&["LUKS2", "AES-256-XTS", "argon2id"]);
        let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "LUKS2 \u{b7} AES-256-XTS \u{b7} argon2id");
        assert_eq!(line.spans[0].style.fg, Some(LABEL));
        assert_eq!(line.spans[1].style.fg, Some(ACCENT));
    }
}
