//! A design as React: each component a `.tsx` whose props are its options
//! and its words, each page a `.tsx` placing them, all styled by the same
//! CSS files the HTML sync writes (see [`crate::sync`]).
//!
//! ```text
//! <folder>/theme.css            the palette
//! <folder>/<id>.css             a component's rules, as for HTML
//! <folder>/<Name>.tsx           the component: `export function Button(…)`
//! <folder>/pages/<id>.css       a page's own rules and media queries
//! <folder>/pages/<Name>.tsx     the page: `export default function HomePage()`
//! <folder>/images/…             its pictures, imported where they're shown
//! ```
//!
//! A component's props are, in order: `className` (where it sits, its
//! page's class), `as` (the element it is, its root's tag unless the page
//! says otherwise), one string union for each of its props (`variant`, the
//! first option the default) and `state`, then one string for each text
//! layer, its own words the default. Every class is the HTML writer's, so
//! the CSS is shared unchanged.
//!
//! Back in, from the `.tsx` files, as one step each ([`read`]):
//!
//! - **A component:** each text prop's default as that layer's words.
//! - **A page:** a text layer's words, from between its tags; and each
//!   instance's attributes — a text prop's words, an option, a state — with
//!   one taken out meaning the component's own again.
//! - **A component inside a component:** its attributes, as a page's.
//!
//! Words are JSX text or a `{"…"}` string, with `<br />` a new line. What a
//! `.tsx` says that the design can't take — a tag, markup in words, an
//! option the component hasn't — is a note, and left as it was. The CSS is
//! read back as for HTML.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use serde_json::{json, Value};

use crate::format::{Component, Kind, Layer, Page, STATE, STATES};
use crate::tailwind::{ComponentLook, PageLook};

/// What the head of each `.tsx` says.
const TSX_MARK: &str = "/* Written by Photon from a design. The words of its text, and the props\n   an instance is given, come back to the design when this file is saved;\n   its look is in the CSS beside it. */\n";

/// The name a component or page goes by in React: its id in PascalCase
/// (`hero-card` → `HeroCard`).
pub fn pascal(id: &str) -> String {
    id.split(['-', '_'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map(|c| c.to_ascii_uppercase().to_string() + chars.as_str()).unwrap_or_default()
        })
        .collect()
}

/// The prop a text layer's words are: its id in camelCase, kept clear of
/// the props every component has and of its own props.
pub fn text_prop(c: &Component, id: &str) -> String {
    let name = pascal(id);
    let mut name = name[..1].to_ascii_lowercase() + &name[1..];
    let taken = |n: &str| ["className", "as", "key", "ref", "children", STATE].contains(&n) || c.props.iter().any(|p| p.name == n);
    if taken(&name) {
        name.push_str("Text");
    }
    name
}

/// A component's `.tsx`; `components` names the words of those it holds.
/// With `look`, styled by Tailwind's classes rather than its CSS file.
pub fn component(c: &Component, components: &BTreeMap<String, Component>, look: Option<&ComponentLook>) -> String {
    let mut out = String::from(TSX_MARK);
    out.push_str("import type { ElementType } from \"react\";\n");
    for inner in held(c) {
        let _ = writeln!(out, "import {{ {} }} from \"./{}\";", pascal(&inner), pascal(&inner));
    }
    for (name, src) in images(&c.layers) {
        let _ = writeln!(out, "import {name} from \"./{src}\";");
    }
    match look {
        None => {
            let _ = writeln!(out, "import \"./{}.css\";\n", c.id);
        }
        Some(look) => {
            out.push('\n');
            out.push_str("/** Each layer's classes. What an option changes is in its own list\n    below, one of which always applies. */\nconst look = {\n");
            for (id, list) in &look.base {
                let _ = writeln!(out, "  {}: {},", key(id), string(list));
            }
            out.push_str("};\n\n");
            for (prop, lists) in &look.by {
                let _ = writeln!(out, "/** What each {prop} says instead. */\nconst {} = {{", crate::tailwind::by(prop));
                for (option, list) in lists {
                    let inner: Vec<String> = list.iter().map(|(id, l)| format!("{}: {}", key(id), string(l))).collect();
                    let _ = writeln!(out, "  {}: {{ {} }},", key(option), inner.join(", "));
                }
                out.push_str("};\n\n");
            }
        }
    }

    let name = pascal(&c.id);
    let texts: Vec<&Layer> = c.layers.iter().filter(|l| l.kind == Kind::Text).collect();
    let states: Vec<&str> = STATES.iter().copied().filter(|s| c.states.iter().any(|x| x == s)).collect();
    let _ = writeln!(out, "export type {name}Props = {{");
    out.push_str("  /** Where it sits: its page's class. */\n  className?: string;\n");
    out.push_str("  /** The element it is. */\n  as?: ElementType;\n");
    for prop in &c.props {
        let _ = writeln!(out, "  {}?: {};", prop.name, union(&prop.options));
    }
    if !states.is_empty() {
        let _ = writeln!(out, "  {STATE}?: {};", union(&states.iter().map(|s| s.to_string()).collect::<Vec<_>>()));
    }
    for layer in &texts {
        let _ = writeln!(out, "  {}?: string;", text_prop(c, &layer.id));
    }
    out.push_str("};\n\n");

    let root = c.layer(&c.root);
    let mut args = vec!["className".to_string(), format!("as: Root = {}", string(root.map(tag).unwrap_or("div")))];
    for prop in &c.props {
        match prop.options.first() {
            Some(first) => args.push(format!("{} = {}", prop.name, string(first))),
            None => args.push(prop.name.clone()),
        }
    }
    if !states.is_empty() {
        args.push(STATE.to_string());
    }
    for layer in &texts {
        args.push(format!("{} = {}", text_prop(c, &layer.id), string(&layer.text)));
    }
    let _ = writeln!(out, "export function {name}({{ {} }}: {name}Props) {{", args.join(", "));
    let mut classes = vec![string(&c.id)];
    for prop in &c.props {
        classes.push(format!("`{}--{}-${{{}}}`", c.id, prop.name, prop.name));
    }
    if !states.is_empty() {
        classes.push(format!("{STATE} && `{}--{STATE}-${{{STATE}}}`", c.id));
    }
    classes.extend(look.map(|l| looked(l, &c.root)).unwrap_or_default());
    classes.push("className".into());
    out.push_str("  return (\n");
    let mut disabled = if states.contains(&"disabled") { format!(" aria-disabled={{{STATE} === \"disabled\" || undefined}}") } else { String::new() };
    if look.is_some() && !states.is_empty() {
        // What `data-[state=disabled]:` and the group's states look at.
        disabled = format!(" data-{STATE}={{{STATE}}}{disabled}");
    }
    let class = format!("{{[{}].filter(Boolean).join(\" \")}}", classes.join(", "));
    match root {
        Some(root) if !root.children.is_empty() && root.kind == Kind::Frame => {
            let _ = writeln!(out, "    <Root className={class}{disabled}>");
            for child in &root.children {
                component_element(c, components, look, child, 3, &mut out);
            }
            out.push_str("    </Root>\n");
        }
        Some(root) if root.kind == Kind::Text => {
            let _ = writeln!(out, "    <Root className={class}{disabled}>{{{}}}</Root>", text_prop(c, &root.id));
        }
        _ => {
            let _ = writeln!(out, "    <Root className={class}{disabled} />");
        }
    }
    out.push_str("  );\n}\n");
    out
}

/// A page's `.tsx`. With `look`, styled by Tailwind's classes, and its own
/// CSS imported only when it holds anything.
pub fn page(p: &Page, components: &BTreeMap<String, Component>, look: Option<&PageLook>) -> String {
    let mut out = String::from(TSX_MARK);
    out.push_str("import \"../theme.css\";\n");
    let mut placed: Vec<String> = Vec::new();
    for layer in p.subtree(&p.root) {
        if layer.kind == Kind::Instance && components.contains_key(&layer.component) && !placed.contains(&layer.component) {
            placed.push(layer.component.clone());
        }
    }
    for id in &placed {
        let _ = writeln!(out, "import {{ {} }} from \"../{}\";", pascal(id), pascal(id));
    }
    let own: Vec<Layer> = p.subtree(&p.root).into_iter().cloned().collect();
    for (name, src) in images(&own) {
        let _ = writeln!(out, "import {name} from \"../{src}\";");
    }
    match look {
        Some(look) if look.css.is_empty() => out.push('\n'),
        _ => {
            let _ = writeln!(out, "import \"./{}.css\";\n", p.id);
        }
    }
    let _ = writeln!(out, "export default function {}Page() {{", pascal(&p.id));
    out.push_str("  return (\n");
    page_element(p, components, look, &p.root, 2, &mut Vec::new(), &mut out);
    out.push_str("  );\n}\n");
    out
}

/// The components a component places, in order.
fn held(c: &Component) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for layer in &c.layers {
        if layer.kind == Kind::Instance && !out.contains(&layer.component) {
            out.push(layer.component.clone());
        }
    }
    out
}

/// Each picture shown, once: the name it's imported as and its file.
fn images(layers: &[Layer]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for layer in layers.iter().filter(|l| l.kind == Kind::Image && crate::format::is_image_path(&l.src)) {
        if out.iter().any(|(_, src)| *src == layer.src) {
            continue;
        }
        let file = layer.src.rsplit('/').next().unwrap_or(&layer.src);
        let stem = file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file);
        let mut name = pascal(&stem.replace(|c: char| !c.is_ascii_alphanumeric(), "-"));
        name = format!("{}{}Image", name.get(..1).map(|s| s.to_ascii_lowercase()).unwrap_or_default(), name.get(1..).unwrap_or(""));
        if name.chars().next().is_none_or(|c| !c.is_ascii_alphabetic()) {
            name = format!("image{name}");
        }
        while out.iter().any(|(n, _)| *n == name) {
            name.push('2');
        }
        out.push((name, layer.src.clone()));
    }
    out
}

fn image_name(layers: &[Layer], src: &str) -> Option<String> {
    images(layers).into_iter().find(|(_, s)| s == src).map(|(n, _)| n)
}

/// A layer's classes in a component styled by Tailwind: its own list and,
/// for each prop that changes it, its option's.
fn looked(look: &ComponentLook, id: &str) -> Vec<String> {
    let mut out = vec![format!("look{}", access(id))];
    for (prop, lists) in &look.by {
        if lists.iter().any(|(_, list)| list.iter().any(|(l, _)| l == id)) {
            out.push(format!("{}[{prop}]{}", crate::tailwind::by(prop), access(id)));
        }
    }
    out
}

/// A key of an object: bare when it can be.
fn key(id: &str) -> String {
    match id.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        true => id.to_string(),
        false => string(id),
    }
}

fn access(id: &str) -> String {
    match key(id) == id {
        true => format!(".{id}"),
        false => format!("[{}]", string(id)),
    }
}

fn component_element(c: &Component, components: &BTreeMap<String, Component>, look: Option<&ComponentLook>, id: &str, depth: usize, out: &mut String) {
    let Some(layer) = c.layer(id) else { return };
    let indent = "  ".repeat(depth);
    let plain = format!("{}__{}", c.id, layer.id);
    // `className="button__label"`, or with Tailwind its classes after it.
    let class = match look {
        None => format!("\"{plain}\""),
        Some(look) => format!("{{[{}].filter(Boolean).join(\" \")}}", [string(&plain)].into_iter().chain(looked(look, &layer.id)).collect::<Vec<_>>().join(", ")),
    };
    match layer.kind {
        Kind::Text => {
            let _ = writeln!(out, "{indent}<{0} className={class}>{{{1}}}</{0}>", tag(layer), text_prop(c, &layer.id));
        }
        Kind::Image => {
            let src = image_name(&c.layers, &layer.src).map(|n| format!("{{{n}}}")).unwrap_or_else(|| string(&layer.src));
            let _ = writeln!(out, "{indent}<img className={class} src={src} alt={} />", string(&layer.text));
        }
        Kind::Instance => {
            let _ = writeln!(out, "{indent}{}", instance(layer, &class, components));
        }
        _ if layer.children.is_empty() => {
            let _ = writeln!(out, "{indent}<{0} className={class} />", tag(layer));
        }
        _ => {
            let _ = writeln!(out, "{indent}<{} className={class}>", tag(layer));
            for child in &layer.children {
                component_element(c, components, look, child, depth + 1, out);
            }
            let _ = writeln!(out, "{indent}</{}>", tag(layer));
        }
    }
}

fn page_element(p: &Page, components: &BTreeMap<String, Component>, look: Option<&PageLook>, id: &str, depth: usize, path: &mut Vec<String>, out: &mut String) {
    let Some(layer) = p.layer(id) else { return };
    if path.iter().any(|seen| seen == id) {
        return;
    }
    // Its id, and with Tailwind its classes after it.
    let class = match look.and_then(|l| l.classes.get(id)).filter(|c| !c.is_empty()) {
        Some(classes) => format!("{id} {classes}"),
        None => id.to_string(),
    };
    let indent = "  ".repeat(depth);
    match layer.kind {
        Kind::Text => {
            let _ = writeln!(out, "{indent}<{0} className=\"{1}\">{2}</{0}>", tag(layer), class, words(&layer.text));
        }
        Kind::Image => {
            let own: Vec<Layer> = p.subtree(&p.root).into_iter().cloned().collect();
            let src = image_name(&own, &layer.src).map(|n| format!("{{{n}}}")).unwrap_or_else(|| string(&layer.src));
            let _ = writeln!(out, "{indent}<img className=\"{class}\" src={src} alt={} />", string(&layer.text));
        }
        Kind::Instance if components.contains_key(&layer.component) => {
            let _ = writeln!(out, "{indent}{}", instance(layer, &format!("\"{class}\""), components));
        }
        Kind::Instance => {
            let _ = writeln!(out, "{indent}{{/* {}: no component {} */}}", layer.id, layer.component);
        }
        _ if layer.children.is_empty() => {
            let _ = writeln!(out, "{indent}<{0} className=\"{1}\" />", tag(layer), class);
        }
        _ => {
            let _ = writeln!(out, "{indent}<{} className=\"{class}\">", tag(layer));
            path.push(id.to_string());
            for child in &layer.children {
                page_element(p, components, look, child, depth + 1, path, out);
            }
            path.pop();
            let _ = writeln!(out, "{indent}</{}>", tag(layer));
        }
    }
}

/// An instance as its component's element: where it sits, the element it
/// is when it says, then what it chooses and the words it gives.
fn instance(layer: &Layer, class: &str, components: &BTreeMap<String, Component>) -> String {
    let mut out = format!("<{} className={class}", pascal(&layer.component));
    if !layer.tag.is_empty() {
        let _ = write!(out, " as={}", attribute(&layer.tag));
    }
    for (prop, option) in &layer.props {
        let _ = write!(out, " {prop}={}", attribute(option));
    }
    // Words by the prop they're given as.
    let empty = Component::default();
    let c = components.get(&layer.component).unwrap_or(&empty);
    for (id, text) in &layer.texts {
        let _ = write!(out, " {}={}", text_prop(c, id), attribute(text));
    }
    out.push_str(" />");
    out
}

fn tag(layer: &Layer) -> &str {
    match (layer.tag.is_empty(), layer.kind) {
        (false, _) => &layer.tag,
        (true, Kind::Text) => "p",
        (_, Kind::Image) => "img",
        (true, _) => "div",
    }
}

fn union(options: &[String]) -> String {
    match options.is_empty() {
        true => "string".into(),
        false => options.iter().map(|o| string(o)).collect::<Vec<_>>().join(" | "),
    }
}

/// A JavaScript string: JSON's, which JavaScript reads the same.
fn string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into())
}

/// An attribute's value: quoted when JSX takes it as it is, else a string
/// in braces.
fn attribute(text: &str) -> String {
    match text.contains(['"', '\n', '&', '\\', '{', '}', '<', '>']) {
        true => format!("{{{}}}", string(text)),
        false => format!("\"{text}\""),
    }
}

/// Words as JSX: each line as text when JSX reads it back the same, else
/// as a string in braces; lines joined by `<br />`.
fn words(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let plain = !line.is_empty()
                && !line.contains(['{', '}', '<', '>', '&', '"'])
                && line.trim() == line
                && !line.contains("  ");
            match plain {
                true => line.to_string(),
                false => format!("{{{}}}", string(line)),
            }
        })
        .collect::<Vec<_>>()
        .join("<br />")
}

/* ── read ─────────────────────────────────────────────────────────── */

/// What a `.tsx` file is for: the component or page whose React name it
/// carries.
pub enum Of<'a> {
    Component(&'a Component),
    Page(&'a Page),
}

/// The ops bringing a component's or page's document to what its `.tsx`
/// says, and notes on what couldn't be read.
pub fn read(of: Of, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    match of {
        Of::Component(c) => component_ops(c, components, text, notes),
        Of::Page(p) => page_ops(p, components, text, notes),
    }
}

fn component_ops(c: &Component, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    let name = pascal(&c.id);
    let Some(defaults) = defaults(text, &format!("export function {name}(")) else {
        notes.push(format!("there's no `export function {name}({{ … }})` to read its words from"));
        return ops;
    };
    for layer in c.layers.iter().filter(|l| l.kind == Kind::Text) {
        let prop = text_prop(c, &layer.id);
        match defaults.get(&prop) {
            Some(Some(value)) => match js_string(value) {
                Some(w) if w != layer.text => ops.push(set(&layer.id, &["text"], json!(w))),
                Some(_) => {}
                None => notes.push(format!("{prop}'s default isn't a string; {} left as it is", layer.label())),
            },
            _ => notes.push(format!("{prop} has no default; {} left as it is", layer.label())),
        }
    }
    let root_tag = c.layer(&c.root).map(tag).unwrap_or("div");
    if let Some(Some(said)) = defaults.get("as") {
        if js_string(said).as_deref() != Some(root_tag) {
            notes.push(format!("the element it is ({said}) is the design's to say; left as {root_tag}"));
        }
    }
    for prop in &c.props {
        if let (Some(Some(said)), Some(first)) = (defaults.get(&prop.name), prop.options.first()) {
            if js_string(said).as_ref() != Some(first) {
                notes.push(format!("{}'s default is its first option, {first}; left as it is", prop.name));
            }
        }
    }
    // Components it holds, by their class there.
    let elements = elements(text);
    for layer in c.layers.iter().filter(|l| l.kind == Kind::Instance) {
        let class = format!("{}__{}", c.id, layer.id);
        if let Some(element) = elements.iter().find(|e| e.classes().iter().any(|k| *k == class)) {
            ops.extend(instance_ops(layer, components, element, notes));
        }
    }
    ops
}

fn page_ops(p: &Page, components: &BTreeMap<String, Component>, text: &str, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    for element in elements(text) {
        let classes = element.classes();
        let Some(layer) = classes.first().and_then(|k| p.layer(k)) else { continue };
        match layer.kind {
            Kind::Text => match element.inner(text).map(read_words) {
                Some(Content::Words(w)) if w != layer.text => ops.push(set(&layer.id, &["text"], json!(w))),
                Some(Content::Words(_)) | None => {}
                Some(_) => notes.push(format!("{} holds markup, not words; left as it is", layer.label())),
            },
            Kind::Instance => ops.extend(instance_ops(layer, components, &element, notes)),
            _ => {}
        }
    }
    ops
}

/// What an instance's attributes say: its options, its state and its
/// words. One taken out is the component's own again.
fn instance_ops(layer: &Layer, components: &BTreeMap<String, Component>, element: &Element, notes: &mut Vec<String>) -> Vec<proton_game::Op> {
    let mut ops = Vec::new();
    let Some(c) = components.get(&layer.component) else { return ops };
    let label = layer.label();
    let mut said: BTreeMap<&str, String> = BTreeMap::new();
    for (name, value) in &element.attrs {
        if name == "className" || name == "key" {
            continue;
        }
        match value.as_deref().and_then(attribute_value) {
            Some(v) => {
                said.insert(name.as_str(), v);
            }
            None => notes.push(format!("{label}'s {name} isn't a string; left as it is")),
        }
    }
    if said.get("as").map(String::as_str).unwrap_or("") != layer.tag {
        notes.push(format!("{label}'s element is the design's to say; left as it is"));
    }
    let path = layer_path(&layer.id);
    // Options and the state.
    let mut choices: Vec<(&str, Vec<String>)> = c.props.iter().map(|p| (p.name.as_str(), p.options.clone())).collect();
    choices.push((STATE, c.states.clone()));
    for (prop, options) in choices {
        match (said.get(prop), layer.props.get(prop)) {
            (Some(v), given) if given != Some(v) => match options.contains(v) {
                true => ops.push(set_at(&path, &["props", prop], json!(v))),
                false => notes.push(format!("{label}'s {prop} can be {}, not {v}; left as it is", options.join(", "))),
            },
            (None, Some(_)) => ops.push(proton_game::Op::Remove { path: [path.clone(), vec!["props".into(), prop.to_string()]].concat() }),
            _ => {}
        }
    }
    // Words.
    for own in c.layers.iter().filter(|l| l.kind == Kind::Text) {
        let prop = text_prop(c, &own.id);
        match (said.get(prop.as_str()), layer.texts.get(&own.id)) {
            (Some(w), given) if given != Some(w) => ops.push(set_at(&path, &["texts", &own.id], json!(w))),
            (None, Some(_)) => ops.push(proton_game::Op::Remove { path: [path.clone(), vec!["texts".into(), own.id.clone()]].concat() }),
            _ => {}
        }
    }
    let known: Vec<String> = c.props.iter().map(|p| p.name.clone()).chain([STATE.to_string(), "as".into()]).chain(c.layers.iter().filter(|l| l.kind == Kind::Text).map(|l| text_prop(c, &l.id))).collect();
    for name in said.keys().filter(|n| !known.iter().any(|k| k == *n)) {
        notes.push(format!("{label}: {} has no prop {name}", pascal(&c.id)));
    }
    ops
}

fn set(id: &str, keys: &[&str], value: Value) -> proton_game::Op {
    set_at(&layer_path(id), keys, value)
}

fn set_at(path: &[String], keys: &[&str], value: Value) -> proton_game::Op {
    let mut at = path.to_vec();
    at.extend(keys.iter().map(|k| k.to_string()));
    proton_game::Op::Set { path: at, value }
}

fn layer_path(id: &str) -> Vec<String> {
    vec!["layers".into(), format!("#{id}")]
}

/// The defaults of the props `function Name({ a, b = "x" })` takes, after
/// `head`: each prop by its name (an alias `as: Root` by `as`), with its
/// default's source if it has one.
fn defaults(text: &str, head: &str) -> Option<BTreeMap<String, Option<String>>> {
    let start = text.find(head)? + head.len();
    let open = start + text[start..].find('{')?;
    let close = closing(text, open)?;
    let mut out = BTreeMap::new();
    for part in split_top(&text[open + 1..close], ',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let (left, default) = match split_top(part, '=').as_slice() {
            [left] => (left.trim().to_string(), None),
            [left, rest @ ..] => (left.trim().to_string(), Some(rest.join("=").trim().to_string())),
            [] => continue,
        };
        let name = left.split(':').next().unwrap_or("").trim().to_string();
        out.insert(name, default);
    }
    Some(out)
}

/// `text` split at `at` where it's outside strings, braces, brackets and
/// parentheses.
fn split_top(text: &str, at: char) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for c in text.chars() {
        if let Some(q) = quote {
            out.last_mut().unwrap().push(c);
            match (escaped, c) {
                (true, _) => escaped = false,
                (false, '\\') => escaped = true,
                (false, c) if c == q => quote = None,
                _ => {}
            }
            continue;
        }
        match c {
            '"' | '\'' | '`' => quote = Some(c),
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => depth -= 1,
            c if c == at && depth == 0 => {
                out.push(String::new());
                continue;
            }
            _ => {}
        }
        out.last_mut().unwrap().push(c);
    }
    out
}

/// The brace, bracket or parenthesis closing the one at `open`, outside
/// strings.
fn closing(text: &str, open: usize) -> Option<usize> {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    let mut escaped = false;
    for (i, c) in text[open..].char_indices() {
        if let Some(q) = quote {
            match (escaped, c) {
                (true, _) => escaped = false,
                (false, '\\') => escaped = true,
                (false, c) if c == q => quote = None,
                _ => {}
            }
            continue;
        }
        match c {
            '"' | '\'' | '`' => quote = Some(c),
            '{' | '[' | '(' => depth += 1,
            '}' | ']' | ')' => {
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

/// A JavaScript string literal's value: double- or single-quoted, or a
/// template without `${}`.
fn js_string(source: &str) -> Option<String> {
    let s = source.trim();
    if s.len() < 2 {
        return None;
    }
    let (first, last) = (s.chars().next()?, s.chars().last()?);
    if first != last || !['"', '\'', '`'].contains(&first) {
        return None;
    }
    if first == '`' && s.contains("${") {
        return None;
    }
    let body = &s[1..s.len() - 1];
    let mut out = String::new();
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c == first {
            return None;
        }
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next()? {
            'n' => out.push('\n'),
            't' => out.push('\t'),
            'r' => out.push('\r'),
            '0' => out.push('\0'),
            'u' => {
                let hex: String = chars.by_ref().take(4).collect();
                out.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
            }
            other => out.push(other),
        }
    }
    Some(out)
}

/// An attribute's value as words: a quoted string (entities decoded) or a
/// string in braces.
fn attribute_value(source: &str) -> Option<String> {
    let s = source.trim();
    if let Some(inner) = s.strip_prefix('{').and_then(|r| r.strip_suffix('}')) {
        return js_string(inner);
    }
    let inner = s.strip_prefix('"').and_then(|r| r.strip_suffix('"')).or_else(|| s.strip_prefix('\'').and_then(|r| r.strip_suffix('\'')))?;
    Some(entities(inner))
}

fn entities(text: &str) -> String {
    text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", "\u{a0}").replace("&amp;", "&")
}

/// What's between an element's tags.
#[derive(Debug, PartialEq)]
enum Content {
    Words(String),
    /// An expression, as a component's `{label}`.
    Expression,
    Markup,
}

/// Words between tags, as JSX reads them: each line of text trimmed and
/// joined by a space, `{"…"}` a string, `<br />` a new line.
fn read_words(inner: &str) -> Content {
    let mut lines = Vec::new();
    let mut rest = inner;
    loop {
        let (piece, after) = match rest.find("<br") {
            Some(at) => {
                let end = rest[at..].find('>').map(|e| at + e + 1).unwrap_or(rest.len());
                let tag = rest[at..end].trim_start_matches("<br").trim_end_matches('>').trim().trim_end_matches('/').trim();
                if !tag.is_empty() {
                    return Content::Markup;
                }
                (&rest[..at], Some(&rest[end..]))
            }
            None => (rest, None),
        };
        let mut line = String::new();
        let mut text = piece;
        while !text.is_empty() {
            match text.find('{') {
                Some(at) => {
                    if text[..at].contains('<') {
                        return Content::Markup;
                    }
                    line.push_str(&jsx_text(&text[..at]));
                    let Some(close) = closing(text, at) else { return Content::Markup };
                    match js_string(&text[at + 1..close]) {
                        Some(s) => line.push_str(&s),
                        None if text[at + 1..close].trim().starts_with("/*") => {}
                        None => return Content::Expression,
                    }
                    text = &text[close + 1..];
                }
                None => {
                    if text.contains('<') {
                        return Content::Markup;
                    }
                    line.push_str(&jsx_text(text));
                    text = "";
                }
            }
        }
        lines.push(line);
        match after {
            Some(after) => rest = after,
            None => break,
        }
    }
    Content::Words(lines.join("\n"))
}

/// JSX text: lines trimmed, blank ones dropped, the rest joined by a space;
/// entities decoded.
fn jsx_text(text: &str) -> String {
    if !text.contains('\n') {
        return entities(text);
    }
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    entities(&lines.join(" "))
}

/// An element of the JSX: its name, attributes (each value's source, or
/// none for a bare one) and where what's between its tags is.
#[derive(Debug)]
struct Element {
    attrs: Vec<(String, Option<String>)>,
    inner: Option<(usize, usize)>,
}

impl Element {
    /// Its classes: a quoted list, or the first string of a list in
    /// braces, as `{["button__label", look.label].join(" ")}`.
    fn classes(&self) -> Vec<String> {
        let Some(v) = self.attrs.iter().find(|(n, _)| n == "className").and_then(|(_, v)| v.as_deref()) else { return Vec::new() };
        let v = v.trim();
        let said = match v.strip_prefix("{[") {
            Some(list) => split_top(list, ',').first().and_then(|first| js_string(first)),
            None => v.strip_prefix('"').and_then(|r| r.strip_suffix('"')).map(str::to_string),
        };
        said.map(|v| v.split_whitespace().map(str::to_string).collect()).unwrap_or_default()
    }

    fn inner<'a>(&self, text: &'a str) -> Option<&'a str> {
        self.inner.map(|(a, b)| &text[a..b])
    }
}

/// Each element's classes, by its first: a layer's id, or a component's
/// class for it.
pub fn class_lists(text: &str) -> Vec<(String, Vec<String>)> {
    elements(text)
        .iter()
        .map(|e| e.classes())
        .filter_map(|all| Some((all.first()?.clone(), all)))
        .collect()
}

/// The keys of the object after `head` (`const look = `), each with its
/// value: a string's words, or anything else's source.
pub fn object(text: &str, head: &str) -> Option<Vec<(String, String)>> {
    let start = text.find(head)? + head.len();
    let open = start + text[start..].find('{')?;
    if !text[start..open].trim().is_empty() {
        return None;
    }
    let close = closing(text, open)?;
    let mut out = Vec::new();
    for part in split_top(&text[open + 1..close], ',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let pieces = split_top(part, ':');
        let (Some(name), true) = (pieces.first(), pieces.len() > 1) else { continue };
        let name = name.trim();
        let name = js_string(name).unwrap_or_else(|| name.to_string());
        let value = pieces[1..].join(":");
        let value = value.trim();
        out.push((name, js_string(value).unwrap_or_else(|| value.to_string())));
    }
    Some(out)
}

/// The JSX elements after the first `return (`, in order.
fn elements(text: &str) -> Vec<Element> {
    let Some(start) = text.find("return (") else { return Vec::new() };
    let bytes = text.as_bytes();
    let mut out: Vec<Element> = Vec::new();
    let mut open: Vec<(String, usize)> = Vec::new();
    let mut i = start + "return (".len();
    while i < bytes.len() {
        match bytes[i] {
            b'{' => i = closing(text, i).map(|c| c + 1).unwrap_or(bytes.len()),
            b'<' if bytes.get(i + 1) == Some(&b'/') => {
                let end = text[i..].find('>').map(|e| i + e).unwrap_or(bytes.len());
                let name = text[i + 2..end].trim().to_string();
                if let Some(at) = open.iter().rposition(|(n, _)| *n == name) {
                    let index = open[at].1;
                    if let Some(element) = out.get_mut(index) {
                        if let Some((a, _)) = element.inner {
                            element.inner = Some((a, i));
                        }
                    }
                    open.truncate(at);
                }
                i = end + 1;
            }
            b'<' if bytes.get(i + 1).is_some_and(|b| b.is_ascii_alphabetic()) => {
                let mut j = i + 1;
                while j < bytes.len() && (bytes[j].is_ascii_alphanumeric() || b"._-".contains(&bytes[j])) {
                    j += 1;
                }
                let name = text[i + 1..j].to_string();
                let mut attrs = Vec::new();
                let mut closed = false;
                loop {
                    while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                        j += 1;
                    }
                    if j >= bytes.len() {
                        break;
                    }
                    if bytes[j] == b'/' {
                        closed = true;
                        j = text[j..].find('>').map(|e| j + e + 1).unwrap_or(bytes.len());
                        break;
                    }
                    if bytes[j] == b'>' {
                        j += 1;
                        break;
                    }
                    if bytes[j] == b'{' {
                        // A spread: `{...rest}`.
                        j = closing(text, j).map(|c| c + 1).unwrap_or(bytes.len());
                        continue;
                    }
                    let a = j;
                    while j < bytes.len() && !bytes[j].is_ascii_whitespace() && !b"=/>".contains(&bytes[j]) {
                        j += 1;
                    }
                    let attr = text[a..j].to_string();
                    if bytes.get(j) == Some(&b'=') {
                        j += 1;
                        let v = j;
                        match bytes.get(j) {
                            Some(b'{') => j = closing(text, j).map(|c| c + 1).unwrap_or(bytes.len()),
                            Some(&q) if q == b'"' || q == b'\'' => j = text[j + 1..].find(q as char).map(|e| j + 1 + e + 1).unwrap_or(bytes.len()),
                            _ => {}
                        }
                        attrs.push((attr, Some(text[v..j].to_string())));
                    } else if !attr.is_empty() {
                        attrs.push((attr, None));
                    } else {
                        j += 1;
                    }
                }
                let index = out.len();
                out.push(Element { attrs, inner: (!closed).then_some((j, j)) });
                if !closed {
                    open.push((name, index));
                }
                i = j;
            }
            _ => i += 1,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_round_trip() {
        for text in ["Wishlist now", "Two\nlines", " spaced  out ", "a {brace} & <tag>", "quote \"this\"", ""] {
            let jsx = format!("return (<p className=\"x\">{}</p>)", words(text));
            let all = elements(&jsx);
            assert_eq!(read_words(all[0].inner(&jsx).unwrap()), Content::Words(text.to_string()), "{jsx}");
        }
    }

    #[test]
    fn attributes_round_trip() {
        for text in ["Watch the trailer", "say \"hi\"", "a & b", "two\nlines"] {
            assert_eq!(attribute_value(&attribute(text)).as_deref(), Some(text));
        }
    }

    #[test]
    fn names() {
        assert_eq!(pascal("hero-card"), "HeroCard");
        assert_eq!(pascal("button"), "Button");
        assert_eq!(pascal("nav_link_2"), "NavLink2");
    }
}
