//! A design as React styled by Tailwind: the React files of [`crate::react`],
//! their look in utility classes instead of CSS files.
//!
//! ```text
//! <folder>/theme.css            `@import "tailwindcss"` and the palette as `@theme static`
//! <folder>/<Name>.tsx           a component, its classes in `look` and `by<Prop>`
//! <folder>/pages/<Name>.tsx     a page, each element's classes on it
//! <folder>/pages/<id>.css       only what a page says of a component's layers at
//!                               a breakpoint, which a page's classes can't reach
//! ```
//!
//! The classes are worked out from the CSS the HTML writer writes, one
//! declaration at a time, so the two can't drift: a colour token is its
//! Tailwind colour (`--color-lantern-500` → `bg-lantern-500`), a radius
//! token its radius (`rounded-full`), any other token a variable
//! (`p-(--space-4)`), a value of its own in brackets (`gap-[8px]`), and what
//! has no utility an arbitrary property (`[font:var(--type-body)]`). A
//! narrower breakpoint is `max-[1279px]:`. A component's states are
//! `hover:`, `active:`, `focus-visible:` and `data-[state=disabled]:` on its
//! root, and the same through `group-…/button:` on the layers inside.
//!
//! A component's options can't add to its classes, as the HTML's modifiers
//! do, because two utilities for one property apply in Tailwind's order, not
//! the class list's. So each property an option changes leaves `look` for a
//! list per option, `byVariant.primary` and `byVariant.secondary`, one of
//! which is always applied.
//!
//! Back in, the classes are turned back into the CSS they came from and read
//! as the HTML sync reads CSS ([`crate::sync`]), with the React reader for
//! words and props. A class Aether doesn't write is a note.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

use crate::format::{Component, Page, STATE};
use crate::sync;
use crate::{html, react};

/// A component's classes: each layer's, and for each prop, each option's.
pub struct ComponentLook {
    pub base: Vec<(String, String)>,
    pub by: Vec<(String, Vec<(String, Vec<(String, String)>)>)>,
}

/// A page's classes, by layer, and the CSS its classes can't say.
pub struct PageLook {
    pub classes: BTreeMap<String, String>,
    pub css: String,
}

/// `theme.css` as Tailwind's entry: the import, and the palette's `:root`
/// as `@theme static`, so every token is a variable whether a class uses
/// it or not. A scheme's block stays as it is, and wins over the theme.
pub fn theme(text: &str) -> String {
    let mut depth = 0i32;
    let mut at = None;
    for (i, c) in text.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth -= 1,
            ':' if depth == 0 && text[i..].starts_with(":root") => {
                at = Some(i);
                break;
            }
            _ => {}
        }
    }
    let body = match at {
        Some(i) => format!("{}@theme static{}", &text[..i], &text[i + ":root".len()..]),
        None => text.to_string(),
    };
    format!("@import \"tailwindcss\";\n\n{body}")
}

/// The name of a prop's options' list: `byVariant`.
pub fn by(prop: &str) -> String {
    format!("by{}", react::pascal(prop))
}

/* ── CSS → classes ────────────────────────────────────────────────── */

/// What a declaration's value is to a class: a colour, a length, a radius.
#[derive(Clone, Copy)]
enum As {
    Colour,
    Length,
    Radius,
}

fn value(kind: As, v: &str) -> String {
    let v = v.trim();
    if let Some(name) = v.strip_prefix("var(").and_then(|r| r.strip_suffix(')')).filter(|n| !n.contains(',')) {
        let name = name.trim();
        return match kind {
            As::Colour => match name.strip_prefix("--color-") {
                Some(colour) => colour.to_string(),
                None => format!("(color:{name})"),
            },
            As::Radius => match name.strip_prefix("--radius-") {
                Some(radius) => radius.to_string(),
                None => format!("({name})"),
            },
            As::Length => format!("({name})"),
        };
    }
    match (kind, v) {
        (As::Colour, "transparent") => "transparent".into(),
        (As::Colour, "currentColor") => "current".into(),
        (As::Length, "0") => "0".into(),
        (As::Radius, "0") => "none".into(),
        (As::Colour, v) if !v.starts_with(['#']) && !v.contains('(') => format!("[color:{}]", bracket(v)),
        (_, v) => format!("[{}]", bracket(v)),
    }
}

/// A value inside brackets: spaces as underscores.
fn bracket(v: &str) -> String {
    v.replace(' ', "_")
}

/// The classes a declaration is.
fn classes(property: &str, v: &str) -> Vec<String> {
    let arbitrary = || vec![format!("[{property}:{}]", bracket(v))];
    if v == "revert" {
        return arbitrary();
    }
    let one = |s: &str| vec![s.to_string()];
    match (property, v) {
        ("display", "flex") => one("flex"),
        ("display", "none") => one("hidden"),
        ("display", "block") => one("block"),
        ("flex-direction", "row") => one("flex-row"),
        ("flex-direction", "column") => one("flex-col"),
        ("flex-wrap", "wrap") => one("flex-wrap"),
        ("align-items", "flex-start") => one("items-start"),
        ("align-items", "center") => one("items-center"),
        ("align-items", "flex-end") => one("items-end"),
        ("align-items", "stretch") => one("items-stretch"),
        ("justify-content", "flex-start") => one("justify-start"),
        ("justify-content", "center") => one("justify-center"),
        ("justify-content", "flex-end") => one("justify-end"),
        ("justify-content", "space-between") => one("justify-between"),
        ("gap", v) => vec![format!("gap-{}", value(As::Length, v))],
        ("padding", v) => {
            let parts: Vec<&str> = v.split_whitespace().collect();
            match parts.as_slice() {
                [all] => vec![format!("p-{}", value(As::Length, all))],
                [y, x] if y == x => vec![format!("p-{}", value(As::Length, y))],
                [y, x] => vec![format!("py-{}", value(As::Length, y)), format!("px-{}", value(As::Length, x))],
                _ => arbitrary(),
            }
        }
        ("background", v) => vec![format!("bg-{}", value(As::Colour, v))],
        ("border", v) => match v.strip_prefix("1px solid ") {
            Some(colour) => vec!["border".into(), format!("border-{}", value(As::Colour, colour))],
            None => arbitrary(),
        },
        ("border-radius", v) => vec![format!("rounded-{}", value(As::Radius, v))],
        ("color", v) => vec![format!("text-{}", value(As::Colour, v))],
        ("text-align", "left" | "center" | "right" | "justify" | "start" | "end") => vec![format!("text-{v}")],
        ("opacity", v) => vec![format!("opacity-[{v}]")],
        ("object-fit", "cover" | "contain" | "fill" | "none" | "scale-down") => vec![format!("object-{v}")],
        ("flex", "0 0 auto") => one("flex-none"),
        ("flex", "1 1 0") => one("flex-1"),
        ("min-width", "0") => one("min-w-0"),
        ("min-height", "0") => one("min-h-0"),
        ("max-width", "100%") => one("max-w-full"),
        ("width", "100%") => one("w-full"),
        ("min-height", "100vh") => one("min-h-screen"),
        ("align-self", "stretch") => one("self-stretch"),
        ("width", v) => vec![format!("w-[{}]", bracket(v))],
        ("height", v) => vec![format!("h-[{}]", bracket(v))],
        _ => arbitrary(),
    }
}

fn utilities(decls: &[(String, String)], variant: &str) -> Vec<String> {
    decls.iter().flat_map(|(p, v)| classes(p, v)).map(|c| format!("{variant}{c}")).collect()
}

/// A component's classes, worked out from its CSS.
pub fn component_look(c: &Component) -> ComponentLook {
    let ids: Vec<String> = c.as_page(c.layers.clone()).subtree(&c.root).iter().map(|l| l.id.clone()).collect();
    let mut base: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    let mut options: BTreeMap<(String, String), Vec<(String, String)>> = BTreeMap::new();
    let mut states: BTreeMap<(String, String), Vec<(String, String)>> = BTreeMap::new();
    for rule in sync::rules(&html::component_css(c)) {
        let Some((id, key)) = sync::component_selector(c, &rule.selector) else { continue };
        match key.as_deref().and_then(|k| k.split_once('=')) {
            None => base.entry(id).or_default().extend(rule.decls),
            Some((STATE, state)) => states.entry((id, state.to_string())).or_default().extend(rule.decls),
            Some((_, _)) => options.entry((id, key.unwrap_or_default())).or_default().extend(rule.decls),
        }
    }
    // What each prop changes leaves the base for each of its options' lists.
    let mut by: Vec<(String, Vec<(String, Vec<(String, String)>)>)> = Vec::new();
    for prop in &c.props {
        let mut lists: Vec<(String, Vec<(String, String)>)> = prop.options.iter().map(|o| (o.clone(), Vec::new())).collect();
        for id in &ids {
            let changed: BTreeSet<String> = prop
                .options
                .iter()
                .flat_map(|o| options.get(&(id.clone(), format!("{}={o}", prop.name))).cloned().unwrap_or_default())
                .map(|(p, _)| p)
                .collect();
            if changed.is_empty() {
                continue;
            }
            let had = base.get(id).cloned().unwrap_or_default();
            for (option, list) in lists.iter_mut() {
                let says = options.get(&(id.clone(), format!("{}={option}", prop.name))).cloned().unwrap_or_default();
                let mut decls: Vec<(String, String)> = Vec::new();
                for (p, v) in had.iter().filter(|(p, _)| changed.contains(p)) {
                    match says.iter().find(|(q, _)| q == p) {
                        Some((_, w)) if w == "revert" => {}
                        Some((_, w)) => decls.push((p.clone(), w.clone())),
                        None => decls.push((p.clone(), v.clone())),
                    }
                }
                for (p, w) in says.iter().filter(|(p, w)| w != "revert" && !had.iter().any(|(q, _)| q == p)) {
                    decls.push((p.clone(), w.clone()));
                }
                list.push((id.clone(), utilities(&decls, "").join(" ")));
            }
            base.entry(id.clone()).or_default().retain(|(p, _)| !changed.contains(p));
        }
        if lists.iter().any(|(_, list)| !list.is_empty()) {
            by.push((prop.name.clone(), lists));
        }
    }
    let base = ids
        .iter()
        .map(|id| {
            let root = *id == c.root;
            let mut all = if root { vec![format!("group/{}", c.id)] } else { Vec::new() };
            all.extend(utilities(&base.get(id).cloned().unwrap_or_default(), ""));
            for state in ["hover", "focus", "pressed", "disabled"] {
                let Some(decls) = states.get(&(id.clone(), state.to_string())) else { continue };
                let variant = match (state, root) {
                    ("hover", true) => "hover:".to_string(),
                    ("focus", true) => "focus-visible:".into(),
                    ("pressed", true) => "active:".into(),
                    (_, true) => format!("data-[{STATE}=disabled]:"),
                    ("hover", false) => format!("group-hover/{}:", c.id),
                    ("focus", false) => format!("group-focus-visible/{}:", c.id),
                    ("pressed", false) => format!("group-active/{}:", c.id),
                    (_, false) => format!("group-data-[{STATE}=disabled]/{}:", c.id),
                };
                all.extend(utilities(decls, &variant));
            }
            (id.clone(), all.join(" "))
        })
        .collect();
    ComponentLook { base, by }
}

/// A page's classes, worked out from its CSS: each layer's, with what a
/// narrower breakpoint changes as `max-[…px]:`; and the rules for a
/// component's layers, which stay CSS.
pub fn page_look(p: &Page, components: &BTreeMap<String, Component>) -> PageLook {
    let mut classes: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut css: BTreeMap<Option<u64>, String> = BTreeMap::new();
    for rule in sync::rules(&html::page_css(p, components, &p.root)) {
        let id = rule.selector.trim_start_matches('.');
        if p.layer(id).is_some() {
            let variant = rule.media.map(|w| format!("max-[{}px]:", trim(w))).unwrap_or_default();
            classes.entry(id.to_string()).or_default().extend(utilities(&rule.decls, &variant));
        } else {
            let block = css.entry(rule.media.map(|w| w as u64)).or_default();
            let _ = writeln!(block, "  .{id} {{");
            for (property, v) in &rule.decls {
                let _ = writeln!(block, "    {property}: {v};");
            }
            block.push_str("  }\n");
        }
    }
    let mut text = String::new();
    for (media, block) in &css {
        match media {
            Some(w) => {
                let _ = writeln!(text, "@media (max-width: {w}px) {{\n{block}}}");
            }
            None => text.push_str(block),
        }
    }
    let css = match text.is_empty() {
        true => String::new(),
        false => format!("{}/* What this page says of its components' layers at a breakpoint, which\n   its classes can't reach. */\n{text}", sync::CSS_MARK),
    };
    PageLook { classes: classes.into_iter().map(|(id, all)| (id, all.join(" "))).collect(), css }
}

fn trim(n: f64) -> String {
    let text = format!("{n:.3}");
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

/* ── classes → CSS ────────────────────────────────────────────────── */

/// A class's variants and itself: `max-[389px]:p-(--space-4)` is
/// `["max-[389px]"]` and `p-(--space-4)`. Colons inside brackets and
/// parentheses aren't variants'.
fn split(class: &str) -> (Vec<String>, String) {
    let mut parts = vec![String::new()];
    let mut depth = 0i32;
    for ch in class.chars() {
        match ch {
            '[' | '(' => depth += 1,
            ']' | ')' => depth -= 1,
            ':' if depth == 0 => {
                parts.push(String::new());
                continue;
            }
            _ => {}
        }
        parts.last_mut().unwrap().push(ch);
    }
    let last = parts.pop().unwrap_or_default();
    (parts, last)
}

fn unvalue(kind: As, v: &str) -> String {
    if let Some(inner) = v.strip_prefix('(').and_then(|r| r.strip_suffix(')')) {
        let name = inner.split_once(':').map(|(_, n)| n).unwrap_or(inner);
        return format!("var({name})");
    }
    if let Some(inner) = v.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
        let inner = inner.strip_prefix("color:").or_else(|| inner.strip_prefix("length:")).unwrap_or(inner);
        return inner.replace('_', " ");
    }
    match (kind, v) {
        (As::Colour, "transparent") => "transparent".into(),
        (As::Colour, "current") => "currentColor".into(),
        (As::Colour, name) => format!("var(--color-{name})"),
        (As::Radius, "none") => "0".into(),
        (As::Radius, name) => format!("var(--radius-{name})"),
        (As::Length, "0") => "0".into(),
        (As::Length, "px") => "1px".into(),
        (As::Length, n) => match n.parse::<f64>() {
            Ok(n) => format!("{}px", trim(n * 4.0)),
            Err(_) => n.to_string(),
        },
    }
}

/// What a class (without variants) says, as declarations; `None` for one
/// Aether doesn't write. Padding's halves come back separately.
fn declarations(class: &str) -> Option<Vec<(String, String)>> {
    let one = |p: &str, v: &str| Some(vec![(p.to_string(), v.to_string())]);
    if let Some(inner) = class.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
        let (p, v) = inner.split_once(':')?;
        return one(p, &v.replace('_', " "));
    }
    match class {
        "flex" => return one("display", "flex"),
        "hidden" => return one("display", "none"),
        "block" => return one("display", "block"),
        "flex-row" => return one("flex-direction", "row"),
        "flex-col" => return one("flex-direction", "column"),
        "flex-wrap" => return one("flex-wrap", "wrap"),
        "items-start" => return one("align-items", "flex-start"),
        "items-center" => return one("align-items", "center"),
        "items-end" => return one("align-items", "flex-end"),
        "items-stretch" => return one("align-items", "stretch"),
        "justify-start" => return one("justify-content", "flex-start"),
        "justify-center" => return one("justify-content", "center"),
        "justify-end" => return one("justify-content", "flex-end"),
        "justify-between" => return one("justify-content", "space-between"),
        "border" => return Some(vec![]),
        "flex-none" => return one("flex", "0 0 auto"),
        "flex-1" => return one("flex", "1 1 0"),
        "min-w-0" => return one("min-width", "0"),
        "min-h-0" => return one("min-height", "0"),
        "max-w-full" => return one("max-width", "100%"),
        "w-full" => return one("width", "100%"),
        "min-h-screen" => return one("min-height", "100vh"),
        "self-stretch" => return one("align-self", "stretch"),
        "text-left" | "text-center" | "text-right" | "text-justify" | "text-start" | "text-end" => return one("text-align", &class[5..]),
        "object-cover" | "object-contain" | "object-fill" | "object-none" | "object-scale-down" => return one("object-fit", &class[7..]),
        _ => {}
    }
    let (head, v) = [
        "gap-", "p-", "px-", "py-", "bg-", "border-", "rounded-", "text-", "opacity-", "w-", "h-", "flex-",
    ]
    .iter()
    .find_map(|h| class.strip_prefix(h).map(|v| (*h, v)))?;
    match head {
        "gap-" => one("gap", &unvalue(As::Length, v)),
        "p-" => one("padding", &unvalue(As::Length, v)),
        "px-" => one("padding-x", &unvalue(As::Length, v)),
        "py-" => one("padding-y", &unvalue(As::Length, v)),
        "bg-" => one("background", &unvalue(As::Colour, v)),
        "border-" => one("border", &format!("1px solid {}", unvalue(As::Colour, v))),
        "rounded-" => one("border-radius", &unvalue(As::Radius, v)),
        "text-" => one("color", &unvalue(As::Colour, v)),
        "opacity-" => match v.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
            Some(n) => one("opacity", n),
            None => one("opacity", &trim(v.parse::<f64>().ok()? / 100.0)),
        },
        "w-" => one("width", &unvalue(As::Length, v)),
        "h-" => one("height", &unvalue(As::Length, v)),
        "flex-" => one("flex", &v.strip_prefix('[')?.strip_suffix(']')?.replace('_', " ")),
        _ => None,
    }
}

/// Declarations from classes, padding's halves joined as `padding: y x`.
fn joined(found: Vec<(String, String)>) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let (mut y, mut x) = (None, None);
    for (p, v) in found {
        match p.as_str() {
            "padding-y" => y = Some(v),
            "padding-x" => x = Some(v),
            "padding" => {
                y = Some(v.clone());
                x = Some(v);
            }
            _ => match out.iter_mut().find(|(q, _)| *q == p) {
                Some(slot) => slot.1 = v,
                None => out.push((p, v)),
            },
        }
    }
    if y.is_some() || x.is_some() {
        out.push(("padding".into(), format!("{} {}", y.unwrap_or_else(|| "0".into()), x.unwrap_or_else(|| "0".into()))));
    }
    out
}

fn rule_text(selector: &str, decls: &[(String, String)], out: &mut String) {
    let _ = writeln!(out, "{selector} {{");
    for (p, v) in decls {
        let _ = writeln!(out, "  {p}: {v};");
    }
    out.push_str("}\n");
}

/// A page's `.tsx` read back: words and props as React's are, and each
/// element's classes as the CSS they came from.
pub fn read_page(p: &Page, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = react::read(react::Of::Page(p), components, text, notes);
    let mut css = String::new();
    let mut media: BTreeMap<u64, String> = BTreeMap::new();
    for (id, list) in react::class_lists(text) {
        let Some(layer) = p.layer(&id) else { continue };
        let mut base = Vec::new();
        let mut narrower: BTreeMap<u64, Vec<(String, String)>> = BTreeMap::new();
        for class in list.iter().skip(1) {
            let (variants, own) = split(class);
            let Some(found) = declarations(&own) else {
                notes.push(format!("{}: {class} isn't a class Aether reads; left as it is", layer.label()));
                continue;
            };
            match variants.as_slice() {
                [] => base.extend(found),
                [one] => match one.strip_prefix("max-[").and_then(|r| r.strip_suffix("px]")).and_then(|w| w.parse::<f64>().ok()) {
                    Some(w) => narrower.entry(w as u64).or_default().extend(found),
                    None => notes.push(format!("{}: {class}'s {one}: isn't a breakpoint; left as it is", layer.label())),
                },
                _ => notes.push(format!("{}: {class} isn't a class Aether reads; left as it is", layer.label())),
            }
        }
        rule_text(&format!(".{id}"), &joined(base), &mut css);
        for (w, decls) in narrower {
            rule_text(&format!(".{id}"), &joined(decls), media.entry(w).or_default());
        }
    }
    for (w, block) in media {
        let _ = writeln!(css, "@media (max-width: {w}px) {{\n{block}}}");
    }
    ops.extend(sync::page_css_ops(p, components, &css, notes));
    ops
}

/// A component's `.tsx` read back: its words and what it holds as React's
/// are, and `look` and each `by<Prop>` as the CSS they came from.
pub fn read_component(c: &Component, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = react::read(react::Of::Component(c), components, text, notes);
    let Some(look) = react::object(text, "const look = ") else {
        notes.push("there's no `const look = { … }` to read its classes from".into());
        return ops;
    };
    let class = |id: &str| match id == c.root {
        true => format!(".{}", c.id),
        false => format!(".{}__{id}", c.id),
    };
    let disabled = format!("{}--{STATE}-disabled", c.id);
    let mut base: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    let mut states: BTreeMap<(String, &str), Vec<(String, String)>> = BTreeMap::new();
    for (id, list) in &look {
        if c.layer(id).is_none() {
            notes.push(format!("look.{id} isn't one of {}'s layers; left as it is", c.id));
            continue;
        }
        for one in list.split_whitespace() {
            let (variants, own) = split(one);
            if variants.is_empty() && own == format!("group/{}", c.id) {
                continue;
            }
            let Some(found) = declarations(&own) else {
                notes.push(format!("look.{id}: {one} isn't a class Aether reads; left as it is"));
                continue;
            };
            let state = match variants.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
                [] => None,
                ["hover"] => Some("hover"),
                ["focus-visible"] => Some("focus"),
                ["active"] => Some("pressed"),
                [v] if *v == format!("data-[{STATE}=disabled]") => Some("disabled"),
                [v] if *v == format!("group-hover/{}", c.id) => Some("hover"),
                [v] if *v == format!("group-focus-visible/{}", c.id) => Some("focus"),
                [v] if *v == format!("group-active/{}", c.id) => Some("pressed"),
                [v] if *v == format!("group-data-[{STATE}=disabled]/{}", c.id) => Some("disabled"),
                _ => {
                    notes.push(format!("look.{id}: {one} isn't a state {} has; left as it is", c.id));
                    continue;
                }
            };
            match state {
                None => base.entry(id.clone()).or_default().extend(found),
                Some(s) => states.entry((id.clone(), s)).or_default().extend(found),
            }
        }
    }
    // Each prop's first option is what the base says; the others, what
    // they say instead of it.
    let mut whole: BTreeMap<String, Vec<(String, String)>> = look.iter().filter(|(id, _)| c.layer(id).is_some()).map(|(id, _)| (id.clone(), joined(base.get(id).cloned().unwrap_or_default()))).collect();
    let mut css = String::new();
    let mut later = String::new();
    for prop in &c.props {
        let Some(lists) = react::object(text, &format!("const {} = ", by(&prop.name))) else { continue };
        let lists: BTreeMap<String, BTreeMap<String, String>> = lists
            .into_iter()
            .filter_map(|(option, inner)| Some((option, react::object(&format!("x = {inner}"), "x = ")?.into_iter().collect())))
            .collect();
        let Some(first) = prop.options.first() else { continue };
        let read = |option: &str, id: &str, notes: &mut Vec<String>| -> Vec<(String, String)> {
            let list = lists.get(option).and_then(|l| l.get(id)).cloned().unwrap_or_default();
            let mut found = Vec::new();
            for one in list.split_whitespace() {
                match declarations(one) {
                    Some(d) => found.extend(d),
                    None => notes.push(format!("{}.{option}.{id}: {one} isn't a class Aether reads; left as it is", by(&prop.name))),
                }
            }
            joined(found)
        };
        for option in lists.keys().filter(|o| !prop.options.contains(o)) {
            notes.push(format!("{}.{option} isn't one of {}'s options; left as it is", by(&prop.name), prop.name));
        }
        for id in c.layers.iter().map(|l| l.id.clone()) {
            let default = read(first, &id, notes);
            // A layer `look` doesn't name, and no option does: left as it is.
            if default.is_empty() && !look.iter().any(|(l, _)| *l == id) {
                continue;
            }
            let entry = whole.entry(id.clone()).or_default();
            for (p, v) in &default {
                match entry.iter_mut().find(|(q, _)| q == p) {
                    Some(slot) => slot.1 = v.clone(),
                    None => entry.push((p.clone(), v.clone())),
                }
            }
            for option in prop.options.iter().skip(1) {
                let mut says = read(option, &id, notes);
                for (p, _) in &default {
                    if !says.iter().any(|(q, _)| q == p) {
                        says.push((p.clone(), "revert".into()));
                    }
                }
                if says.is_empty() {
                    continue;
                }
                let head = format!(".{}--{}-{option}", c.id, prop.name);
                let selector = match id == c.root {
                    true => head,
                    false => format!("{head} {}", class(&id)),
                };
                rule_text(&selector, &says, &mut later);
            }
        }
    }
    for (id, decls) in &whole {
        rule_text(&class(id), decls, &mut css);
    }
    css.push_str(&later);
    for ((id, state), decls) in states {
        let head = match state {
            "hover" => format!(".{}:hover:not(.{disabled})", c.id),
            "focus" => format!(".{}:focus-visible", c.id),
            "pressed" => format!(".{}:active:not(.{disabled})", c.id),
            _ => format!(".{disabled}"),
        };
        let selector = match id == c.root {
            true => head,
            false => format!("{head} {}", class(&id)),
        };
        rule_text(&selector, &joined(decls), &mut css);
    }
    ops.extend(sync::component_css_ops(c, &css, notes));
    ops
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_class_written_reads_back_as_its_declaration() {
        for (p, v) in [
            ("display", "flex"),
            ("display", "none"),
            ("flex-direction", "row"),
            ("gap", "var(--space-6)"),
            ("gap", "8px"),
            ("padding", "var(--space-16) var(--space-8)"),
            ("padding", "16px 20px"),
            ("background", "var(--color-lantern-500)"),
            ("background", "transparent"),
            ("background", "#123456"),
            ("background", "var(--brand)"),
            ("border", "1px solid var(--color-line)"),
            ("border-radius", "var(--radius-full)"),
            ("border-radius", "12px"),
            ("color", "var(--color-ink)"),
            ("color", "rgb(1, 2, 3)"),
            ("font", "var(--type-body)"),
            ("font", "600 15px/1 system-ui, sans-serif"),
            ("text-align", "center"),
            ("opacity", "0.85"),
            ("object-fit", "contain"),
            ("flex", "1 1 240px"),
            ("display", "revert"),
        ] {
            let classes = classes(p, v);
            let back: Vec<(String, String)> = joined(classes.iter().flat_map(|c| declarations(c).unwrap_or_else(|| panic!("{c}"))).collect());
            let want = match (p, v) {
                ("padding", v) if v.split_whitespace().count() == 1 => format!("{v} {v}"),
                _ => v.to_string(),
            };
            assert_eq!(back, vec![(p.to_string(), want)], "{classes:?}");
        }
        assert_eq!(classes("background", "var(--color-lantern-500)"), vec!["bg-lantern-500"]);
        assert_eq!(classes("padding", "var(--space-16) var(--space-8)"), vec!["py-(--space-16)", "px-(--space-8)"]);
        assert_eq!(classes("font", "var(--type-body)"), vec!["[font:var(--type-body)]"]);
    }

    #[test]
    fn variants_are_split_outside_brackets() {
        assert_eq!(split("max-[389px]:[font:var(--x)]"), (vec!["max-[389px]".to_string()], "[font:var(--x)]".to_string()));
        assert_eq!(split("group-hover/button:opacity-[0.85]"), (vec!["group-hover/button".to_string()], "opacity-[0.85]".to_string()));
    }

    #[test]
    fn the_theme_is_tailwinds_and_its_schemes_stay() {
        let theme = theme("/* p */\n:root {\n  --color-ink: #fff;\n}\n@media (prefers-color-scheme: light) {\n  :root {\n    --color-ink: #000;\n  }\n}\n");
        assert!(theme.starts_with("@import \"tailwindcss\";\n\n/* p */\n@theme static {\n  --color-ink: #fff;"), "{theme}");
        assert!(theme.contains("@media (prefers-color-scheme: light) {\n  :root {"), "{theme}");
    }
}
