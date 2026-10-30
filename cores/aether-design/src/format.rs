//! What a design is, on disk: one folder a diff can be read in.
//!
//! ```text
//! design.json              the design: its name and its pages, in order
//! theme.css                the palette: tokens, in Proton's format
//! pages/<id>.page.json     a page: its breakpoints and its layers
//! ```
//!
//! A page's layers are a flat list, each frame naming its children by id,
//! rather than a nested tree. Moving a layer into another frame then changes
//! two lines of `children`, not a block of the file, and an op addresses a
//! layer as `["layers", "#hero"]` wherever it sits in the tree.
//!
//! ## Values
//!
//! A length is a number of points or a token's name (`--space-4`); a colour
//! or a font is a token's name or a CSS value as written (`#f2b84b`,
//! `600 15px/1 system-ui`). Tokens come first — the inspector offers them
//! before raw values — but nothing insists on them. A token the theme does
//! not have is not a broken page: the theme may be mid-edit in a text
//! editor, so the workspace shows it as missing rather than refusing it.
//!
//! Every struct defaults field by field and the writer leaves out what is
//! empty, as Game's files do, so a hand-written layer needs only what it
//! means.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The version every file is written at.
pub const FORMAT: u32 = 1;

/* ── design.json ──────────────────────────────────────────────────── */

/// `design.json`: the design as a whole.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct DesignFile {
    pub format: u32,
    pub name: String,
    /// Its pages' ids, in the order they are listed; each is
    /// `pages/<id>.page.json`.
    pub pages: Vec<String>,
}

impl Default for DesignFile {
    fn default() -> DesignFile {
        DesignFile { format: FORMAT, name: String::new(), pages: Vec::new() }
    }
}

/* ── pages/<id>.page.json ─────────────────────────────────────────── */

/// A page: the widths it is drawn at, and its layers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Page {
    pub format: u32,
    pub id: String,
    pub name: String,
    /// Each width the page is drawn at, side by side: Desktop, Mobile.
    pub breakpoints: Vec<Breakpoint>,
    /// The frame the page is: as wide as the breakpoint, as tall as it holds.
    pub root: String,
    pub layers: Vec<Layer>,
}

impl Default for Page {
    fn default() -> Page {
        Page { format: FORMAT, id: String::new(), name: String::new(), breakpoints: Vec::new(), root: String::new(), layers: Vec::new() }
    }
}

impl Page {
    pub fn layer(&self, id: &str) -> Option<&Layer> {
        self.layers.iter().find(|layer| layer.id == id)
    }

    /// The frame `id` is in, if any.
    pub fn parent(&self, id: &str) -> Option<&Layer> {
        self.layers.iter().find(|layer| layer.children.iter().any(|child| child == id))
    }

    /// `id` and everything inside it, in the tree's order.
    pub fn subtree(&self, id: &str) -> Vec<&Layer> {
        let mut out = Vec::new();
        let mut seen = BTreeSet::new();
        self.walk(id, &mut seen, &mut out);
        out
    }

    fn walk<'a>(&'a self, id: &str, seen: &mut BTreeSet<String>, out: &mut Vec<&'a Layer>) {
        // A cycle is a problem `problems` reports; walking one must still end.
        if !seen.insert(id.to_string()) {
            return;
        }
        let Some(layer) = self.layer(id) else { return };
        out.push(layer);
        for child in &layer.children {
            self.walk(child, seen, out);
        }
    }
}

/// A width a page is drawn at.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Breakpoint {
    pub id: String,
    pub name: String,
    pub width: f64,
}

/// What a layer is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// A box that lays out its children in a row or a column.
    #[default]
    Frame,
    /// A run of text, wrapped to the width it is given.
    Text,
    /// A plain shape: a rule, a swatch, a placeholder for an image.
    Rect,
}

/// A number, or a word: a token's name, `hug`, `fill`, a CSS value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Val {
    Num(f64),
    Text(String),
}

impl Val {
    pub fn word(&self) -> Option<&str> {
        match self {
            Val::Text(text) => Some(text),
            Val::Num(_) => None,
        }
    }
}

/// One layer of a page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Layer {
    /// Letters, digits, `-` and `_`, starting with a letter: it is the
    /// layer's class in the HTML written from it.
    pub id: String,
    pub kind: Kind,
    /// What the layer tree calls it; the id when empty.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    /// The HTML element it is written as — `h1`, `nav`, `a` — when not the
    /// kind's own (`div`, or `p` for text).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub tag: String,
    /// A text layer's words. A line break is a new line.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub text: String,
    /// A frame's layers, first to last.
    pub children: Vec<String>,
    /// `hug`, `fill` or points. Unsaid: `fill` for a frame or a shape, `hug`
    /// for text.
    pub w: Option<Val>,
    /// `hug`, `fill` or points. Unsaid: `hug`, or 100 points for a shape.
    pub h: Option<Val>,
    /// The narrowest a `fill` layer gets in a row that wraps before it
    /// moves to the next line (CSS's flex-basis).
    pub min_w: Option<f64>,
    pub layout: Layout,
    pub style: Style,
}

impl Layer {
    pub fn label(&self) -> &str {
        match self.name.is_empty() {
            true => &self.id,
            false => &self.name,
        }
    }
}

/// How a frame lays out its children.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Layout {
    /// `row` or `column`. Unsaid: `column`.
    pub direction: Option<String>,
    pub gap: Option<Val>,
    /// Padding left and right, and top and bottom.
    pub pad_h: Option<Val>,
    pub pad_v: Option<Val>,
    /// Across the direction: `start`, `center` or `end`.
    pub align: Option<String>,
    /// Along it: `start`, `center`, `end` or `between`.
    pub justify: Option<String>,
    /// Whether a row moves children that don't fit onto another line.
    pub wrap: Option<bool>,
}

/// How a layer looks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Style {
    /// The background, a colour.
    pub fill: Option<String>,
    /// A one-point outline, a colour.
    pub stroke: Option<String>,
    pub radius: Option<Val>,
    /// Text's colour.
    pub color: Option<String>,
    /// Text's font: a token, or CSS's `font` as written.
    pub font: Option<String>,
    /// `start`, `center` or `end`.
    pub text_align: Option<String>,
    pub opacity: Option<f64>,
}

/* ── what each document checks ────────────────────────────────────── */

/// Whether `id` is a plain name: it becomes a class in CSS and a file name.
pub fn is_plain(id: &str) -> bool {
    id.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Ids empty, not plain, or used twice, said as problems.
fn ids<'a>(what: &str, all: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for id in all {
        if !is_plain(id) {
            out.push(format!("a {what} is called {id:?}: an id is letters, digits, - and _, starting with a letter"));
        } else if !seen.insert(id) {
            out.push(format!("two {what}s are called {id}"));
        }
    }
    out
}

/// A CSS value written into a page: nothing that could end the declaration
/// or the stylesheet it is spliced into, or open a tag.
fn plain_value(value: &str) -> bool {
    !value.trim().is_empty() && !value.contains([';', '{', '}', '<', '>', '\n'])
}

impl proton_game::Document for DesignFile {
    fn problems(&self) -> Vec<String> {
        ids("page", self.pages.iter().map(String::as_str))
    }
}

impl proton_game::Document for Page {
    fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if !is_plain(&self.id) {
            out.push(format!("the page is called {:?}: an id is letters, digits, - and _", self.id));
        }
        if self.breakpoints.is_empty() {
            out.push("a page needs a breakpoint to be drawn at".into());
        }
        out.extend(ids("breakpoint", self.breakpoints.iter().map(|b| b.id.as_str())));
        for point in &self.breakpoints {
            if !(point.width.is_finite() && point.width >= 1.0) {
                out.push(format!("{} is {} wide", point.id, point.width));
            }
        }
        out.extend(ids("layer", self.layers.iter().map(|l| l.id.as_str())));

        let known: BTreeSet<&str> = self.layers.iter().map(|l| l.id.as_str()).collect();
        match self.layer(&self.root) {
            None => out.push(format!("the page's root, {:?}, is not one of its layers", self.root)),
            Some(root) if root.kind != Kind::Frame => out.push(format!("the page's root, {}, is not a frame", root.id)),
            Some(_) => {}
        }

        // Each layer in one frame only, every one but the root in some frame.
        let mut parents: BTreeMap<&str, &str> = BTreeMap::new();
        for layer in &self.layers {
            if layer.kind != Kind::Frame && !layer.children.is_empty() {
                out.push(format!("{} has layers inside it but is not a frame", layer.id));
            }
            for child in &layer.children {
                if !known.contains(child.as_str()) {
                    out.push(format!("{} holds {child}, which is not a layer", layer.id));
                } else if let Some(other) = parents.insert(child, &layer.id) {
                    out.push(format!("{child} is in both {other} and {}", layer.id));
                }
            }
        }
        if let Some(holder) = parents.get(self.root.as_str()) {
            out.push(format!("the page's root is inside {holder}"));
        }
        // Reached from the root, or lost: a layer outside the tree, or a
        // loop of frames inside each other, is drawn nowhere.
        let reached: BTreeSet<&str> = self.subtree(&self.root).iter().map(|l| l.id.as_str()).collect();
        for layer in &self.layers {
            if !reached.contains(layer.id.as_str()) && layer.id != self.root && known.contains(layer.id.as_str()) {
                out.push(format!("{} is in no frame of the page", layer.id));
            }
        }

        for layer in &self.layers {
            out.extend(layer_problems(layer));
        }
        out
    }
}

fn layer_problems(layer: &Layer) -> Vec<String> {
    let mut out = Vec::new();
    let id = &layer.id;
    for (what, size) in [("width", &layer.w), ("height", &layer.h)] {
        match size {
            Some(Val::Text(word)) if word != "hug" && word != "fill" => {
                out.push(format!("{id}'s {what} is {word:?}: hug, fill or a number"));
            }
            Some(Val::Num(n)) if !(n.is_finite() && *n >= 0.0) => out.push(format!("{id}'s {what} is {n}")),
            _ => {}
        }
    }
    let lay = &layer.layout;
    let words: [(&str, &Option<String>, &[&str]); 3] = [
        ("direction", &lay.direction, &["row", "column"]),
        ("align", &lay.align, &["start", "center", "end"]),
        ("justify", &lay.justify, &["start", "center", "end", "between"]),
    ];
    for (what, value, allowed) in words {
        if let Some(value) = value {
            if !allowed.contains(&value.as_str()) {
                out.push(format!("{id}'s {what} is {value:?}: {}", allowed.join(", ")));
            }
        }
    }
    if let Some(value) = &layer.style.text_align {
        if !["start", "center", "end"].contains(&value.as_str()) {
            out.push(format!("{id}'s text align is {value:?}"));
        }
    }
    for length in [&lay.gap, &lay.pad_h, &lay.pad_v, &layer.style.radius] {
        match length {
            Some(Val::Text(word)) if !word.starts_with("--") || !plain_value(word) => {
                out.push(format!("{id} has a length of {word:?}: a number or a token"));
            }
            Some(Val::Num(n)) if !(n.is_finite() && *n >= 0.0) => out.push(format!("{id} has a length of {n}")),
            _ => {}
        }
    }
    for value in [&layer.style.fill, &layer.style.stroke, &layer.style.color, &layer.style.font].into_iter().flatten() {
        if !plain_value(value) {
            out.push(format!("{id} has a style of {value:?}, which CSS can't hold"));
        }
    }
    if !layer.tag.is_empty() && !(layer.tag.chars().all(|c| c.is_ascii_alphanumeric()) && layer.tag.chars().next().is_some_and(|c| c.is_ascii_alphabetic())) {
        out.push(format!("{id}'s tag is {:?}", layer.tag));
    }
    if layer.min_w.is_some_and(|n| !(n.is_finite() && n >= 0.0)) {
        out.push(format!("{id}'s narrowest is not a width"));
    }
    out
}
