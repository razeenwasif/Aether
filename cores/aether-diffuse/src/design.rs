//! Design, for Swift: a design's folder open for editing (`aether-design`'s
//! `Design`: its pages changed by Game's ops and its theme's tokens spliced,
//! each document with its own undo, held until saved), its components and
//! their instances expanded, and the HTML and CSS a page is written as.

use std::path::Path;
use std::sync::{Arc, Mutex};

use aether_design::{html, starter, Design, Target};
use proton_game::Op;

use crate::{failed, json, lock, DiffuseError};

/// The designs in `folder`: each folder in it (or it itself) holding a
/// `design.json`. JSON: a list of `{path, name, pages}`, by name.
#[uniffi::export]
pub fn design_found(folder: String) -> String {
    let root = Path::new(&folder);
    let mut dirs = vec![root.to_path_buf()];
    if let Ok(entries) = std::fs::read_dir(root) {
        dirs.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()));
    }
    let mut found: Vec<serde_json::Value> = dirs
        .into_iter()
        .filter(|d| Design::is_design(d))
        .filter_map(|d| {
            let design = Design::open(&d).ok()?;
            Some(serde_json::json!({
                "path": d.to_string_lossy(),
                "name": design.design.get().name,
                "pages": design.pages.len(),
            }))
        })
        .collect();
    found.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    json(&found)
}

/// A new design called `name` in `dir`, from the starter: Lumen's landing
/// page and its palette. Refused if `dir` already holds a design.
#[uniffi::export]
pub fn design_create(dir: String, name: String) -> Result<(), DiffuseError> {
    starter::write(Path::new(&dir), &starter::files(&name)).map_err(failed)
}

/// One design open for editing.
#[derive(uniffi::Object)]
pub struct DesignEditor {
    held: Mutex<Design>,
}

fn target(text: &str) -> Result<Target, DiffuseError> {
    Target::parse(text).ok_or_else(|| failed(format!("{text} is not one of a design's documents")))
}

#[uniffi::export]
impl DesignEditor {
    /// The design in the folder at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<DesignEditor>, DiffuseError> {
        Ok(Arc::new(DesignEditor { held: Mutex::new(Design::open(Path::new(&path)).map_err(failed)?) }))
    }

    /// Everything but the pages' layers, as JSON: the design, a row a page,
    /// the theme's tokens, what is unsaved and the tokens pages use that the
    /// theme lacks.
    pub fn view(&self) -> String {
        let d = lock(&self.held);
        let pages: Vec<serde_json::Value> = d
            .pages
            .iter()
            .map(|p| serde_json::json!({ "id": p.get().id, "name": p.get().name, "dirty": p.is_dirty(), "canUndo": p.can_undo(), "canRedo": p.can_redo() }))
            .collect();
        let uses = d.uses();
        let components: Vec<serde_json::Value> = d
            .components
            .iter()
            .map(|c| {
                let placed: Vec<_> = uses.get(&c.get().id).into_iter().flatten().map(|(page, layer)| serde_json::json!({ "page": page, "layer": layer })).collect();
                serde_json::json!({ "id": c.get().id, "name": c.get().name, "dirty": c.is_dirty(), "uses": placed })
            })
            .collect();
        json(&serde_json::json!({
            "path": d.root().to_string_lossy(),
            "design": d.design.get(),
            "pages": pages,
            "components": components,
            "theme": {
                "exists": d.theme.exists(),
                "tokens": d.theme.tokens(),
                "dirty": d.theme.is_dirty(),
            },
            "unsaved": d.unsaved_files(),
            "problems": d.problems(),
        }))
    }

    /// Page `id`, as JSON, as it is now.
    pub fn page(&self, id: String) -> Option<String> {
        lock(&self.held).page(&id).map(|p| json(p.get()))
    }

    /// Page `id` with its instances expanded into their components' layers,
    /// as JSON.
    pub fn expanded(&self, id: String) -> Option<String> {
        lock(&self.held).expanded(&id).map(|p| json(&p))
    }

    /// Component `id`, as JSON, as it is now.
    pub fn component(&self, id: String) -> Option<String> {
        lock(&self.held).component(&id).map(|c| json(c.get()))
    }

    /// Component `id` made from frame `layer` of page `page`, an instance
    /// in the frame's place: one step, undone as `made:<id>/<page>`.
    pub fn make_component(&self, page: String, layer: String, id: String, name: String) -> Result<(), DiffuseError> {
        lock(&self.held).make_component(&page, &layer, &id, &name).map_err(failed)
    }

    /// A batch of ops (JSON, Game's ops) on `design`, `page:<id>` or
    /// `component:<id>`, whole or not at all. Whether it changed anything.
    pub fn apply(&self, target_name: String, ops: String) -> Result<bool, DiffuseError> {
        let ops: Vec<Op> = serde_json::from_str(&ops).map_err(|e| failed(format!("not ops: {e}")))?;
        lock(&self.held).apply(&target(&target_name)?, &ops).map_err(failed)
    }

    /// One token's value, by name and scope, as a step of `theme`.
    pub fn set_token(&self, name: String, scope: String, value: String) -> Result<bool, DiffuseError> {
        lock(&self.held).set_token(&name, &scope, &value).map_err(failed)
    }

    pub fn undo(&self, target_name: String) -> Result<bool, DiffuseError> {
        lock(&self.held).undo(&target(&target_name)?).map_err(failed)
    }

    pub fn redo(&self, target_name: String) -> Result<bool, DiffuseError> {
        lock(&self.held).redo(&target(&target_name)?).map_err(failed)
    }

    /// Write every changed file; the files written.
    pub fn save(&self) -> Result<Vec<String>, DiffuseError> {
        lock(&self.held).save().map_err(failed)
    }

    /// The theme's text as it is now, saved or not.
    pub fn theme_text(&self) -> String {
        lock(&self.held).theme.text().to_string()
    }

    /// Page `id` as an HTML document, its tokens from `theme_href` and its
    /// pictures' `images/` under `base`.
    pub fn html(&self, id: String, theme_href: String, base: String) -> Option<String> {
        let d = lock(&self.held);
        d.page(&id).map(|p| html::document(p.get(), &d.component_map(), &theme_href, &base))
    }

    /// Layer `layer` of page `id` and everything in it, as JSON:
    /// `{html, css}`.
    pub fn code(&self, id: String, layer: String) -> Option<String> {
        let d = lock(&self.held);
        let page = d.page(&id)?.get();
        page.layer(&layer)?;
        let components = d.component_map();
        Some(json(&serde_json::json!({ "html": html::markup(page, &components, &layer, ""), "css": html::css(page, &components, &layer) })))
    }

    /// Component `id` as its instances are written: `{html, css}`.
    pub fn component_code(&self, id: String) -> Option<String> {
        let d = lock(&self.held);
        let c = d.component(&id)?.get();
        Some(json(&serde_json::json!({ "html": html::component_markup(c, ""), "css": html::component_css(c) })))
    }
}
