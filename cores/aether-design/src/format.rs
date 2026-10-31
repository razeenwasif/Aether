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
//! ## Breakpoints
//!
//! The widest breakpoint is the page's own: a layer's fields are what it is
//! there. Each narrower one can say otherwise in the layer's `at`, by the
//! breakpoint's id, and what it says holds for every breakpoint narrower
//! still unless that one says otherwise too — CSS's cascade of `max-width`
//! media queries, which is how the page is written out.
//!
//! ## Pictures
//!
//! An image layer names a file in the design's `images/`. When the picture
//! is another workspace's asset, the project's graph holds the link and the
//! workspace writes each new version over that file, as Diffuse writes a
//! Load Image's picture; the page itself doesn't change.
//!
//! ## Components
//!
//! `components/<id>.component.json` is a tree of layers like a page's, with
//! props — `variant: primary | secondary`, the first option the default —
//! and each layer's `when` saying what an option changes, as `at` does for a
//! breakpoint. A page places one as an `instance` layer: which component,
//! which option of each prop, and the words of any of its text layers. An
//! instance is expanded into the component's layers wherever the page is
//! drawn or written ([`expand`]), so changing the component changes every
//! page that uses it.
//!
//! A component's `states` — hover, pressed, focus, disabled — are said the
//! same way, as `state=hover` in a layer's `when`. The first three happen
//! when someone uses the page, so they're CSS's `:hover`, `:active` and
//! `:focus-visible`, and no page picks them; a page can pick `disabled`.
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

    /// The breakpoints widest first: the page's own, then each that says
    /// otherwise.
    pub fn widest_first(&self) -> Vec<&Breakpoint> {
        let mut points: Vec<&Breakpoint> = self.breakpoints.iter().collect();
        points.sort_by(|a, b| b.width.total_cmp(&a.width));
        points
    }

    /// The page as it is at breakpoint `id`: each layer with what that
    /// breakpoint and every wider one say laid over it. Unknown, or the
    /// widest, is the page as written.
    pub fn at(&self, id: &str) -> Page {
        let points = self.widest_first();
        let Some(place) = points.iter().position(|b| b.id == id) else { return self.clone() };
        // Each breakpoint after the widest down to this one, widest first,
        // as the media queries cascade.
        let wider: Vec<String> = points.iter().skip(1).take(place).map(|b| b.id.clone()).collect();
        let mut page = self.clone();
        for layer in &mut page.layers {
            for point in &wider {
                if let Some(over) = layer.at.get(point).cloned() {
                    over.apply(layer);
                }
            }
        }
        page
    }

    /// `id` and everything inside it, in the tree's order.
    pub fn subtree(&self, id: &str) -> Vec<&Layer> {
        subtree(&self.layers, id)
    }
}

/// `id` and everything inside it in `layers`, in the tree's order.
pub fn subtree<'a>(layers: &'a [Layer], id: &str) -> Vec<&'a Layer> {
    fn walk<'a>(layers: &'a [Layer], id: &str, seen: &mut BTreeSet<String>, out: &mut Vec<&'a Layer>) {
        // A cycle is a problem the checks report; walking one must still end.
        if !seen.insert(id.to_string()) {
            return;
        }
        let Some(layer) = layers.iter().find(|l| l.id == id) else { return };
        out.push(layer);
        for child in &layer.children {
            walk(layers, child, seen, out);
        }
    }
    let mut out = Vec::new();
    walk(layers, id, &mut BTreeSet::new(), &mut out);
    out
}

/* ── components/<id>.component.json ───────────────────────────────── */

/// A component: a tree of layers placed on pages as instances, and its
/// props, each a list of options.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Component {
    pub format: u32,
    pub id: String,
    pub name: String,
    pub props: Vec<Prop>,
    /// Which of [`STATES`] it has a look for.
    pub states: Vec<String>,
    pub root: String,
    pub layers: Vec<Layer>,
}

impl Default for Component {
    fn default() -> Component {
        Component { format: FORMAT, id: String::new(), name: String::new(), props: Vec::new(), states: Vec::new(), root: String::new(), layers: Vec::new() }
    }
}

/// The states a component can have a look for, in the order the CSS
/// writes them: a later one wins where two hold at once.
pub const STATES: [&str; 4] = ["hover", "focus", "pressed", "disabled"];

/// What says a state is the page's, not the instance's: the prop name a
/// state is keyed by in `when`.
pub const STATE: &str = "state";

/// One of a component's props: `variant`, and its options, the first the
/// default.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Prop {
    pub name: String,
    pub options: Vec<String>,
}

impl Component {
    pub fn layer(&self, id: &str) -> Option<&Layer> {
        self.layers.iter().find(|layer| layer.id == id)
    }

    /// The option each prop takes for `chosen`: what it says, else the
    /// default, in the props' order.
    pub fn options(&self, chosen: &BTreeMap<String, String>) -> Vec<(String, String)> {
        let mut out: Vec<(String, String)> = self
            .props
            .iter()
            .map(|p| (p.name.clone(), chosen.get(&p.name).cloned().or_else(|| p.options.first().cloned()).unwrap_or_default()))
            .collect();
        // Disabled, when the page says so; the others are the browser's.
        if let Some(state) = chosen.get(STATE) {
            out.push((STATE.to_string(), state.clone()));
        }
        out
    }

    /// The component's layers with what `options` change laid over them,
    /// `when` taken off.
    pub fn with(&self, options: &[(String, String)]) -> Vec<Layer> {
        self.layers
            .iter()
            .map(|layer| {
                let mut out = layer.clone();
                for (prop, option) in options {
                    if let Some(over) = layer.when.get(&format!("{prop}={option}")) {
                        over.apply(&mut out);
                    }
                }
                out.when.clear();
                out
            })
            .collect()
    }

    /// The component as a page of one breakpoint, for laying out and for
    /// writing its CSS.
    pub fn as_page(&self, layers: Vec<Layer>) -> Page {
        Page { id: self.id.clone(), name: self.name.clone(), breakpoints: vec![], root: self.root.clone(), layers, ..Page::default() }
    }

    /// Why `instance`'s choices don't fit this component, if they don't.
    pub fn misfits(&self, instance: &Layer) -> Vec<String> {
        let mut out = Vec::new();
        for (prop, option) in &instance.props {
            if prop == STATE {
                if option != "disabled" {
                    out.push(format!("{} picks {prop}={option}: a page picks only disabled; the rest are how someone uses it", instance.id));
                } else if !self.states.iter().any(|s| s == "disabled") {
                    out.push(format!("{} picks disabled, which {} has no look for", instance.id, self.id));
                }
                continue;
            }
            match self.props.iter().find(|p| &p.name == prop) {
                None => out.push(format!("{} picks {prop}, which {} doesn't have", instance.id, self.id)),
                Some(p) if !p.options.contains(option) => out.push(format!("{} picks {prop}={option}, which {} doesn't have", instance.id, self.id)),
                Some(_) => {}
            }
        }
        for id in instance.texts.keys() {
            if self.layer(id).map(|l| l.kind) != Some(Kind::Text) {
                out.push(format!("{} gives words to {id}, which isn't one of {}'s text layers", instance.id, self.id));
            }
        }
        out
    }
}

impl proton_game::Document for Component {
    fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if !is_plain(&self.id) {
            out.push(format!("the component is called {:?}: an id is letters, digits, - and _", self.id));
        }
        out.extend(ids("prop", self.props.iter().map(|p| p.name.as_str())));
        if self.props.iter().any(|p| p.name == STATE) {
            out.push(format!("a prop can't be called {STATE}: states are the component's own"));
        }
        for state in &self.states {
            if !STATES.contains(&state.as_str()) {
                out.push(format!("{state:?} isn't a state: {}", STATES.join(", ")));
            }
        }
        if self.states.iter().collect::<BTreeSet<_>>().len() != self.states.len() {
            out.push("a state is listed twice".into());
        }
        for prop in &self.props {
            if prop.options.is_empty() {
                out.push(format!("{} has no options", prop.name));
            }
            out.extend(ids("option", prop.options.iter().map(String::as_str)).into_iter().map(|why| format!("{}: {why}", prop.name)));
        }
        out.extend(tree_problems("component", &self.root, &self.layers));
        for layer in &self.layers {
            if !layer.at.is_empty() {
                out.push(format!("{} says something at a breakpoint: a component takes its page's breakpoints from where it's placed", layer.id));
            }
            if layer.kind == Kind::Instance {
                out.push(format!("{} is an instance: a component doesn't hold other components yet", layer.id));
            }
            for (key, over) in &layer.when {
                let fits = key.split_once('=').is_some_and(|(prop, option)| match prop == STATE {
                    true => self.states.iter().any(|s| s == option),
                    false => self.props.iter().any(|p| p.name == prop && p.options.iter().any(|o| o == option)),
                });
                if !fits {
                    out.push(format!("{} says what {key} changes, which isn't one of the component's options", layer.id));
                } else {
                    let mut there = layer.clone();
                    over.apply(&mut there);
                    out.extend(layer_problems(&there).into_iter().map(|why| format!("when {key}, {why}")));
                }
            }
        }
        out.sort();
        out.dedup();
        out
    }
}

/// `page` with each instance expanded into its component's layers, as the
/// options it picks change them and with its words: the instance keeps its
/// id on the component's root, and the root's layers inside are
/// `<instance>.<layer>`. The instance's own sizes, place, breakpoint values
/// and tag are the root's. An instance of a component that isn't there
/// stays as it is, and draws nothing.
pub fn expand(page: &Page, components: &BTreeMap<String, Component>) -> Page {
    let mut layers = Vec::with_capacity(page.layers.len());
    for layer in &page.layers {
        let Some(component) = components.get(&layer.component).filter(|_| layer.kind == Kind::Instance) else {
            layers.push(layer.clone());
            continue;
        };
        let options = component.options(&layer.props);
        let name = |id: &str| match id == component.root {
            true => layer.id.clone(),
            false => format!("{}.{id}", layer.id),
        };
        for inner in component.with(&options) {
            let mut out = inner.clone();
            out.id = name(&inner.id);
            out.children = inner.children.iter().map(|c| name(c)).collect();
            out.component = component.id.clone();
            if let Some(words) = layer.texts.get(&inner.id) {
                out.text = words.clone();
            }
            if inner.id == component.root {
                // Where it sits and how big it is are the page's to say.
                out.name = layer.name.clone();
                if !layer.tag.is_empty() {
                    out.tag = layer.tag.clone();
                }
                if layer.w.is_some() {
                    out.w = layer.w.clone();
                }
                if layer.h.is_some() {
                    out.h = layer.h.clone();
                }
                if layer.min_w.is_some() {
                    out.min_w = layer.min_w;
                }
                out.hidden = layer.hidden;
                out.at = layer.at.clone();
                out.props = options.iter().cloned().collect();
            }
            layers.push(out);
        }
    }
    Page { layers, ..page.clone() }
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
    /// A plain shape: a rule, a swatch, a placeholder.
    Rect,
    /// A picture from the design's `images/`.
    Image,
    /// A component placed on a page.
    Instance,
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
    /// An image's file, in the design's folder: `images/key-art.png`.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub src: String,
    /// Not drawn, and taking no room.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
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
    /// What a narrower breakpoint says otherwise, by its id.
    pub at: BTreeMap<String, Override>,
    /// In a component: what an option of a prop changes, by `prop=option`.
    pub when: BTreeMap<String, Override>,
    /// An instance's component, by id. Kept on the layers an instance is
    /// expanded into, to name their CSS classes.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub component: String,
    /// An instance's option of each prop it doesn't leave at the default.
    pub props: BTreeMap<String, String>,
    /// An instance's words for the component's text layers, by their id.
    pub texts: BTreeMap<String, String>,
}

/// What a breakpoint says of a layer where it differs: each field said
/// replaces the layer's, each unsaid is the wider breakpoint's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Override {
    pub w: Option<Val>,
    pub h: Option<Val>,
    pub min_w: Option<f64>,
    pub hidden: Option<bool>,
    pub layout: Layout,
    pub style: Style,
}

impl Override {
    /// `self` laid over `layer`.
    pub fn apply(&self, layer: &mut Layer) {
        fn over<T: Clone>(to: &mut Option<T>, from: &Option<T>) {
            if from.is_some() {
                *to = from.clone();
            }
        }
        over(&mut layer.w, &self.w);
        over(&mut layer.h, &self.h);
        over(&mut layer.min_w, &self.min_w);
        if let Some(hidden) = self.hidden {
            layer.hidden = hidden;
        }
        let (l, o) = (&mut layer.layout, &self.layout);
        over(&mut l.direction, &o.direction);
        over(&mut l.gap, &o.gap);
        over(&mut l.pad_h, &o.pad_h);
        over(&mut l.pad_v, &o.pad_v);
        over(&mut l.align, &o.align);
        over(&mut l.justify, &o.justify);
        over(&mut l.wrap, &o.wrap);
        let (s, o) = (&mut layer.style, &self.style);
        over(&mut s.fill, &o.fill);
        over(&mut s.stroke, &o.stroke);
        over(&mut s.radius, &o.radius);
        over(&mut s.color, &o.color);
        over(&mut s.font, &o.font);
        over(&mut s.text_align, &o.text_align);
        over(&mut s.opacity, &o.opacity);
        over(&mut s.fit, &o.fit);
    }
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
    /// How a picture fills its layer: `cover` (cropped) or `contain`
    /// (letterboxed). Unsaid: `cover`.
    pub fit: Option<String>,
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

/// Whether `src` is a picture in the design's `images/`: plain parts only,
/// and nothing that could end the HTML attribute it is written into.
pub fn is_image_path(src: &str) -> bool {
    let Some(name) = src.strip_prefix("images/") else { return false };
    let kind = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    !name.is_empty()
        && ["png", "jpg", "jpeg", "webp", "gif"].contains(&kind.as_str())
        && name.split('/').all(|part| !part.is_empty() && part != "." && part != "..")
        && !src.contains(['"', '\'', '<', '>', '\\', '\0', '?', '#'])
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

/// A tree of layers' problems: ids, one root frame, each layer in one
/// frame and every one reached, and each layer's own. `what` is "page" or
/// "component", for the words.
fn tree_problems(what: &str, root_id: &str, layers: &[Layer]) -> Vec<String> {
    let mut out = ids("layer", layers.iter().map(|l| l.id.as_str()));
    let find = |id: &str| layers.iter().find(|l| l.id == id);
    let known: BTreeSet<&str> = layers.iter().map(|l| l.id.as_str()).collect();
    match find(root_id) {
        None => out.push(format!("the {what}'s root, {root_id:?}, is not one of its layers")),
        Some(root) if root.kind != Kind::Frame => out.push(format!("the {what}'s root, {}, is not a frame", root.id)),
        Some(_) => {}
    }

    // Each layer in one frame only, every one but the root in some frame.
    let mut parents: BTreeMap<&str, &str> = BTreeMap::new();
    for layer in layers {
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
    if let Some(holder) = parents.get(root_id) {
        out.push(format!("the {what}'s root is inside {holder}"));
    }
    // Reached from the root, or lost: a layer outside the tree, or a loop of
    // frames inside each other, is drawn nowhere.
    let reached: BTreeSet<&str> = subtree(layers, root_id).iter().map(|l| l.id.as_str()).collect();
    for layer in layers {
        if !reached.contains(layer.id.as_str()) && layer.id != root_id && known.contains(layer.id.as_str()) {
            out.push(format!("{} is in no frame of the {what}", layer.id));
        }
    }
    for layer in layers {
        out.extend(layer_problems(layer));
    }
    out
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
        out.extend(tree_problems("page", &self.root, &self.layers));
        for layer in &self.layers {
            if !layer.when.is_empty() {
                out.push(format!("{} says what a prop's option changes, which only a component's layers do", layer.id));
            }
        }

        // What a breakpoint says is checked as the layer it makes there.
        let points = self.widest_first();
        let widest = points.first().map(|b| b.id.as_str());
        for layer in &self.layers {
            for (point, over) in &layer.at {
                if !points.iter().any(|b| &b.id == point) {
                    out.push(format!("{} says something at {point}, which isn't one of the page's breakpoints", layer.id));
                } else if Some(point.as_str()) == widest {
                    out.push(format!("{} says something at {point}, the page's widest: there, a layer is what its own fields say", layer.id));
                } else {
                    let mut there = layer.clone();
                    over.apply(&mut there);
                    out.extend(layer_problems(&there).into_iter().map(|why| format!("at {point}, {why}")));
                }
            }
        }
        out.sort();
        out.dedup();
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
    if let Some(fit) = &layer.style.fit {
        if fit != "cover" && fit != "contain" {
            out.push(format!("{id}'s fit is {fit:?}: cover or contain"));
        }
    }
    match layer.kind {
        Kind::Instance if !is_plain(&layer.component) => {
            out.push(format!("{id} is an instance of {:?}, which isn't a component's id", layer.component));
        }
        Kind::Instance => {}
        _ if !layer.props.is_empty() || !layer.texts.is_empty() || !layer.component.is_empty() => {
            out.push(format!("{id} picks a component's options but isn't an instance"));
        }
        _ => {}
    }
    match layer.kind {
        Kind::Image if !is_image_path(&layer.src) => {
            out.push(format!("{id}'s picture is {:?}: a file in the design's images/", layer.src));
        }
        Kind::Image => {}
        _ if !layer.src.is_empty() => out.push(format!("{id} names a picture but isn't an image")),
        _ => {}
    }
    if layer.min_w.is_some_and(|n| !(n.is_finite() && n >= 0.0)) {
        out.push(format!("{id}'s narrowest is not a width"));
    }
    out
}
