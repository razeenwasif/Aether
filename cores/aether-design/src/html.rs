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
//! A component's CSS is written once, as classes its instances share (see
//! [`component_css`]); an instance's own class says only where it sits.
//!
//! The widest breakpoint is the page's own rules; each narrower one is a
//! `max-width` media query holding only what changes there — a rule a layer
//! no longer has there is `revert`ed — so the cascade is the page's.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::format::{expand, Component, Kind, Layer, Page, Val};

/// The whole page as a document, its instances expanded, its tokens from
/// the stylesheet at `theme_href` and its pictures' `images/` under `base`.
pub fn document(page: &Page, components: &BTreeMap<String, Component>, theme_href: &str, base: &str) -> String {
    let mut out = String::new();
    out.push_str("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    let _ = writeln!(out, "<title>{}</title>", escape(&page.name));
    let _ = writeln!(out, "<link rel=\"stylesheet\" href=\"{}\">", escape(theme_href));
    out.push_str("<style>\n* { box-sizing: border-box; margin: 0; }\nbody { margin: 0; }\n");
    out.push_str(&css(page, components, &page.root));
    out.push_str("</style>\n</head>\n<body>\n");
    out.push_str(&markup(page, components, &page.root, base));
    out.push_str("</body>\n</html>\n");
    out
}

/// The elements of `id` and everything in it, instances expanded,
/// indented, pictures under `base`.
pub fn markup(page: &Page, components: &BTreeMap<String, Component>, id: &str, base: &str) -> String {
    let page = expand(page, components);
    let mut out = String::new();
    element(&page, id, 0, base, &mut Vec::new(), &mut out);
    out
}

/// The rules for `id` and everything in it: each component it places, once;
/// the page's own; then what each narrower breakpoint changes.
pub fn css(page: &Page, components: &BTreeMap<String, Component>, id: &str) -> String {
    let page = expand(page, components);
    let mut out = String::new();
    let mut used: Vec<&str> = Vec::new();
    for layer in page.subtree(id) {
        if !layer.component.is_empty() && !used.contains(&layer.component.as_str()) {
            used.push(&layer.component);
        }
    }
    for c in used.iter().filter_map(|c| components.get(*c)) {
        out.push_str(&component_css(c));
    }
    for layer in page.subtree(id) {
        block(&mut out, "", &layer.id, &page_rules(&page, layer));
    }
    let points = page.widest_first();
    for pair in points.windows(2) {
        let (wider, here) = (pair[0], pair[1]);
        let before = page.at(&wider.id);
        let now = page.at(&here.id);
        let mut inner = String::new();
        for layer in now.subtree(id) {
            let had = before.layer(&layer.id).map(|l| page_rules(&before, l)).unwrap_or_default();
            block(&mut inner, "  ", &layer.id, &changes(&had, &page_rules(&now, layer), layer.hidden));
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

/// A component's rules, as classes every instance shares: `.button` for its
/// root's box and look, `.button__label` for each layer inside, and for each
/// option of each prop, `.button--variant-secondary` and
/// `.button--variant-secondary .button__label` holding only what it
/// changes. Where an instance sits and how big it is are its page's, on the
/// instance's own class.
pub fn component_css(c: &Component) -> String {
    let base = c.as_page(c.with(&[]));
    let class = |id: &str| match id == c.root {
        true => c.id.clone(),
        false => format!("{}__{id}", c.id),
    };
    let part = |page: &Page, layer: &Layer| match layer.id == c.root {
        true => rules_of(page, layer, Part::Own),
        false => rules(page, layer),
    };
    let mut out = String::new();
    for layer in base.subtree(&base.root) {
        block(&mut out, "", &class(&layer.id), &part(&base, layer));
    }
    for prop in &c.props {
        for option in &prop.options {
            let now = c.as_page(c.with(&[(prop.name.clone(), option.clone())]));
            let modifier = format!("{}--{}-{option}", c.id, prop.name);
            for layer in now.subtree(&now.root) {
                let had = base.layer(&layer.id).map(|l| part(&base, l)).unwrap_or_default();
                let selector = match layer.id == c.root {
                    true => modifier.clone(),
                    false => format!("{modifier} .{}", class(&layer.id)),
                };
                block(&mut out, "", &selector, &changes(&had, &part(&now, layer), layer.hidden));
            }
        }
    }
    out
}

/// A component's elements as an instance of it at its defaults is written.
pub fn component_markup(c: &Component, base: &str) -> String {
    let instance = Layer { id: c.id.clone(), kind: Kind::Instance, component: c.id.clone(), ..Layer::default() };
    let page = Page { root: c.id.clone(), layers: vec![instance], ..Page::default() };
    markup(&page, &BTreeMap::from([(c.id.clone(), c.clone())]), &c.id, base)
}

/// A page's rules for a layer: its own, or for a component's root only how
/// it sits in its frame; the component's layers inside are the
/// component's CSS.
fn page_rules(page: &Page, layer: &Layer) -> Rules {
    match (layer.component.is_empty(), layer.id.contains('.')) {
        (true, _) => rules(page, layer),
        (false, false) => rules_of(page, layer, Part::Sizing),
        (false, true) => Vec::new(),
    }
}

/// What `has` says that `had` didn't, and `revert` for what it no longer
/// says — unless it's hidden, when nothing else it had matters.
fn changes(had: &Rules, has: &Rules, hidden: bool) -> Rules {
    let mut out: Rules = has.iter().filter(|r| !had.contains(r)).cloned().collect();
    for (property, _) in had.iter().filter(|_| !hidden) {
        if !has.iter().any(|(p, _)| p == property) {
            out.push((property, "revert".into()));
        }
    }
    out
}

fn block(out: &mut String, indent: &str, selector: &str, rules: &[(&'static str, String)]) {
    if rules.is_empty() {
        return;
    }
    let _ = writeln!(out, "{indent}.{selector} {{");
    for (property, value) in rules {
        let _ = writeln!(out, "{indent}  {property}: {value};");
    }
    let _ = writeln!(out, "{indent}}}");
}

/// A layer's classes: its id, or for a component's layers the component's
/// classes — its root's, with a modifier for each option it takes.
fn classes(layer: &Layer) -> String {
    let c = &layer.component;
    if c.is_empty() {
        return layer.id.clone();
    }
    match layer.id.split_once('.') {
        Some((_, inner)) => format!("{c}__{inner}"),
        None => {
            let modifiers: String = layer.props.iter().map(|(p, o)| format!(" {c}--{p}-{o}")).collect();
            format!("{} {c}{modifiers}", layer.id)
        }
    }
}

fn element(page: &Page, id: &str, depth: usize, base: &str, path: &mut Vec<String>, out: &mut String) {
    let Some(layer) = page.layer(id) else { return };
    if path.iter().any(|seen| seen == id) {
        return;
    }
    let indent = "  ".repeat(depth);
    let tag = tag(layer);
    let class = classes(layer);
    match layer.kind {
        Kind::Text => {
            let words = layer.text.lines().map(escape).collect::<Vec<_>>().join("<br>");
            let _ = writeln!(out, "{indent}<{tag} class=\"{class}\">{words}</{tag}>");
        }
        Kind::Image => {
            // Its text is what it shows, for whoever can't see it.
            let _ = writeln!(out, "{indent}<img class=\"{class}\" src=\"{}{}\" alt=\"{}\">", escape(base), escape(&layer.src), escape(&layer.text));
        }
        Kind::Instance => {
            // Still an instance once expanded: its component isn't there.
            let _ = writeln!(out, "{indent}<!-- {}: no component {} -->", layer.id, escape(&layer.component));
        }
        _ if layer.children.is_empty() => {
            let _ = writeln!(out, "{indent}<{tag} class=\"{class}\"></{tag}>");
        }
        _ => {
            let _ = writeln!(out, "{indent}<{tag} class=\"{class}\">");
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

/// Which of a layer's rules: what it is (its box, its children's layout,
/// its look), or how it sits in its frame.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Part {
    All,
    Own,
    Sizing,
}

type Rules = Vec<(&'static str, String)>;

fn rules(page: &Page, layer: &Layer) -> Rules {
    rules_of(page, layer, Part::All)
}

fn rules_of(page: &Page, layer: &Layer, part: Part) -> Rules {
    let mut out = Vec::new();
    let mut size = Vec::new();
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
            size.push(("width", "100%".to_string()));
            size.push(("min-height", "100vh".to_string()));
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
                    size.push(("flex", format!("1 1 {basis}")));
                    size.push((if row { "min-width" } else { "min-height" }, "0".to_string()));
                }
                Val::Num(n) => {
                    size.push((along_name, px(n)));
                    size.push(("flex", "0 0 auto".to_string()));
                }
                _ => size.push(("flex", "0 0 auto".to_string())),
            }
            match across {
                Val::Text(w) if w == "fill" => size.push(("align-self", "stretch".to_string())),
                Val::Num(n) => size.push((across_name, px(n))),
                _ => {}
            }
            if !row {
                // A column never lets a child spill out of its side.
                size.push(("max-width", "100%".to_string()));
            }
        }
    }

    // Where its place goes, between its box and its look.
    let split = out.len();
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
    match part {
        Part::All => {
            out.splice(split..split, size);
            out
        }
        Part::Own => out,
        Part::Sizing => size,
    }
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
