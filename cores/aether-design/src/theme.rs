//! `theme.css`, open for editing: Proton's [`Theme`] with undo, held until
//! saved like a page.
//!
//! Proton wrote a token to disk the moment it changed and kept no history.
//! Here a token edit is a step like any other: it is undone with ⌘Z wherever
//! it was made, and written on ⌘S with the pages it was made beside. The
//! file is still only ever spliced — what is kept for undo is the text each
//! step left, so undoing puts back the exact bytes, comments and all.

use std::path::Path;

use proton_design::{Theme, Token};

/// How many steps back undo goes.
const UNDO: usize = 200;

/// The theme as it is now and as it was saved.
#[derive(Debug, Clone)]
pub struct ThemeDoc {
    theme: Theme,
    /// As the file has it; `None` when there is no file yet.
    saved: Option<String>,
    undo: Vec<String>,
    redo: Vec<String>,
}

impl ThemeDoc {
    /// `theme.css` in `root`, or an empty theme when there is none.
    pub fn read(root: &Path) -> Result<ThemeDoc, String> {
        let path = root.join(crate::THEME);
        if !path.exists() {
            return Ok(ThemeDoc { theme: Theme::parse(""), saved: None, undo: Vec::new(), redo: Vec::new() });
        }
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", crate::THEME))?;
        Ok(ThemeDoc { theme: Theme::parse(&text), saved: Some(text), undo: Vec::new(), redo: Vec::new() })
    }

    pub fn tokens(&self) -> &[Token] {
        self.theme.tokens()
    }

    pub fn text(&self) -> &str {
        self.theme.to_text()
    }

    /// Whether there is a `theme.css` on disk.
    pub fn exists(&self) -> bool {
        self.saved.is_some()
    }

    pub fn is_dirty(&self) -> bool {
        self.saved.as_deref().unwrap_or("") != self.text()
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Set one declaration's value, found by name and scope, as one step.
    /// `Ok(false)` when it already had that value.
    pub fn set(&mut self, name: &str, scope: &str, value: &str) -> Result<bool, String> {
        let value = value.trim();
        // Spliced into somebody's stylesheet: a `;` or a brace would end the
        // declaration and start something else in their file.
        if value.is_empty() || value.contains([';', '{', '}', '\n']) || value.contains("/*") {
            return Err(format!("{value:?} can't be a token's value"));
        }
        if !self.tokens().iter().any(|t| t.name == name && t.scope == scope) {
            return Err(format!("the theme has no {name} in {scope}"));
        }
        let was = self.text().to_string();
        if !self.theme.set(name, scope, value) {
            return Ok(false);
        }
        self.undo.push(was);
        if self.undo.len() > UNDO {
            self.undo.remove(0);
        }
        self.redo.clear();
        Ok(true)
    }

    pub fn undo(&mut self) -> bool {
        let Some(was) = self.undo.pop() else { return false };
        self.redo.push(self.text().to_string());
        self.theme = Theme::parse(&was);
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.redo.pop() else { return false };
        self.undo.push(self.text().to_string());
        self.theme = Theme::parse(&next);
        true
    }

    /// Write it, whole or not at all.
    pub fn save(&mut self, root: &Path) -> Result<(), String> {
        let text = self.text().to_string();
        proton_game::doc::write_atomically(&root.join(crate::THEME), text.as_bytes()).map_err(|e| format!("{}: {e}", crate::THEME))?;
        self.saved = Some(text);
        Ok(())
    }
}
