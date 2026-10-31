//! Design's document: a design's folder, open for editing.
//!
//! Proton's Design mode edited two files, a component's `.html` and a
//! `theme.css` of tokens, and drew the component in a web view. Aether has no
//! web view, and an HTML file is only drawn faithfully by a browser, so a
//! design's pages are Aether's own: trees of frames, text and shapes laid out
//! as flexbox lays them out ([`format`]), drawn natively, and written out as
//! HTML and CSS ([`html`]) for the code drawer and for a browser. The tokens
//! stay Proton's: `theme.css` is read and spliced by `proton-design`, so the
//! same palette file serves both apps and a token edit moves one value.
//!
//! ## One undo, two kinds of file
//!
//! A page is a JSON document edited by Game's ops (`proton-game`'s [`Doc`]:
//! a batch applied whole or not at all, then checked, each document with its
//! own undo). The theme is text, edited by splicing, with its own undo of the
//! texts each step left ([`theme::ThemeDoc`]). Each is a [`Target`]; the
//! workspace keeps the order steps were made in, so ⌘Z undoes the newest
//! wherever it was, as in Game. Nothing is written until ⌘S.
//!
//! ## Components
//!
//! A design's components are the files in `components/`, each a document
//! with its own undo. A page's instances are checked against them, and a
//! component's edit against every page that places it: an option an
//! instance picks can't be taken away under it. Making a component from a
//! page's frame is one step of its own ([`Target::Made`]): the page's
//! change and the component's new file, undone together.

pub mod format;
pub mod html;
pub mod starter;
pub mod theme;

use std::path::{Path, PathBuf};

use proton_game::{Doc, Op};

use std::collections::BTreeMap;

use format::{is_plain, Component, DesignFile, Kind, Layer, Page};
use theme::ThemeDoc;

/// The design's own file, in its folder.
pub const DESIGN: &str = "design.json";
/// The palette, in its folder.
pub const THEME: &str = "theme.css";

/// Where page `id` is written, in the design's folder.
pub fn page_rel(id: &str) -> String {
    format!("pages/{id}.page.json")
}

/// Where component `id` is written, in the design's folder.
pub fn component_rel(id: &str) -> String {
    format!("components/{id}.component.json")
}

/// One of a design's documents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Design,
    Theme,
    Page(String),
    Component(String),
    /// A component made from a page's frame: the page's step and the
    /// component's being, together.
    Made { component: String, page: String },
}

impl Target {
    /// `design`, `theme` or `page:<id>`.
    pub fn parse(text: &str) -> Option<Target> {
        match text {
            "design" => Some(Target::Design),
            "theme" => Some(Target::Theme),
            _ => {
                if let Some(id) = text.strip_prefix("page:") {
                    return Some(Target::Page(id.to_string()));
                }
                if let Some(id) = text.strip_prefix("component:") {
                    return Some(Target::Component(id.to_string()));
                }
                let (component, page) = text.strip_prefix("made:")?.split_once('/')?;
                Some(Target::Made { component: component.to_string(), page: page.to_string() })
            }
        }
    }
}

/// A design open for editing.
pub struct Design {
    root: PathBuf,
    pub design: Doc<DesignFile>,
    pub pages: Vec<Doc<Page>>,
    pub components: Vec<Doc<Component>>,
    pub theme: ThemeDoc,
    /// Components made and then undone, for redo.
    unmade: Vec<Doc<Component>>,
    /// Component files to take away on the next save: made, saved, then
    /// undone.
    deleted: Vec<String>,
}

impl Design {
    /// Whether `dir` holds a design.
    pub fn is_design(dir: &Path) -> bool {
        dir.join(DESIGN).is_file()
    }

    /// The design in `root`: its file, every page it lists, and its theme.
    pub fn open(root: &Path) -> Result<Design, String> {
        let design: Doc<DesignFile> = Doc::read(root, DESIGN)?;
        let mut pages = Vec::new();
        for id in &design.get().pages {
            // Checked before it is joined to the folder: a page's id is a
            // file name.
            if !is_plain(id) {
                return Err(format!("{DESIGN} lists a page called {id:?}"));
            }
            let page: Doc<Page> = Doc::read(root, &page_rel(id))?;
            if page.get().id != *id {
                return Err(format!("{} says it is {:?}", page_rel(id), page.get().id));
            }
            pages.push(page);
        }
        let mut components = Vec::new();
        let mut names: Vec<String> = std::fs::read_dir(root.join("components"))
            .map(|dir| dir.flatten().filter_map(|e| e.file_name().to_str()?.strip_suffix(".component.json").map(str::to_string)).collect())
            .unwrap_or_default();
        names.sort();
        for id in names.into_iter().filter(|id| is_plain(id)) {
            let component: Doc<Component> = Doc::read(root, &component_rel(&id))?;
            if component.get().id != id {
                return Err(format!("{} says it is {:?}", component_rel(&id), component.get().id));
            }
            components.push(component);
        }
        Ok(Design { root: root.to_path_buf(), design, pages, components, theme: ThemeDoc::read(root)?, unmade: Vec::new(), deleted: Vec::new() })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn page(&self, id: &str) -> Option<&Doc<Page>> {
        self.pages.iter().find(|page| page.get().id == id)
    }

    pub fn component(&self, id: &str) -> Option<&Doc<Component>> {
        self.components.iter().find(|c| c.get().id == id)
    }

    /// Every component, by id, as it is now.
    pub fn component_map(&self) -> BTreeMap<String, Component> {
        self.components.iter().map(|c| (c.get().id.clone(), c.get().clone())).collect()
    }

    /// `page` with its instances expanded.
    pub fn expanded(&self, page: &str) -> Option<Page> {
        Some(format::expand(self.page(page)?.get(), &self.component_map()))
    }

    /// Where each component is placed: `(page, instance)`, by component.
    pub fn uses(&self) -> BTreeMap<String, Vec<(String, String)>> {
        let mut out: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for page in &self.pages {
            for layer in page.get().layers.iter().filter(|l| l.kind == Kind::Instance) {
                out.entry(layer.component.clone()).or_default().push((page.get().id.clone(), layer.id.clone()));
            }
        }
        out
    }

    /// Why `page`'s instances don't fit `components`.
    fn instance_problems(page: &Page, components: &BTreeMap<String, Component>) -> Vec<String> {
        let mut out = Vec::new();
        for layer in page.layers.iter().filter(|l| l.kind == Kind::Instance) {
            match components.get(&layer.component) {
                None => out.push(format!("{} places {}, which isn't one of the design's components", layer.id, layer.component)),
                Some(c) => out.extend(c.misfits(layer).into_iter().map(|why| format!("on {}, {why}", page.name))),
            }
        }
        out
    }

    fn page_mut(&mut self, id: &str) -> Result<&mut Doc<Page>, String> {
        self.pages.iter_mut().find(|page| page.get().id == id).ok_or_else(|| format!("there is no page {id}"))
    }

    /// A batch of ops on the design or a page, whole or not at all. The
    /// theme takes [`set_token`](Self::set_token) instead: it is text.
    pub fn apply(&mut self, target: &Target, ops: &[Op]) -> Result<bool, String> {
        match target {
            Target::Design => {
                // Tried on a copy, so a refusal leaves the history alone.
                let mut trial = self.design.clone();
                let changed = trial.apply(ops)?;
                // A page is added or taken away by its own file, not by
                // editing the list; the list may only be reordered here.
                let mut now = trial.get().pages.clone();
                let mut before = self.design.get().pages.clone();
                now.sort();
                before.sort();
                if now != before {
                    return Err("pages are added and removed as files, not in design.json's list".into());
                }
                self.design = trial;
                Ok(changed)
            }
            Target::Page(id) => {
                let components = self.component_map();
                let page = self.page_mut(id)?;
                let mut trial = page.clone();
                let changed = trial.apply(ops)?;
                if trial.get().id != page.get().id {
                    return Err("a page's id is its file's name, and doesn't change".into());
                }
                let misfits = Self::instance_problems(trial.get(), &components);
                if changed && !misfits.is_empty() {
                    return Err(misfits.join("; "));
                }
                *page = trial;
                Ok(changed)
            }
            Target::Component(id) => {
                let mut components = self.component_map();
                let doc = self.components.iter().find(|c| c.get().id == *id).ok_or_else(|| format!("there is no component {id}"))?;
                let mut trial = doc.clone();
                let changed = trial.apply(ops)?;
                if trial.get().id != *id {
                    return Err("a component's id is its file's name, and doesn't change".into());
                }
                // An option an instance picks can't go out from under it.
                components.insert(id.clone(), trial.get().clone());
                let misfits: Vec<String> = self.pages.iter().flat_map(|p| Self::instance_problems(p.get(), &components)).collect();
                if !misfits.is_empty() {
                    return Err(misfits.join("; "));
                }
                *self.components.iter_mut().find(|c| c.get().id == *id).unwrap() = trial;
                Ok(changed)
            }
            Target::Theme => Err("the theme is changed a token at a time".into()),
            Target::Made { .. } => Err("a component is made from a frame, not by ops".into()),
        }
    }

    /// One token's value, found by name and scope, as one step.
    pub fn set_token(&mut self, name: &str, scope: &str, value: &str) -> Result<bool, String> {
        self.theme.set(name, scope, value)
    }

    /// Component `id` made from frame `layer` of page `page`, called `name`:
    /// the frame and what's in it become the component, and an instance of
    /// it takes the frame's place, with its id, its sizes and its place.
    /// What breakpoints said of the layers inside stays with the page's
    /// breakpoints no longer — a component has no breakpoints of its own.
    pub fn make_component(&mut self, page: &str, layer: &str, id: &str, name: &str) -> Result<(), String> {
        if !is_plain(id) {
            return Err(format!("{id:?} can't be a component's id: letters, digits, - and _, starting with a letter"));
        }
        if self.component(id).is_some() {
            return Err(format!("there is already a component called {id}"));
        }
        let doc = self.page(page).ok_or_else(|| format!("there is no page {page}"))?;
        let p = doc.get();
        let frame = p.layer(layer).ok_or_else(|| format!("there is no {layer}"))?;
        if frame.kind != Kind::Frame {
            return Err(format!("{} isn't a frame", frame.label()));
        }
        if layer == p.root {
            return Err("the page's own frame can't be a component".into());
        }
        let inside: Vec<Layer> = p.subtree(layer).into_iter().cloned().collect();
        if inside.iter().any(|l| l.kind == Kind::Instance) {
            return Err(format!("{} holds an instance: a component doesn't hold other components yet", frame.label()));
        }
        let component = Component {
            id: id.to_string(),
            name: name.to_string(),
            root: layer.to_string(),
            layers: inside.iter().cloned().map(|mut l| {
                l.at.clear();
                if l.id == layer {
                    // Where it sits is the instance's to say.
                    l.w = None;
                    l.h = None;
                    l.min_w = None;
                    l.hidden = false;
                }
                l
            }).collect(),
            ..Component::default()
        };
        let problems = proton_game::Document::problems(&component);
        if !problems.is_empty() {
            return Err(problems.join("; "));
        }
        let instance = Layer {
            id: frame.id.clone(),
            kind: Kind::Instance,
            name: frame.name.clone(),
            tag: frame.tag.clone(),
            w: frame.w.clone(),
            h: frame.h.clone(),
            min_w: frame.min_w,
            hidden: frame.hidden,
            at: frame.at.clone(),
            component: id.to_string(),
            ..Layer::default()
        };
        let gone: Vec<&str> = inside.iter().map(|l| l.id.as_str()).collect();
        let mut next = p.clone();
        next.layers = p.layers.iter().filter_map(|l| match l.id.as_str() {
            id if id == layer => Some(instance.clone()),
            id if gone.contains(&id) => None,
            _ => Some(l.clone()),
        }).collect();
        let problems = proton_game::Document::problems(&next);
        if !problems.is_empty() {
            return Err(problems.join("; "));
        }
        let rel = component_rel(id);
        self.deleted.retain(|d| d != &rel);
        self.unmade.retain(|c| c.get().id != id);
        self.components.push(Doc::fresh(&rel, component));
        self.components.sort_by(|a, b| a.get().id.cmp(&b.get().id));
        self.page_mut(page)?.replace(next);
        Ok(())
    }

    pub fn undo(&mut self, target: &Target) -> Result<bool, String> {
        Ok(match target {
            Target::Design => self.design.undo(),
            Target::Theme => self.theme.undo(),
            Target::Page(id) => self.page_mut(id)?.undo(),
            Target::Component(id) => self.components.iter_mut().find(|c| c.get().id == *id).ok_or_else(|| format!("there is no component {id}"))?.undo(),
            Target::Made { component, page } => {
                let Some(place) = self.components.iter().position(|c| &c.get().id == component) else { return Ok(false) };
                if !self.page_mut(page)?.undo() {
                    return Ok(false);
                }
                let gone = self.components.remove(place);
                self.deleted.push(gone.rel().to_string());
                self.unmade.push(gone);
                true
            }
        })
    }

    pub fn redo(&mut self, target: &Target) -> Result<bool, String> {
        Ok(match target {
            Target::Design => self.design.redo(),
            Target::Theme => self.theme.redo(),
            Target::Page(id) => self.page_mut(id)?.redo(),
            Target::Component(id) => self.components.iter_mut().find(|c| c.get().id == *id).ok_or_else(|| format!("there is no component {id}"))?.redo(),
            Target::Made { component, page } => {
                let Some(place) = self.unmade.iter().position(|c| &c.get().id == component) else { return Ok(false) };
                if !self.page_mut(page)?.redo() {
                    return Ok(false);
                }
                let back = self.unmade.remove(place);
                self.deleted.retain(|d| d != back.rel());
                self.components.push(back);
                self.components.sort_by(|a, b| a.get().id.cmp(&b.get().id));
                true
            }
        })
    }

    /// The files changed and not saved, relative to the folder.
    pub fn unsaved_files(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.design.is_dirty() {
            out.push(DESIGN.to_string());
        }
        if self.theme.is_dirty() {
            out.push(THEME.to_string());
        }
        out.extend(self.pages.iter().filter(|p| p.is_dirty()).map(|p| p.rel().to_string()));
        out.extend(self.components.iter().filter(|c| c.is_dirty()).map(|c| c.rel().to_string()));
        out.extend(self.deleted.iter().filter(|rel| self.root.join(rel).exists()).cloned());
        out
    }

    /// Write every changed file; the files written.
    pub fn save(&mut self) -> Result<Vec<String>, String> {
        let written = self.unsaved_files();
        if self.design.is_dirty() {
            self.design.save(&self.root)?;
        }
        if self.theme.is_dirty() {
            self.theme.save(&self.root)?;
        }
        for page in self.pages.iter_mut().filter(|p| p.is_dirty()) {
            page.save(&self.root)?;
        }
        for component in self.components.iter_mut().filter(|c| c.is_dirty()) {
            component.save(&self.root)?;
        }
        for rel in std::mem::take(&mut self.deleted) {
            let file = self.root.join(&rel);
            if file.exists() {
                std::fs::remove_file(&file).map_err(|e| format!("{rel}: {e}"))?;
            }
        }
        Ok(written)
    }

    /// Tokens the pages use that the theme doesn't have, as `page: token`.
    pub fn problems(&self) -> Vec<String> {
        let known: std::collections::BTreeSet<&str> = self.theme.tokens().iter().map(|t| t.name.as_str()).collect();
        let mut out = Vec::new();
        let components = self.component_map();
        let trees = self.pages.iter().map(|p| (p.get().name.clone(), p.get().layers.clone()))
            .chain(self.components.iter().map(|c| (c.get().name.clone(), c.get().layers.clone())));
        for page in &self.pages {
            out.extend(Self::instance_problems(page.get(), &components));
        }
        for (name, layers) in trees {
            let mut missing = std::collections::BTreeSet::new();
            let overrides: Vec<Layer> = layers.iter().flat_map(|l| l.when.values().chain(l.at.values()).map(|o| {
                let mut there = l.clone();
                o.apply(&mut there);
                there
            })).collect();
            for layer in layers.iter().chain(overrides.iter()) {
                let style = &layer.style;
                let lay = &layer.layout;
                let words = [&style.fill, &style.stroke, &style.color, &style.font].into_iter().flatten().map(String::as_str);
                let lengths = [&lay.gap, &lay.pad_h, &lay.pad_v, &style.radius].into_iter().flatten().filter_map(format::Val::word);
                for word in words.chain(lengths) {
                    if word.starts_with("--") && !known.contains(word) {
                        missing.insert(word.to_string());
                    }
                }
            }
            for token in missing {
                out.push(format!("{name} uses {token}, which {THEME} doesn't have"));
            }
        }
        out
    }
}
