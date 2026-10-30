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

pub mod format;
pub mod html;
pub mod starter;
pub mod theme;

use std::path::{Path, PathBuf};

use proton_game::{Doc, Op};

use format::{is_plain, DesignFile, Page};
use theme::ThemeDoc;

/// The design's own file, in its folder.
pub const DESIGN: &str = "design.json";
/// The palette, in its folder.
pub const THEME: &str = "theme.css";

/// Where page `id` is written, in the design's folder.
pub fn page_rel(id: &str) -> String {
    format!("pages/{id}.page.json")
}

/// One of a design's documents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Design,
    Theme,
    Page(String),
}

impl Target {
    /// `design`, `theme` or `page:<id>`.
    pub fn parse(text: &str) -> Option<Target> {
        match text {
            "design" => Some(Target::Design),
            "theme" => Some(Target::Theme),
            _ => text.strip_prefix("page:").map(|id| Target::Page(id.to_string())),
        }
    }
}

/// A design open for editing.
pub struct Design {
    root: PathBuf,
    pub design: Doc<DesignFile>,
    pub pages: Vec<Doc<Page>>,
    pub theme: ThemeDoc,
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
        Ok(Design { root: root.to_path_buf(), design, pages, theme: ThemeDoc::read(root)? })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn page(&self, id: &str) -> Option<&Doc<Page>> {
        self.pages.iter().find(|page| page.get().id == id)
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
                let page = self.page_mut(id)?;
                let mut trial = page.clone();
                let changed = trial.apply(ops)?;
                if trial.get().id != page.get().id {
                    return Err("a page's id is its file's name, and doesn't change".into());
                }
                *page = trial;
                Ok(changed)
            }
            Target::Theme => Err("the theme is changed a token at a time".into()),
        }
    }

    /// One token's value, found by name and scope, as one step.
    pub fn set_token(&mut self, name: &str, scope: &str, value: &str) -> Result<bool, String> {
        self.theme.set(name, scope, value)
    }

    pub fn undo(&mut self, target: &Target) -> Result<bool, String> {
        Ok(match target {
            Target::Design => self.design.undo(),
            Target::Theme => self.theme.undo(),
            Target::Page(id) => self.page_mut(id)?.undo(),
        })
    }

    pub fn redo(&mut self, target: &Target) -> Result<bool, String> {
        Ok(match target {
            Target::Design => self.design.redo(),
            Target::Theme => self.theme.redo(),
            Target::Page(id) => self.page_mut(id)?.redo(),
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
        Ok(written)
    }

    /// Tokens the pages use that the theme doesn't have, as `page: token`.
    pub fn problems(&self) -> Vec<String> {
        let known: std::collections::BTreeSet<&str> = self.theme.tokens().iter().map(|t| t.name.as_str()).collect();
        let mut out = Vec::new();
        for page in &self.pages {
            let mut missing = std::collections::BTreeSet::new();
            for layer in &page.get().layers {
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
                out.push(format!("{} uses {token}, which {THEME} doesn't have", page.get().name));
            }
        }
        out
    }
}
