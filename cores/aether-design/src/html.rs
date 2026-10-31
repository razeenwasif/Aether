//! A page as HTML and CSS: the code the design is, shown rather than hidden.
//!
//! Each layer is one element whose class is its id, and one CSS rule; the
//! rule says in flexbox what the layer says in the inspector, and every token
//! is a `var()` of the theme's custom property, so the page written out is
//! styled by the same `theme.css` the design is. A frame is a flex box, and
//! how a child is sized depends on its frame's direction: `fill` along a row
//! grows (`flex: 1 1 <narrowest>`), `fill` down a column stretches across it.
//! The workspace's own layout (`DesignLayout` in Swift) follows the same
//! rules, so the artboard and a browser agree.
//!
//! The widest breakpoint is the page's own rules; each narrower one is a
//! `max-width` media query holding only what changes there — a rule a layer
//! no longer has there is `revert`ed — so the cascade is the page's.

use std::fmt::Write as _;

use crate::format::{Kind, Layer, Page, Val};

/// The whole page as a document, its tokens from the stylesheet at
/// `theme_href` and its pictures' `images/` under `base`.
pub fn document(page: &Page, theme_href: &str, base: &str) -> String {
    let mut out = String::new();
    out.push_str("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    let _ = writeln!(out, "<title>{}</title>", escape(&page.name));
    let _ = writeln!(out, "<link rel=\"stylesheet\" href=\"{}\">", escape(theme_href));
    out.push_str("<style>\n* { box-sizing: border-box; margin: 0; }\nbody { margin: 0; }\n");
    out.push_str(&css(page, &page.root));
    out.push_str("</style>\n</head>\n<body>\n");
    out.push_str(&markup(page, &page.root, base));
    out.push_str("</body>\n</html>\n");
    out
}

/// The elements of `id` and everything in it, indented, pictures under
/// `base`.
pub fn markup(page: &Page, id: &str, base: &str) -> String {
    let mut out = String::new();
    element(page, id, 0, base, &mut Vec::new(), &mut out);
    out
}

/// The rules for `id` and everything in it: the page's own, then what
/// each narrower breakpoint changes.
pub fn css(page: &Page, id: &str) -> String {
    let mut out = String::new();
    for layer in page.subtree(id) {
        block(&mut out, "", &layer.id, &rules(page, layer));
    }
    let points = page.widest_first();
    for pair in points.windows(2) {
        let (wider, here) = (pair[0], pair[1]);
        let before = page.at(&wider.id);
        let now = page.at(&here.id);
        let mut inner = String::new();
        for layer in now.subtree(id) {
            let had = before.layer(&layer.id).map(|l| rules(&before, l)).unwrap_or_default();
            let has = rules(&now, layer);
            let mut changed: Vec<(&'static str, String)> = has.iter().filter(|r| !had.contains(r)).cloned().collect();
            // Hidden, nothing else it had matters there.
            let hidden = layer.hidden;
            for (property, _) in had.iter().filter(|_| !hidden) {
                if !has.iter().any(|(p, _)| p == property) {
                    changed.push((property, "revert".into()));
                }
            }
            block(&mut inner, "  ", &layer.id, &changed);
        }
        if !inner.is_empty() {
            // Below the wider breakpoint's width: what a narrower screen
            // than it gets.
            let _ = writeln!(out, "/* {} */\n@media (max-width: {}) {{", here.name, px((wider.width - 1.0).max(0.0)));
            out.push_str(&inner);
            out.push_str("}\n");
        }
    }
    out
}

fn block(out: &mut String, indent: &str, id: &str, rules: &[(&'static str, String)]) {
    if rules.is_empty() {
        return;
    }
    let _ = writeln!(out, "{indent}.{id} {{");
    for (property, value) in rules {
        let _ = writeln!(out, "{indent}  {property}: {value};");
    }
    let _ = writeln!(out, "{indent}}}");
}

fn element(page: &Page, id: &str, depth: usize, base: &str, path: &mut Vec<String>, out: &mut String) {
    let Some(layer) = page.layer(id) else { return };
    if path.iter().any(|seen| seen == id) {
        return;
    }
    let indent = "  ".repeat(depth);
    let tag = tag(layer);
    match layer.kind {
        Kind::Text => {
            let words = layer.text.lines().map(escape).collect::<Vec<_>>().join("<br>");
            let _ = writeln!(out, "{indent}<{tag} class=\"{}\">{words}</{tag}>", layer.id);
        }
        Kind::Image => {
            // Its text is what it shows, for whoever can't see it.
            let _ = writeln!(out, "{indent}<img class=\"{}\" src=\"{}{}\" alt=\"{}\">", layer.id, escape(base), escape(&layer.src), escape(&layer.text));
        }
        _ if layer.children.is_empty() => {
            let _ = writeln!(out, "{indent}<{tag} class=\"{}\"></{tag}>", layer.id);
        }
        _ => {
            let _ = writeln!(out, "{indent}<{tag} class=\"{}\">", layer.id);
            path.push(id.to_string());
            for child in &layer.children {
                element(page, child, depth + 1, base, path, out);
            }
            path.pop();
            let _ = writeln!(out, "{indent}</{tag}>");
        }
    }
}

fn tag(layer: &Layer) -> &str {
    match (layer.tag.is_empty(), layer.kind) {
        (false, _) => &layer.tag,
        (true, Kind::Text) => "p",
        (_, Kind::Image) => "img",
        (true, _) => "div",
    }
}

/// The size a layer is, said or not.
pub fn width(layer: &Layer) -> Val {
    layer.w.clone().unwrap_or_else(|| match layer.kind {
        Kind::Text => Val::Text("hug".into()),
        _ => Val::Text("fill".into()),
    })
}

pub fn height(layer: &Layer) -> Val {
    layer.h.clone().unwrap_or_else(|| match layer.kind {
        Kind::Rect => Val::Num(100.0),
        _ => Val::Text("hug".into()),
    })
}

fn rules(page: &Page, layer: &Layer) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    let lay = &layer.layout;
    if layer.hidden {
        return vec![("display", "none".to_string())];
    }
    if layer.kind == Kind::Image {
        out.push(("display", "block".to_string()));
        out.push(("object-fit", layer.style.fit.clone().unwrap_or_else(|| "cover".into())));
    }
    if layer.kind == Kind::Frame {
        out.push(("display", "flex".to_string()));
        let row = lay.direction.as_deref() == Some("row");
        out.push(("flex-direction", if row { "row" } else { "column" }.to_string()));
        if lay.wrap == Some(true) && row {
            out.push(("flex-wrap", "wrap".to_string()));
        }
        if let Some(gap) = &lay.gap {
            out.push(("gap", length(gap)));
        }
        if lay.pad_v.is_some() || lay.pad_h.is_some() {
            let v = lay.pad_v.as_ref().map(length).unwrap_or_else(|| "0".into());
            let h = lay.pad_h.as_ref().map(length).unwrap_or_else(|| "0".into());
            out.push(("padding", format!("{v} {h}")));
        }
        out.push(("align-items", flex_word(lay.align.as_deref().unwrap_or("start")).to_string()));
        if let Some(justify) = lay.justify.as_deref().filter(|j| *j != "start") {
            out.push(("justify-content", flex_word(justify).to_string()));
        }
    }

    // Sized by its frame's direction, or as the page's root.
    match page.parent(&layer.id) {
        None => {
            out.push(("width", "100%".to_string()));
            out.push(("min-height", "100vh".to_string()));
        }
        Some(frame) => {
            let row = frame.layout.direction.as_deref() == Some("row");
            let (along, across) = match row {
                true => (width(layer), height(layer)),
                false => (height(layer), width(layer)),
            };
            let (along_name, across_name) = if row { ("width", "height") } else { ("height", "width") };
            match along {
                Val::Text(w) if w == "fill" => {
                    let basis = match (row, layer.min_w) {
                        (true, Some(n)) => px(n),
                        _ => "0".to_string(),
                    };
                    out.push(("flex", format!("1 1 {basis}")));
                    out.push((if row { "min-width" } else { "min-height" }, "0".to_string()));
                }
                Val::Num(n) => {
                    out.push((along_name, px(n)));
                    out.push(("flex", "0 0 auto".to_string()));
                }
                _ => out.push(("flex", "0 0 auto".to_string())),
            }
            match across {
                Val::Text(w) if w == "fill" => out.push(("align-self", "stretch".to_string())),
                Val::Num(n) => out.push((across_name, px(n))),
                _ => {}
            }
            if !row {
                // A column never lets a child spill out of its side.
                out.push(("max-width", "100%".to_string()));
            }
        }
    }

    let style = &layer.style;
    if let Some(fill) = &style.fill {
        out.push(("background", value(fill)));
    }
    if let Some(stroke) = &style.stroke {
        out.push(("border", format!("1px solid {}", value(stroke))));
    }
    if let Some(radius) = &style.radius {
        out.push(("border-radius", length(radius)));
    }
    if let Some(color) = &style.color {
        out.push(("color", value(color)));
    }
    if let Some(font) = &style.font {
        out.push(("font", value(font)));
    }
    if let Some(align) = &style.text_align {
        out.push(("text-align", align.clone()));
    }
    if let Some(opacity) = style.opacity {
        out.push(("opacity", trim(opacity)));
    }
    out
}

fn flex_word(word: &str) -> &str {
    match word {
        "center" => "center",
        "end" => "flex-end",
        "between" => "space-between",
        _ => "flex-start",
    }
}

/// A token as its `var()`, anything else as written.
fn value(text: &str) -> String {
    match text.starts_with("--") {
        true => format!("var({text})"),
        false => text.to_string(),
    }
}

fn length(val: &Val) -> String {
    match val {
        Val::Num(n) => px(*n),
        Val::Text(text) => value(text),
    }
}

fn px(n: f64) -> String {
    match n == 0.0 {
        true => "0".into(),
        false => format!("{}px", trim(n)),
    }
}

fn trim(n: f64) -> String {
    let text = format!("{n:.3}");
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
