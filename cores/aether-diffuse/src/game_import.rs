//! Art brought into the open game: a `.psd` or `.png` in its folder made
//! into a room's planes, an Aseprite file or a sprite sheet's JSON into an
//! animation, a DragonBones armature into a skeleton (`proton_game::import`
//! does the making). Proton's core did this (`game/import.rs`); ported.
//!
//! The images are written at once: they're new files beside the game's art,
//! and nothing names them yet. The room's change isn't made here: its planes
//! as they'd be come back, for the Game workspace to make the edit, so it's
//! one step of the person's undo, held until they save. Importing a file
//! again replaces what it made the time before; `import.json` remembers what
//! each file made. An image an earlier import wrote and this one doesn't is
//! said, not deleted: it's the person's file.

use std::path::Path;

use proton_game::format::{Imported, Imports, Plane};
use proton_game::import::{import, Importing, Made};

use crate::game::GameEditor;
use crate::{failed, json, lock, DiffuseError};

/// Where a game keeps what was imported into it.
pub const IMPORTS: &str = "import.json";

/// FNV-1a, hex: enough to tell a file changed, not a seal.
fn hash(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// A file's size and time, to tell cheaply whether it changed since.
fn stamp(path: &Path) -> String {
    let Ok(meta) = std::fs::metadata(path) else { return String::new() };
    let time = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis());
    format!("{}:{}", meta.len(), time)
}

fn read_imports(root: &Path) -> Imports {
    std::fs::read_to_string(root.join(IMPORTS)).ok().and_then(|text| serde_json::from_str(&text).ok()).unwrap_or_default()
}

fn remember(root: &Path, record: Imported) -> Result<(), String> {
    let mut imports = read_imports(root);
    match imports.sources.iter_mut().find(|s| s.source == record.source) {
        Some(old) => *old = record,
        None => imports.sources.push(record),
    }
    proton_game::doc::write_atomically(&root.join(IMPORTS), proton_game::doc::to_text(&imports).as_bytes()).map_err(|e| format!("{IMPORTS}: {e}"))
}

/// Files written into the game's folder, those already the same left alone.
fn write(root: &Path, files: &[(String, Vec<u8>)]) -> Result<(), String> {
    for (rel, data) in files {
        let at = proton_game::path::inside(root, rel)?;
        if std::fs::read(&at).ok().as_deref() == Some(data.as_slice()) {
            continue;
        }
        if let Some(dir) = at.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        proton_game::doc::write_atomically(&at, data).map_err(|e| format!("{rel}: {e}"))?;
    }
    Ok(())
}

/// `base`, or `base_2`, `base_3`… if `taken` has it.
fn free(taken: &[String], base: &str) -> String {
    let mut name = base.to_string();
    let mut n = 2;
    while taken.iter().any(|t| *t == name) {
        name = format!("{base}_{n}");
        n += 1;
    }
    name
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

#[uniffi::export]
impl GameEditor {
    /// Bring in the file at `source`, in the game's folder. A `.psd` or a
    /// `.png` goes into room `room` (or the room it went into last time) at
    /// `scale` room pixels a source pixel (0: as last time, else 1), with
    /// normal maps from its brightness if `normals`; an Aseprite file or a
    /// sheet's JSON becomes an animation, a DragonBones armature a skeleton.
    ///
    /// JSON: `{kind: "room" | "anim" | "skel", room, planes, path, said,
    /// notes}` — for a room, its planes as the import leaves them, for the
    /// caller to set as one edit; for an animation or skeleton, the file
    /// made, which a prefab plays once its sprite names it.
    pub fn import_art(&self, source: String, room: String, scale: f64, normals: bool) -> Result<String, DiffuseError> {
        let p = lock(&self.held);
        let root = p.root().to_path_buf();
        let path = proton_game::path::inside(&root, &source).map_err(failed)?;
        let bytes = std::fs::read(&path).map_err(|e| failed(format!("{source}: {e}")))?;
        let file = source.rsplit('/').next().unwrap_or(&source).to_string();
        let previous = read_imports(&root).sources.into_iter().find(|s| s.source == source);
        let unused = |files: &[String]| -> Vec<String> { previous.as_ref().map(|p| p.files.iter().filter(|f| !files.contains(f)).cloned().collect()).unwrap_or_default() };
        let users = |made: &str| -> Vec<String> { p.prefabs.iter().map(|d| d.get()).filter(|f| f.sprite.as_deref() == Some(made)).map(|f| f.id.clone()).collect() };

        if proton_game::import::anim::is_anim_source(&source, &bytes) {
            let made = proton_game::import::anim::import_anim(&source, &bytes).map_err(failed)?;
            let mut notes = made.notes.clone();
            for sheet in &made.anim.sheets {
                if !made.files.iter().any(|(f, _)| f == sheet) && !proton_game::path::inside(&root, sheet).is_ok_and(|p| p.is_file()) {
                    notes.push(format!("{source} says its frames are on {sheet}, which is not in the game's folder"));
                }
            }
            write(&root, &made.files).map_err(failed)?;
            let files: Vec<String> = made.files.iter().map(|(f, _)| f.clone()).collect();
            let gone = unused(&files);
            remember(&root, Imported { source: source.clone(), hash: hash(&bytes), files, stamp: stamp(&path), anim: made.path.clone(), ..Imported::default() }).map_err(failed)?;
            if !gone.is_empty() {
                notes.push(format!("the last import also wrote {}, which this one doesn't: delete them if nothing else uses them", gone.join(", ")));
            }
            let a = &made.anim;
            let mut said = format!(
                "Made {} of {file}: {}, clips {}",
                made.path,
                plural(a.frames.len(), "frame", "frames"),
                a.clips.iter().map(|c| c.name.as_str()).collect::<Vec<_>>().join(", ")
            );
            said.push_str(&match users(&made.path).as_slice() {
                [] => ". A prefab plays it once its look is this file.".to_string(),
                ids => format!(". Played by {}.", ids.join(", ")),
            });
            return Ok(json(&serde_json::json!({ "kind": "anim", "path": made.path, "said": said, "notes": notes })));
        }

        if proton_game::import::skel::is_skel_source(&source, &bytes) {
            let read = |rel: &str| proton_game::path::inside(&root, rel).ok().and_then(|p| std::fs::read(p).ok());
            let made = proton_game::import::skel::import_skel(&source, &bytes, &read).map_err(failed)?;
            let mut notes = made.notes.clone();
            if read(&made.skel.atlas).is_none() {
                notes.push(format!("its atlas's image {} is not in the game's folder", made.skel.atlas));
            }
            write(&root, &made.files).map_err(failed)?;
            let files: Vec<String> = made.files.iter().map(|(f, _)| f.clone()).collect();
            remember(&root, Imported { source: source.clone(), hash: hash(&bytes), files, stamp: stamp(&path), anim: made.path.clone(), ..Imported::default() }).map_err(failed)?;
            let s = &made.skel;
            let said = format!(
                "Made {} of {file}: {}, clips {}. Skeletons play in a run; drawing them comes later.",
                made.path,
                plural(s.bones.len(), "bone", "bones"),
                s.clips.iter().map(|c| c.name.as_str()).collect::<Vec<_>>().join(", ")
            );
            return Ok(json(&serde_json::json!({ "kind": "skel", "path": made.path, "said": said, "notes": notes })));
        }

        let id = if room.is_empty() { previous.as_ref().map(|p| p.room.clone()).unwrap_or_default() } else { room };
        let doc = p.room(&id).ok_or_else(|| failed(format!("there is no room {id}")))?;
        let how = Importing { scale: if scale > 0.0 { scale } else { previous.as_ref().map_or(1.0, |p| p.scale) }, normals };
        let made = import(&source, &bytes, &how).map_err(failed)?;
        // The images first: a room naming images that failed to be written
        // is worse than images nothing names yet.
        write(&root, &made.files).map_err(failed)?;
        // What this file made the time before taken out, what it makes now
        // put in, each plane where its depth puts it.
        let mut planes: Vec<Plane> = doc.get().planes.clone();
        if let Some(p) = previous.as_ref().filter(|p| p.room == id) {
            planes.retain(|plane| !p.planes.contains(&plane.id));
            for plane in &mut planes {
                plane.items.retain(|i| !p.items.contains(&i.id));
            }
        }
        let (added_planes, added_items) = place(&mut planes, &made);
        let files: Vec<String> = made.files.iter().map(|(f, _)| f.clone()).collect();
        let gone = unused(&files);
        remember(
            &root,
            Imported {
                source: source.clone(),
                hash: hash(&bytes),
                room: id.clone(),
                scale: how.scale,
                normals,
                planes: added_planes.clone(),
                items: added_items.clone(),
                files: files.clone(),
                stamp: stamp(&path),
                anim: String::new(),
            },
        )
        .map_err(failed)?;
        let images = files.iter().filter(|f| f.ends_with(".png")).count();
        let mut said = format!("Imported {file} into {id}: {}", plural(added_planes.len(), "plane", "planes"));
        if !added_items.is_empty() {
            said.push_str(&format!(" and {} on the play plane", plural(added_items.len(), "image", "images")));
        }
        said.push_str(&format!(", {} written", plural(images, "image", "images")));
        if made.cut > 0 {
            said.push_str(&format!(" ({} cut into pieces)", made.cut));
        }
        said.push('.');
        let mut notes = made.notes;
        if !gone.is_empty() {
            notes.push(format!("the last import also wrote {}, which nothing from this one uses: delete them if nothing else does", gone.join(", ")));
        }
        Ok(json(&serde_json::json!({ "kind": "room", "room": id, "planes": planes, "said": said, "notes": notes })))
    }
}

/// An import's planes put into `planes` by depth (further first), and its
/// play-plane images onto the play plane, every id made free in the room.
/// The ids given, of planes and of play-plane items.
fn place(planes: &mut Vec<Plane>, made: &Made) -> (Vec<String>, Vec<String>) {
    let mut items: Vec<String> = planes.iter().flat_map(|p| p.items.iter().map(|i| i.id.clone())).collect();
    let mut added_planes = Vec::new();
    let mut added_items = Vec::new();
    fn free_item(id: &str, items: &mut Vec<String>) -> String {
        let id = free(items, id);
        items.push(id.clone());
        id
    }
    fn put(planes: &mut Vec<Plane>, plane: Plane) {
        let at = planes.iter().position(|p| p.depth < plane.depth).unwrap_or(planes.len());
        planes.insert(at, plane);
    }
    for plane in &made.planes {
        let mut plane = plane.clone();
        let ids: Vec<String> = planes.iter().map(|p| p.id.clone()).collect();
        plane.id = free(&ids, &plane.id);
        for item in &mut plane.items {
            item.id = free_item(&item.id, &mut items);
        }
        added_planes.push(plane.id.clone());
        put(planes, plane);
    }
    if !made.play.is_empty() {
        let mut play = made.play.clone();
        for item in &mut play {
            item.id = free_item(&item.id, &mut items);
            added_items.push(item.id.clone());
        }
        match planes.iter_mut().find(|p| p.gameplay) {
            Some(plane) => plane.items.extend(play),
            None => {
                // A room with no play plane gets one, of what was painted for it.
                let ids: Vec<String> = planes.iter().map(|p| p.id.clone()).collect();
                let plane = Plane { id: free(&ids, "play"), name: "Play".into(), gameplay: true, items: play, ..Plane::default() };
                added_planes.push(plane.id.clone());
                added_items.clear();
                put(planes, plane);
            }
        }
    }
    (added_planes, added_items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A folder that goes when the test does.
    struct Scratch(std::path::PathBuf);
    impl Scratch {
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn game(name: &str) -> (Scratch, Arc<GameEditor>) {
        let dir = Scratch(std::env::temp_dir().join(format!("aether-game-import-{name}-{}", std::process::id())));
        let _ = std::fs::remove_dir_all(dir.path());
        std::fs::create_dir_all(dir.path()).unwrap();
        crate::game::game_create(dir.path().to_string_lossy().into(), "Lumen".into()).unwrap();
        let editor = GameEditor::open(dir.path().to_string_lossy().into()).unwrap();
        (dir, editor)
    }

    /// A layered PSD as a painter lays a room out: a sky, far hills at 800,
    /// and a ground for the play plane.
    fn painted() -> Vec<u8> {
        use proton_game::import::psd_write::{write, Entry, Header, Layer};
        write(
            64,
            48,
            &[
                Entry::group("Floor [play]", vec![Entry::Layer(Layer::filled("Ground", [0, 40], 64, 8, [90, 80, 60, 255]))]),
                Entry::group("Far hills [800]", vec![Entry::Layer(Layer::filled("Hills", [0, 20], 64, 28, [30, 40, 80, 255]))]),
                Entry::Layer(Layer::filled("Sky [still]", [0, 0], 64, 48, [40, 60, 120, 255])),
            ],
            Header::default(),
            None,
        )
    }

    #[test]
    fn a_painters_file_becomes_planes_and_again_replaces_them() {
        let (dir, editor) = game("psd");
        std::fs::create_dir_all(dir.path().join("art/source")).unwrap();
        std::fs::write(dir.path().join("art/source/forest.psd"), painted()).unwrap();
        let before: usize = serde_json::from_str::<serde_json::Value>(&editor.room("crossroads_01".into()).unwrap()).unwrap()["planes"].as_array().unwrap().len();
        let done: serde_json::Value = serde_json::from_str(&editor.import_art("art/source/forest.psd".into(), "crossroads_01".into(), 2.0, true).unwrap()).unwrap();
        assert_eq!(done["kind"], "room");
        let planes = done["planes"].as_array().unwrap();
        assert_eq!(planes.len(), before + 2, "a sky and far hills; the ground joins the play plane: {}", done["said"]);
        let imported = |name: &str| planes.iter().find(|p| p["name"] == name && p["items"][0]["image"].as_str().is_some_and(|i| i.starts_with("art/forest/"))).unwrap();
        let sky = imported("Sky");
        assert_eq!(sky["parallax"], 0.0);
        let hills = imported("Far hills");
        assert_eq!(hills["depth"], 800.0);
        assert_eq!(hills["items"][0]["scale"], 2.0);
        assert_eq!(hills["items"][0]["at"], serde_json::json!([0, 40]));
        // Planes by depth, further first: the still sky's depth is 0, so
        // the hills come before it.
        let depths: Vec<f64> = planes.iter().map(|p| p["depth"].as_f64().unwrap_or(0.0)).collect();
        assert!(depths.windows(2).all(|w| w[0] >= w[1]), "{depths:?}");
        let play = planes.iter().find(|p| p["gameplay"] == true).unwrap();
        assert!(play["items"].as_array().unwrap().iter().any(|i| i["image"].as_str().unwrap().starts_with("art/forest/")));
        assert!(dir.path().join("art/forest").read_dir().unwrap().count() >= 3, "the layers' images, and their normal maps");
        // Applied, then imported again: replaced, not doubled.
        editor.apply("room:crossroads_01".into(), serde_json::json!([{ "op": "set", "path": ["planes"], "value": planes }]).to_string()).unwrap();
        let again: serde_json::Value = serde_json::from_str(&editor.import_art("art/source/forest.psd".into(), String::new(), 0.0, true).unwrap()).unwrap();
        assert_eq!(again["room"], "crossroads_01", "the room it went into last time");
        assert_eq!(again["planes"].as_array().unwrap().len(), before + 2);
        let imports: Imports = serde_json::from_str(&std::fs::read_to_string(dir.path().join(IMPORTS)).unwrap()).unwrap();
        assert_eq!(imports.sources.len(), 1);
        assert_eq!(imports.sources[0].scale, 2.0);
    }

    #[test]
    fn a_sprite_sheet_becomes_an_animation_and_nothing_else_is_refused_plainly() {
        let (dir, editor) = game("sheet");
        let sheet = proton_game::import::encode_png(64, 32, &vec![200u8; 64 * 32 * 4]).unwrap();
        std::fs::write(dir.path().join("art/hero-sheet.png"), sheet).unwrap();
        let frames = serde_json::json!({
            "frames": [
                { "filename": "hero 0", "frame": { "x": 0, "y": 0, "w": 32, "h": 32 }, "spriteSourceSize": { "x": 0, "y": 0, "w": 32, "h": 32 }, "sourceSize": { "w": 32, "h": 32 }, "duration": 100 },
                { "filename": "hero 1", "frame": { "x": 32, "y": 0, "w": 32, "h": 32 }, "spriteSourceSize": { "x": 0, "y": 0, "w": 32, "h": 32 }, "sourceSize": { "w": 32, "h": 32 }, "duration": 100 }
            ],
            "meta": { "image": "hero-sheet.png", "size": { "w": 64, "h": 32 }, "frameTags": [{ "name": "run", "from": 0, "to": 1, "direction": "forward" }] }
        });
        std::fs::write(dir.path().join("art/hero-sheet.json"), frames.to_string()).unwrap();
        let done: serde_json::Value = serde_json::from_str(&editor.import_art("art/hero-sheet.json".into(), String::new(), 0.0, false).unwrap()).unwrap();
        assert_eq!(done["kind"], "anim", "{done}");
        let path = done["path"].as_str().unwrap();
        assert!(path.ends_with(".anim.json") && dir.path().join(path).is_file());
        assert!(done["said"].as_str().unwrap().contains("2 frames"), "{}", done["said"]);
        std::fs::write(dir.path().join("notes.txt"), "hello").unwrap();
        let refused = editor.import_art("notes.txt".into(), "crossroads_01".into(), 0.0, false).unwrap_err();
        assert!(format!("{refused:?}").contains("not a kind of file"), "{refused:?}");
    }
}
