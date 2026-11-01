//! A new design's files: a landing page and its palette, the Design board's.
//!
//! Lumen's home page, as the design canvas draws it: a nav, a hero with its
//! eyebrow, title, body and two actions, and three feature cards in a row
//! that wraps on a phone. Everything is set in tokens, so the first thing a
//! new design shows is the binding: change `--color-lantern-500` and every
//! layer that uses it follows. On the phone the title is set smaller and the
//! hero's padding is less, as the Mobile breakpoint says. Its two buttons are
//! instances of one component, `button`, a primary and a secondary, which
//! dims as it's hovered and pressed, and most when it's disabled. What nobody has
//! decided yet — the platforms, the release window — is a placeholder, not
//! an invented fact.

use std::path::Path;

use std::collections::BTreeMap;

use crate::format::{Breakpoint, Component, DesignFile, Kind, Layer, Layout, Override, Page, Prop, Style, Val};

/// One file: where it goes in the design's folder, and its text.
pub struct File {
    pub rel: String,
    pub text: String,
}

const THEME: &str = "/* The palette. Layers use these tokens; change one here and every layer
   that uses it follows. */
:root {
  --color-ground: #0f1412;
  --color-surface: #18201c;
  --color-line: #34403a;
  --color-ink: #f2efe6;
  --color-ink-muted: #a9b0a8;
  --color-lantern-500: #f2b84b;
  --color-lantern-ink: #1d1406;

  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-6: 24px;
  --space-8: 32px;
  --space-12: 48px;
  --space-16: 64px;

  --radius-md: 12px;
  --radius-full: 999px;

  --type-display: 700 56px/1.05 system-ui, sans-serif;
  --type-display-sm: 700 38px/1.1 system-ui, sans-serif;
  --type-title: 600 22px/1.25 system-ui, sans-serif;
  --type-body: 400 17px/1.5 system-ui, sans-serif;
  --type-label-md: 600 15px/1 system-ui, sans-serif;
  --type-eyebrow: 600 13px/1 system-ui, sans-serif;
}

/* By day: the same page on paper. */
@media (prefers-color-scheme: light) {
  :root {
    --color-ground: #f6f1e4;
    --color-surface: #ebe3d0;
    --color-line: #cfc3a8;
    --color-ink: #1f1b14;
    --color-ink-muted: #5c5546;
    /* Deep enough to read on paper; the buttons' words light on it. */
    --color-lantern-500: #9a5b06;
    --color-lantern-ink: #fffaf0;
  }
}
";

/// The files of a new design called `name`.
pub fn files(name: &str) -> Vec<File> {
    let design = DesignFile { name: name.to_string(), pages: vec!["home".into()], ..DesignFile::default() };
    vec![
        File { rel: crate::DESIGN.into(), text: proton_game::doc::to_text(&design) },
        File { rel: crate::THEME.into(), text: THEME.into() },
        File { rel: crate::page_rel("home"), text: proton_game::doc::to_text(&home()) },
        File { rel: crate::component_rel("button"), text: proton_game::doc::to_text(&button()) },
    ]
}

/// Write them into `root`, refusing a folder that already holds a design.
pub fn write(root: &Path, files: &[File]) -> Result<(), String> {
    if root.join(crate::DESIGN).exists() {
        return Err(format!("{} already holds a design", root.display()));
    }
    for file in files {
        proton_game::doc::write_atomically(&root.join(&file.rel), file.text.as_bytes()).map_err(|e| format!("{}: {e}", file.rel))?;
    }
    Ok(())
}

impl Layer {
    /// What breakpoint `id` says otherwise.
    fn on(mut self, id: &str, over: Override) -> Layer {
        self.at.insert(id.into(), over);
        self
    }
}

fn token(name: &str) -> Option<Val> {
    Some(Val::Text(name.into()))
}

fn frame(id: &str, name: &str, children: &[&str], layout: Layout, style: Style) -> Layer {
    Layer {
        id: id.into(),
        kind: Kind::Frame,
        name: name.into(),
        children: children.iter().map(|c| c.to_string()).collect(),
        layout,
        style,
        ..Layer::default()
    }
}

fn text(id: &str, name: &str, words: &str, font: &str, color: &str) -> Layer {
    Layer {
        id: id.into(),
        kind: Kind::Text,
        name: name.into(),
        text: words.into(),
        style: Style { font: Some(font.into()), color: Some(color.into()), ..Style::default() },
        ..Layer::default()
    }
}

fn row(gap: &str) -> Layout {
    Layout { direction: Some("row".into()), gap: token(gap), align: Some("center".into()), ..Layout::default() }
}

/// The board's ui/Button: a pill of a label, filled with the lantern's
/// colour, or outlined as the secondary.
fn button() -> Component {
    let secondary = |style: Style| BTreeMap::from([("variant=secondary".to_string(), Override { style, ..Override::default() })]);
    let dims = |key: &str, opacity: f64| (key.to_string(), Override { style: Style { opacity: Some(opacity), ..Style::default() }, ..Override::default() });
    Component {
        id: "button".into(),
        name: "Button".into(),
        props: vec![Prop { name: "variant".into(), options: vec!["primary".into(), "secondary".into()] }],
        states: vec!["hover".into(), "pressed".into(), "disabled".into()],
        root: "button".into(),
        layers: vec![
            Layer {
                when: {
                    let mut when = secondary(Style { fill: Some("transparent".into()), stroke: Some("--color-line".into()), ..Style::default() });
                    when.extend([dims("state=hover", 0.85), dims("state=pressed", 0.7), dims("state=disabled", 0.4)]);
                    when
                },
                ..frame(
                    "button",
                    "Button",
                    &["label"],
                    Layout { direction: Some("row".into()), pad_h: Some(Val::Num(20.0)), pad_v: Some(Val::Num(12.0)), align: Some("center".into()), ..Layout::default() },
                    Style { fill: Some("--color-lantern-500".into()), radius: token("--radius-full"), ..Style::default() },
                )
            },
            Layer {
                when: secondary(Style { color: Some("--color-ink".into()), ..Style::default() }),
                ..text("label", "Label", "Button", "--type-label-md", "--color-lantern-ink")
            },
        ],
        ..Component::default()
    }
}

/// A button on the page: an instance of `button`, its words and its variant.
fn button_on(id: &str, name: &str, words: &str, variant: &str) -> Layer {
    Layer {
        id: id.into(),
        kind: Kind::Instance,
        name: name.into(),
        tag: "a".into(),
        w: Some(Val::Text("hug".into())),
        component: "button".into(),
        props: match variant {
            "primary" => BTreeMap::new(),
            other => BTreeMap::from([("variant".to_string(), other.to_string())]),
        },
        texts: BTreeMap::from([("label".to_string(), words.to_string())]),
        ..Layer::default()
    }
}

fn feature(id: &str, title: &str, body: &str) -> [Layer; 3] {
    [
        Layer {
            min_w: Some(240.0),
            ..frame(
                id,
                title,
                &[&format!("{id}-title"), &format!("{id}-body")],
                Layout { gap: token("--space-3"), pad_h: token("--space-6"), pad_v: token("--space-6"), ..Layout::default() },
                Style { fill: Some("--color-surface".into()), radius: token("--radius-md"), ..Style::default() },
            )
        },
        Layer { tag: "h3".into(), ..text(&format!("{id}-title"), "Title", title, "--type-title", "--color-ink") },
        Layer { w: Some(Val::Text("fill".into())), ..text(&format!("{id}-body"), "Body", body, "--type-body", "--color-ink-muted") },
    ]
}

fn home() -> Page {
    let mut layers = vec![
        frame("page", "Home", &["nav", "hero", "features"], Layout::default(), Style { fill: Some("--color-ground".into()), ..Style::default() }),
        Layer {
            tag: "nav".into(),
            ..frame(
                "nav",
                "Nav",
                &["logo", "links"],
                Layout { pad_h: token("--space-8"), pad_v: token("--space-4"), justify: Some("between".into()), ..row("--space-6") },
                Style::default(),
            )
        },
        text("logo", "Logo", "LUMEN", "--type-label-md", "--color-ink"),
        Layer { w: Some(Val::Text("hug".into())), ..frame("links", "Links", &["story", "world", "press"], row("--space-6"), Style::default()) },
        Layer { tag: "a".into(), ..text("story", "Story", "Story", "--type-label-md", "--color-ink-muted") },
        Layer { tag: "a".into(), ..text("world", "World", "World", "--type-label-md", "--color-ink-muted") },
        Layer { tag: "a".into(), ..text("press", "Press kit", "Press kit", "--type-label-md", "--color-ink-muted") },
        Layer {
            tag: "header".into(),
            ..frame(
                "hero",
                "Hero",
                &["eyebrow", "title", "body", "actions", "availability"],
                Layout { gap: token("--space-6"), pad_h: token("--space-8"), pad_v: token("--space-16"), ..Layout::default() },
                Style::default(),
            )
        }
        .on("mobile", Override { layout: Layout { pad_v: token("--space-12"), ..Layout::default() }, ..Override::default() }),
        text("eyebrow", "Eyebrow", "A hand-painted adventure", "--type-eyebrow", "--color-lantern-500"),
        Layer { tag: "h1".into(), w: Some(Val::Text("fill".into())), ..text("title", "Title", "Carry the light through the Hollow Grove.", "--type-display", "--color-ink") }
            .on("mobile", Override { style: Style { font: Some("--type-display-sm".into()), ..Style::default() }, ..Override::default() }),
        Layer {
            w: Some(Val::Text("fill".into())),
            ..text(
                "body",
                "Body",
                "Wren has one lantern and a forest that remembers. Light the way, outwit the moths, and find what the dark is keeping.",
                "--type-body",
                "--color-ink-muted",
            )
        },
        Layer { w: Some(Val::Text("hug".into())), ..frame("actions", "Actions", &["wishlist", "trailer"], row("--space-2"), Style::default()) },
        button_on("wishlist", "Wishlist CTA", "Wishlist now", "primary"),
        button_on("trailer", "Watch the trailer", "Watch the trailer", "secondary"),
        text("availability", "Availability", "Coming to Mac · [PLATFORMS] · [RELEASE WINDOW]", "--type-eyebrow", "--color-ink-muted"),
        Layer {
            tag: "section".into(),
            ..frame(
                "features",
                "Features",
                &["lantern", "painted", "remembers"],
                Layout { direction: Some("row".into()), gap: token("--space-6"), pad_h: token("--space-8"), pad_v: token("--space-12"), wrap: Some(true), ..Layout::default() },
                Style::default(),
            )
        },
    ];
    layers.extend(feature("lantern", "A lantern that matters", "Its light opens paths, wakes shrines and keeps the moths at bay."));
    layers.extend(feature("painted", "Painted by hand", "Every plane of the Hollow Grove is painted, then lit in real time."));
    layers.extend(feature("remembers", "A forest that remembers", "Paths you light stay lit. The grove changes with every return."));
    Page {
        id: "home".into(),
        name: "Home".into(),
        breakpoints: vec![
            Breakpoint { id: "desktop".into(), name: "Desktop".into(), width: 1280.0 },
            Breakpoint { id: "mobile".into(), name: "Mobile".into(), width: 390.0 },
        ],
        root: "page".into(),
        layers,
        ..Page::default()
    }
}
