//! A design kept in step with a folder of HTML and CSS: a project's
//! `src/components`, say.
//!
//! ```text
//! <folder>/theme.css            the palette, as the design has it
//! <folder>/<component>.css      a component's rules (html::component_css)
//! <folder>/<component>.html     an instance of it at its defaults
//! <folder>/pages/<page>.css     a page's own rules and media queries
//! <folder>/pages/<page>.html    the page, linking the rest
//! <folder>/images/…             its pictures
//! ```
//!
//! Out is the HTML writer's: [`files`] on every save. Back in is an edit
//! made in an editor, read as one step ([`read`]):
//!
//! - **CSS:** each rule is found by its selector — `.button__label`,
//!   `.button--variant-secondary .button__label`, `.button:hover…`, a page's
//!   `.hero`, and a page's `@media (max-width: …)` as its breakpoint — and
//!   its declarations are read back into the layer's fields: colours, fonts,
//!   radius, opacity, fit, and a frame's direction, gap, padding, wrap,
//!   align and justify. How a layer sits in its frame (`flex`, `width`,
//!   `align-self`) is the inspector's to say and is left alone; anything else
//!   is said, not guessed at. A rule taken out of the file leaves its layer
//!   as it was.
//! - **HTML:** the words of text layers, read with Proton's own markup
//!   parser; on a page, an instance's words for its component's text.
//!
//! The files are Aether's: the next save writes them as Aether writes them,
//! so what comes back is what they mean, not how they were spaced.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::{json, Value};

use crate::format::{Component, Kind, Layer, Override, Page, STATE};
use crate::{html, react, Design, Target};

/// What the head of each CSS file says.
const CSS_MARK: &str = "/* Written by Aether from a design. Its colours, fonts, radius, opacity and\n   layout come back to the design when this file is saved; how a layer sits\n   in its frame is the design's to say. */\n";
/// What the head of each HTML file says.
const HTML_MARK: &str = "<!-- Written by Aether from a design. The words of its text come back to\n     the design when this file is saved. -->\n";

/// One file of the folder: where it goes in it, and its text.
pub struct File {
    pub rel: String,
    pub text: String,
}

/// Whether the folder is written as React rather than HTML.
fn react(design: &Design) -> bool {
    design.design.get().sync_as == "react"
}

/// The folder's files as the design is now: HTML and CSS, or React's
/// `.tsx` and the same CSS.
pub fn files(design: &Design) -> Vec<File> {
    let components = design.component_map();
    let mut out = vec![File { rel: "theme.css".into(), text: design.theme.text().to_string() }];
    if react(design) {
        for c in components.values() {
            out.push(File { rel: format!("{}.css", c.id), text: format!("{CSS_MARK}{}", html::component_css(c)) });
            out.push(File { rel: format!("{}.tsx", react::pascal(&c.id)), text: react::component(c, &components) });
        }
        for page in &design.pages {
            let p = page.get();
            out.push(File { rel: format!("pages/{}.css", p.id), text: format!("{CSS_MARK}{}", html::page_css(p, &components, &p.root)) });
            out.push(File { rel: format!("pages/{}.tsx", react::pascal(&p.id)), text: react::page(p, &components) });
        }
        return out;
    }
    for c in components.values() {
        out.push(File { rel: format!("{}.css", c.id), text: format!("{CSS_MARK}{}", html::component_css(c)) });
        out.push(File { rel: format!("{}.html", c.id), text: format!("{HTML_MARK}{}", html::component_markup(c, &components, "")) });
    }
    for page in &design.pages {
        let p = page.get();
        out.push(File { rel: format!("pages/{}.css", p.id), text: format!("{CSS_MARK}{}", html::page_css(p, &components, &p.root)) });
        let document = html::linked_document(p, &components, "../", "../");
        // After the doctype, which has to come first.
        let text = match document.split_once('\n') {
            Some((doctype, rest)) => format!("{doctype}\n{HTML_MARK}{rest}"),
            None => document,
        };
        out.push(File { rel: format!("pages/{}.html", p.id), text });
    }
    out
}

/// What reading a file back did.
#[derive(Debug, Default)]
pub struct Read {
    /// The document it changed: `component:<id>` or `page:<id>`.
    pub target: String,
    pub changed: bool,
    /// What was in it that the design couldn't take, in words.
    pub notes: Vec<String>,
}

/// The ops that bring the document `rel` names (a file of the folder) to
/// what `text` says, and what couldn't be read.
pub fn read(design: &Design, rel: &str, text: &str) -> Result<(Target, Vec<proton_game::Op>, Vec<String>), String> {
    let (folder, name) = rel.rsplit_once('/').unwrap_or(("", rel));
    let (stem, kind) = name.rsplit_once('.').ok_or_else(|| format!("{rel} is neither HTML nor CSS"))?;
    let mut notes = Vec::new();
    if kind == "tsx" {
        if !react(design) {
            return Err(format!("{rel}: the folder is written as HTML"));
        }
        let components = design.component_map();
        let (target, ops) = match folder {
            "" => {
                let c = components.values().find(|c| react::pascal(&c.id) == stem).ok_or_else(|| format!("{rel}: there's no component {stem}"))?;
                (Target::Component(c.id.clone()), react::read(react::Of::Component(c), &components, text, &mut notes))
            }
            "pages" => {
                let p = design.pages.iter().map(|p| p.get()).find(|p| react::pascal(&p.id) == stem).ok_or_else(|| format!("{rel}: there's no page {stem}"))?;
                (Target::Page(p.id.clone()), react::read(react::Of::Page(p), &components, text, &mut notes))
            }
            _ => return Err(format!("{rel} isn't one of the files a design writes")),
        };
        let notes = notes.into_iter().map(|n| format!("{rel}: {n}")).collect();
        return Ok((target, ops, notes));
    }
    if kind == "html" && react(design) {
        return Err(format!("{rel}: the folder is written as React"));
    }
    let ops = match (folder, kind) {
        ("", "css") if stem != "theme" => {
            let c = design.component(stem).ok_or_else(|| format!("{rel}: there's no component {stem}"))?.get();
            component_css_ops(c, text, &mut notes)
        }
        ("", "html") => {
            let c = design.component(stem).ok_or_else(|| format!("{rel}: there's no component {stem}"))?.get();
            component_html_ops(c, text, &mut notes)
        }
        ("pages", "css") => {
            let p = design.page(stem).ok_or_else(|| format!("{rel}: there's no page {stem}"))?.get();
            page_css_ops(p, &design.component_map(), text, &mut notes)
        }
        ("pages", "html") => {
            let p = design.page(stem).ok_or_else(|| format!("{rel}: there's no page {stem}"))?.get();
            page_html_ops(p, &design.component_map(), text, &mut notes)
        }
        _ => return Err(format!("{rel} isn't one of the files a design writes")),
    };
    let target = match folder {
        "pages" => Target::Page(stem.to_string()),
        _ => Target::Component(stem.to_string()),
    };
    let notes = notes.into_iter().map(|n| format!("{rel}: {n}")).collect();
    Ok((target, ops, notes))
}

/// Write the folder's files into `folder`, and the design's pictures with
/// them; the files written, which are those whose text changed.
pub fn write(design: &Design, folder: &Path) -> Result<Vec<String>, String> {
    let mut written = Vec::new();
    for file in files(design) {
        let path = folder.join(&file.rel);
        if std::fs::read_to_string(&path).ok().as_deref() == Some(file.text.as_str()) {
            continue;
        }
        proton_game::doc::write_atomically(&path, file.text.as_bytes()).map_err(|e| format!("{}: {e}", file.rel))?;
        written.push(file.rel);
    }
    let images = design.root().join("images");
    if let Ok(entries) = std::fs::read_dir(&images) {
        for entry in entries.flatten() {
            let to = folder.join("images").join(entry.file_name());
            let bytes = std::fs::read(entry.path()).map_err(|e| e.to_string())?;
            if std::fs::read(&to).ok().as_deref() != Some(bytes.as_slice()) {
                proton_game::doc::write_atomically(&to, &bytes).map_err(|e| e.to_string())?;
                written.push(format!("images/{}", entry.file_name().to_string_lossy()));
            }
        }
    }
    Ok(written)
}

/* ── CSS, read ────────────────────────────────────────────────────── */

/// A rule of a stylesheet: the `max-width` of the media query it's in, its
/// selector, and its declarations in order.
#[derive(Debug, Clone, PartialEq)]
pub struct Rule {
    pub media: Option<f64>,
    pub selector: String,
    pub decls: Vec<(String, String)>,
}

/// The rules of a stylesheet: plain ones and those inside a `max-width`
/// media query; comments skipped, and `;` and braces inside strings and
/// parentheses read as text.
pub fn rules(text: &str) -> Vec<Rule> {
    let text = strip_comments(text);
    let mut out = Vec::new();
    let mut rest = text.as_str();
    while let Some(open) = find_outside(rest, '{') {
        let prelude = rest[..open].trim();
        let Some(close) = matching(rest, open) else { break };
        let body = &rest[open + 1..close];
        if let Some(query) = prelude.strip_prefix("@media") {
            let width = query.split("max-width:").nth(1).and_then(|w| w.trim().trim_end_matches(')').trim().trim_end_matches("px").trim().parse().ok());
            for mut inner in rules(body) {
                inner.media = width;
                out.push(inner);
            }
        } else if !prelude.starts_with('@') {
            out.push(Rule { media: None, selector: prelude.split_whitespace().collect::<Vec<_>>().join(" "), decls: declarations(body) });
        }
        rest = &rest[close + 1..];
    }
    out
}

fn strip_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        rest = rest[start + 2..].find("*/").map(|end| &rest[start + 2 + end + 2..]).unwrap_or("");
    }
    out.push_str(rest);
    out
}

/// Where `c` first is outside strings and parentheses.
fn find_outside(text: &str, c: char) -> Option<usize> {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    for (i, ch) in text.char_indices() {
        match (quote, ch) {
            (Some(q), _) if ch == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(ch),
            (None, '(') => depth += 1,
            (None, ')') => depth -= 1,
            (None, _) if ch == c && depth == 0 => return Some(i),
            _ => {}
        }
    }
    None
}

/// The brace that closes the one at `open`.
fn matching(text: &str, open: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    for (i, ch) in text[open..].char_indices() {
        match (quote, ch) {
            (Some(q), _) if ch == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(ch),
            (None, '{') => depth += 1,
            (None, '}') => {
                depth -= 1;
                if depth == 0 {
                    return Some(open + i);
                }
            }
            _ => {}
        }
    }
    None
}

fn declarations(body: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = body;
    loop {
        let end = find_outside(rest, ';').unwrap_or(rest.len());
        if let Some((property, value)) = rest[..end].split_once(':') {
            let (property, value) = (property.trim().to_ascii_lowercase(), value.trim().trim_end_matches("!important").trim());
            if !property.is_empty() && !value.is_empty() {
                out.push((property, value.to_string()));
            }
        }
        if end >= rest.len() {
            break;
        }
        rest = &rest[end + 1..];
    }
    out
}

/// The fields a CSS declaration says, by their path in a layer (`style`,
/// `fill`), as the format writes them; `Err` with the property when it's
/// none a layer says. Empty for what's the inspector's to say: how a layer
/// sits in its frame.
fn fields(property: &str, value: &str) -> Result<Vec<([&'static str; 2], Value)>, ()> {
    let length = |v: &str| match v.trim() {
        "0" => json!(0),
        v if v.starts_with("var(") => json!(token(v)),
        v => v.strip_suffix("px").and_then(|n| n.trim().parse::<f64>().ok()).map(|n| json!(n)).unwrap_or_else(|| json!(v)),
    };
    let word = |v: &str| json!(token(v));
    Ok(match property {
        "background" | "background-color" => vec![(["style", "fill"], word(value))],
        "border" => {
            let colour = value.split_once("solid").map(|(_, c)| c.trim()).unwrap_or(value);
            vec![(["style", "stroke"], word(colour))]
        }
        "border-radius" => vec![(["style", "radius"], length(value))],
        "color" => vec![(["style", "color"], word(value))],
        "font" => vec![(["style", "font"], word(value))],
        "text-align" => vec![(["style", "textAlign"], json!(value))],
        "opacity" => vec![(["style", "opacity"], value.parse::<f64>().map(|n| json!(n)).map_err(|_| ())?)],
        "object-fit" => vec![(["style", "fit"], json!(value))],
        "gap" => vec![(["layout", "gap"], length(value))],
        "padding" => {
            let parts: Vec<&str> = value.split_whitespace().collect();
            let (v, h) = match parts.as_slice() {
                [all] => (*all, *all),
                [v, h, ..] => (*v, *h),
                [] => return Err(()),
            };
            vec![(["layout", "padV"], length(v)), (["layout", "padH"], length(h))]
        }
        "flex-direction" => vec![(["layout", "direction"], json!(value))],
        "flex-wrap" => vec![(["layout", "wrap"], json!(value == "wrap"))],
        "align-items" => vec![(["layout", "align"], json!(flex_word(value)))],
        "justify-content" => vec![(["layout", "justify"], json!(flex_word(value)))],
        // How it sits in its frame, and what every element has.
        "display" | "flex" | "width" | "height" | "min-width" | "min-height" | "max-width" | "align-self" | "box-sizing" | "margin" => vec![],
        _ => return Err(()),
    })
}

/// `var(--x)` as the token `--x`; anything else as written.
fn token(value: &str) -> String {
    let v = value.trim();
    match v.strip_prefix("var(").and_then(|r| r.strip_suffix(')')) {
        Some(inner) if !inner.contains(',') => inner.trim().to_string(),
        _ => v.to_string(),
    }
}

fn flex_word(value: &str) -> &str {
    match value {
        "flex-end" => "end",
        "space-between" => "between",
        "center" => "center",
        _ => "start",
    }
}

/// Every field sync reads, by path.
const FIELDS: [[&str; 2]; 15] = [
    ["style", "fill"],
    ["style", "stroke"],
    ["style", "radius"],
    ["style", "color"],
    ["style", "font"],
    ["style", "textAlign"],
    ["style", "opacity"],
    ["style", "fit"],
    ["layout", "direction"],
    ["layout", "gap"],
    ["layout", "padH"],
    ["layout", "padV"],
    ["layout", "align"],
    ["layout", "justify"],
    ["layout", "wrap"],
];

/// What a rule says of a layer's fields, and whether it hides it; notes for
/// what it says that a layer doesn't.
fn said(rule: &Rule, notes: &mut Vec<String>) -> (BTreeMap<[&'static str; 2], Value>, Option<bool>) {
    let mut out = BTreeMap::new();
    let mut hidden = None;
    for (property, value) in &rule.decls {
        if property == "display" {
            hidden = Some(value == "none");
        }
        if value == "revert" {
            continue;
        }
        match fields(property, value) {
            Ok(found) => out.extend(found),
            Err(()) => notes.push(format!("{} says {property}: {value}, which isn't something a layer says; left as it is", rule.selector)),
        }
    }
    (out, hidden)
}

/// A field as it means the same whether said or not: a column, start,
/// no wrap, cover and no padding are what's unsaid.
fn plain(key: [&str; 2], value: Option<Value>) -> Option<Value> {
    let unsaid = match (key[1], &value) {
        ("direction", Some(v)) => v == "column",
        ("align" | "justify", Some(v)) => v == "start",
        ("wrap", Some(v)) => v == false,
        ("fit", Some(v)) => v == "cover",
        ("padH" | "padV", Some(v)) => v.as_f64() == Some(0.0),
        _ => false,
    };
    if unsaid { None } else { value.filter(|v| !v.is_null()) }
}

/// A layer's field as the format has it.
fn field_of(layer: &Value, key: [&str; 2]) -> Option<Value> {
    layer.get(key[0]).and_then(|o| o.get(key[1])).cloned().filter(|v| !v.is_null())
}

fn values_equal(a: &Option<Value>, b: &Option<Value>) -> bool {
    match (a, b) {
        (Some(x), Some(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(p), Some(q)) => (p - q).abs() < 1e-9,
            _ => x == y,
        },
        (None, None) => true,
        _ => false,
    }
}

/// Ops setting `layer`'s own fields to what `rule` says.
fn own_ops(path: &[String], layer: &Layer, rule: &Rule, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let (said, hidden) = said(rule, notes);
    let mut ops = Vec::new();
    let current = serde_json::to_value(layer).unwrap_or(Value::Null);
    let hide = hidden == Some(true);
    if hide != layer.hidden {
        ops.push(set(path, &["hidden"], json!(hide)));
    }
    // Hidden, a rule says nothing else: its fields stand.
    if hide {
        return ops;
    }
    for key in FIELDS {
        let want = plain(key, said.get(&key).cloned());
        let have = plain(key, field_of(&current, key));
        if !values_equal(&want, &have) {
            ops.push(set(path, &key, want.unwrap_or(Value::Null)));
        }
    }
    ops
}

/// Ops setting what `layer` says under `field` (`at` or `when`) `key` to
/// what `rule` says: only what differs from `wider`, the layer as the level
/// above has it — a shorthand like `padding` says both halves, and the
/// half it shares with `wider` isn't the override's.
fn override_ops(path: &[String], layer: &Layer, wider: &Layer, field: &str, key: &str, rule: &Rule, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let (mut said, hidden) = said(rule, notes);
    let existing = match field {
        "at" => layer.at.get(key),
        _ => layer.when.get(key),
    };
    let above = serde_json::to_value(wider).unwrap_or(Value::Null);
    let before = existing.map(|o| serde_json::to_value(o).unwrap_or(Value::Null)).unwrap_or(Value::Null);
    said.retain(|k, v| !values_equal(&Some(v.clone()), &field_of(&above, *k)) || field_of(&before, *k).is_some());
    let mut want = Override { hidden, ..Override::default() };
    let mut value = serde_json::to_value(&want).unwrap_or(Value::Null);
    for (k, v) in &said {
        value[k[0]][k[1]] = v.clone();
    }
    want = serde_json::from_value(value.clone()).unwrap_or_default();
    let mut at = path.to_vec();
    at.extend([field.to_string(), key.to_string()]);
    let Some(existing) = existing else {
        return vec![proton_game::Op::Set { path: at, value }];
    };
    // Sizes are the inspector's to say: kept as they are.
    want.w = existing.w.clone();
    want.h = existing.h.clone();
    want.min_w = existing.min_w;
    if &want == existing {
        return vec![];
    }
    vec![proton_game::Op::Set { path: at, value: serde_json::to_value(&want).unwrap_or(Value::Null) }]
}

fn set(path: &[String], keys: &[&str], value: Value) -> proton_game::Op {
    let mut at = path.to_vec();
    at.extend(keys.iter().map(|k| k.to_string()));
    proton_game::Op::Set { path: at, value }
}

fn layer_path(id: &str) -> Vec<String> {
    vec!["layers".into(), format!("#{id}")]
}

/// A component's selector read as the layer it's for, and the option or
/// state it says what changes for, if any.
fn component_selector(c: &Component, selector: &str) -> Option<(String, Option<String>)> {
    let class = |id: &str| match id == c.root {
        true => format!(".{}", c.id),
        false => format!(".{}__{id}", c.id),
    };
    let disabled = format!("{}--{STATE}-disabled", c.id);
    let mut heads: Vec<(String, Option<String>)> = vec![(format!(".{}", c.id), None)];
    for prop in &c.props {
        for option in &prop.options {
            heads.push((format!(".{}--{}-{option}", c.id, prop.name), Some(format!("{}={option}", prop.name))));
        }
    }
    for state in &c.states {
        let head = match state.as_str() {
            "hover" => format!(".{}:hover:not(.{disabled})", c.id),
            "focus" => format!(".{}:focus-visible", c.id),
            "pressed" => format!(".{}:active:not(.{disabled})", c.id),
            _ => format!(".{disabled}"),
        };
        heads.push((head, Some(format!("{STATE}={state}"))));
    }
    for layer in &c.layers {
        let own = class(&layer.id);
        for (head, key) in &heads {
            let whole = match (layer.id == c.root, key) {
                (true, None) => own.clone(),
                (true, Some(_)) => head.clone(),
                (false, None) => own.clone(),
                (false, Some(_)) => format!("{head} {own}"),
            };
            if whole == selector {
                return Some((layer.id.clone(), key.clone()));
            }
        }
    }
    None
}

fn component_css_ops(c: &Component, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    for rule in rules(text) {
        let Some((id, key)) = component_selector(c, &rule.selector) else {
            notes.push(format!("{} isn't one of {}'s rules; left as it is", rule.selector, c.id));
            continue;
        };
        let Some(layer) = c.layer(&id) else { continue };
        let path = layer_path(&id);
        match key {
            None => ops.extend(own_ops(&path, layer, &rule, notes)),
            Some(key) => ops.extend(override_ops(&path, layer, layer, "when", &key, &rule, notes)),
        }
    }
    ops
}

fn page_css_ops(page: &Page, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let points = page.widest_first();
    let mut ops = Vec::new();
    for rule in rules(text) {
        let id = rule.selector.strip_prefix('.').unwrap_or("");
        // A component's rule inside a page's media query says what its layers
        // say at that breakpoint: the component's, not read back here.
        if id.contains("__") || components.contains_key(id) {
            continue;
        }
        let Some(layer) = page.layer(id).filter(|_| !id.is_empty() && !id.contains([' ', ':', '.'])) else {
            notes.push(format!("{} isn't one of {}'s layers; left as it is", rule.selector, page.name));
            continue;
        };
        // An instance's rule says only where it sits; its look is its
        // component's file.
        if layer.kind == Kind::Instance && components.contains_key(&layer.component) {
            continue;
        }
        let path = layer_path(id);
        match rule.media {
            None => ops.extend(own_ops(&path, layer, &rule, notes)),
            Some(width) => {
                // The breakpoint below the one this query is a pixel under.
                let here = points.windows(2).find(|pair| (pair[0].width - 1.0 - width).abs() < 0.5).map(|pair| (pair[0].id.clone(), pair[1].id.clone()));
                match here {
                    Some((above, point)) => {
                        let wider = page.at(&above).layer(id).cloned().unwrap_or_else(|| layer.clone());
                        ops.extend(override_ops(&path, layer, &wider, "at", &point, &rule, notes));
                    }
                    None => notes.push(format!("@media (max-width: {width}px) isn't one of {}'s breakpoints; left as it is", page.name)),
                }
            }
        }
    }
    ops
}

/* ── HTML, read ───────────────────────────────────────────────────── */

/// An element's words, as the HTML writer writes them: `<br>` a new line,
/// and the four characters it escapes. `None` when it holds markup.
fn words(inner: &str) -> Option<String> {
    let text = inner.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n");
    if text.contains('<') {
        return None;
    }
    Some(text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&amp;", "&"))
}

fn component_html_ops(c: &Component, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    for element in proton_design::layers(text) {
        for class in &element.classes {
            let Some(id) = class.strip_prefix(&format!("{}__", c.id)) else { continue };
            let Some(layer) = c.layer(id).filter(|l| l.kind == Kind::Text) else { continue };
            match element.inner(text).and_then(words) {
                Some(w) if w != layer.text => ops.push(set(&layer_path(id), &["text"], json!(w))),
                Some(_) => {}
                None => notes.push(format!("{} holds markup, not words; left as it is", layer.label())),
            }
        }
    }
    ops
}

fn page_html_ops(page: &Page, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    // The instance each element is inside, by depth.
    let mut inside: Vec<(usize, String)> = Vec::new();
    for element in proton_design::layers(text) {
        inside.retain(|(depth, _)| *depth < element.depth);
        let Some(first) = element.classes.first() else { continue };
        if let Some(layer) = page.layer(first) {
            if layer.kind == Kind::Instance {
                inside.push((element.depth, layer.id.clone()));
                continue;
            }
            if layer.kind == Kind::Text {
                match element.inner(text).and_then(words) {
                    Some(w) if w != layer.text => ops.push(set(&layer_path(&layer.id), &["text"], json!(w))),
                    Some(_) => {}
                    None => notes.push(format!("{} holds markup, not words; left as it is", layer.label())),
                }
            }
            continue;
        }
        // A component's layer, inside the instance it's drawn for.
        let Some((_, owner)) = inside.last() else { continue };
        let Some(instance) = page.layer(owner) else { continue };
        let Some(c) = components.get(&instance.component) else { continue };
        let Some(id) = first.strip_prefix(&format!("{}__", c.id)) else { continue };
        let Some(own) = c.layer(id).filter(|l| l.kind == Kind::Text) else { continue };
        let Some(w) = element.inner(text).and_then(words) else {
            notes.push(format!("{}'s {} holds markup, not words; left as it is", instance.label(), own.label()));
            continue;
        };
        let given = instance.texts.get(id);
        let path = layer_path(owner);
        if w == own.text {
            // The component's own words: the instance says none.
            if given.is_some() {
                ops.push(proton_game::Op::Remove { path: [path, vec!["texts".into(), id.to_string()]].concat() });
            }
        } else if given != Some(&w) {
            ops.push(set(&path, &["texts", id], json!(w)));
        }
    }
    ops
}

impl Design {
    /// The folder the design is kept in step with, if it has one: as
    /// `design.json` says it, from the design's folder.
    pub fn sync_folder(&self) -> Option<std::path::PathBuf> {
        let said = self.design.get().sync.trim();
        (!said.is_empty()).then(|| self.root().join(said))
    }

    /// Write the folder's files; those written.
    pub fn sync_out(&self) -> Result<Vec<String>, String> {
        let Some(folder) = self.sync_folder() else { return Ok(Vec::new()) };
        write(self, &folder)
    }

    /// File `rel` of the folder, as `text`, read back into the design as one
    /// step of the document it's for.
    pub fn sync_in(&mut self, rel: &str, text: &str) -> Result<Read, String> {
        let (target, ops, notes) = read(self, rel, text)?;
        let name = match &target {
            Target::Page(id) => format!("page:{id}"),
            Target::Component(id) => format!("component:{id}"),
            _ => String::new(),
        };
        let changed = !ops.is_empty() && self.apply(&target, &ops)?;
        Ok(Read { target: name, changed, notes })
    }
}
