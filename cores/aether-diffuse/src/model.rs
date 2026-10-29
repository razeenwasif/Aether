//! A scene open for editing: Proton's `scene.proton.json` (through
//! `proton-scene`) and the meshes it names (through `proton-mesh`), for the
//! Model workspace.
//!
//! The scene file holds transforms, kinds, modifier stacks and materials; a
//! mesh is a path to an `.obj` beside it. So this keeps the scene and an undo
//! history of it (each edit one step: a scene is a few kilobytes, and keeping
//! it whole before each edit is simpler and safer than inverting every kind
//! of edit), and answers for any object the triangles to draw: its `.obj`
//! read once, its modifier stack applied, normals worked out after — as
//! Proton's `Modeling::geometry` did, with its triangle budget.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use aether_layers::Stack;
use proton_mesh::{Mesh, Step};
use proton_scene::{mesh_path, Light, Material, Modifier, Part, Scene};
use serde::Deserialize;

use crate::{failed, json, lock, DiffuseError};

/// The most triangles one object's geometry may have, after its modifiers:
/// Proton's `BUDGET`. Past it the object draws as a box, and says why.
pub const BUDGET: usize = 500_000;

/// The most undo steps kept.
const STEPS: usize = 200;

#[derive(uniffi::Object)]
pub struct SceneEditor {
    held: Mutex<Held>,
}

struct Held {
    scene: Scene,
    /// The scene's file; meshes are named relative to its folder.
    path: Option<PathBuf>,
    /// The file as last written, to know whether there are changes.
    saved: String,
    undo: Vec<(String, String)>,
    redo: Vec<(String, String)>,
    /// `.obj` files read, by their path in the scene, with when they were
    /// changed on disk, so one edited in Blender is read again.
    files: HashMap<String, (Option<SystemTime>, Mesh)>,
}

/// An object's triangles, ready to draw.
#[derive(uniffi::Record)]
pub struct SceneMesh {
    /// Three floats a vertex.
    pub positions: Vec<f32>,
    /// Three floats a vertex; empty draws faceted.
    pub normals: Vec<f32>,
    /// Three vertex numbers a triangle.
    pub triangles: Vec<u32>,
    /// Least x, y, z, then most.
    pub bounds: Vec<f32>,
    /// A solid, so its backs may be culled.
    pub closed: bool,
    /// Faces of the file that couldn't be used.
    pub skipped: u32,
    /// Why there are no triangles, when there aren't.
    pub problem: Option<String>,
}

impl SceneMesh {
    fn missing(why: impl Into<String>, bounds: Option<[f32; 6]>) -> SceneMesh {
        SceneMesh { positions: Vec::new(), normals: Vec::new(), triangles: Vec::new(), bounds: bounds.map(|b| b.to_vec()).unwrap_or_default(), closed: false, skipped: 0, problem: Some(why.into()) }
    }
}

/// One edit, in JSON: `{"edit": "add", "kind": "mesh", "name": "Cube"}`.
#[derive(Deserialize)]
#[serde(tag = "edit", rename_all = "camelCase")]
enum Edit {
    #[serde(rename_all = "camelCase")]
    Add {
        kind: String,
        name: String,
        #[serde(default)]
        parent: String,
        #[serde(default)]
        mesh: String,
        #[serde(default)]
        position: Option<[f64; 3]>,
    },
    Remove { id: String },
    Rename { id: String, name: String },
    Reparent { id: String, parent: String },
    SetTransform { id: String, part: Part, to: [f64; 3] },
    SetMesh { id: String, path: String },
    AddModifier { id: String, kind: String },
    RemoveModifier { id: String, index: usize },
    MoveModifier { id: String, index: usize, to: usize },
    SetModifier { id: String, index: usize, field: String, value: String },
    /// A new material, a layer stack with nothing over its base, worn by
    /// object `id`; answers its id.
    NewMaterial { id: String, name: String },
    /// A material's graph written from a stack; with none, the stack its
    /// graph starts (its principled node's settings, no layers).
    SetLayers {
        material: String,
        #[serde(default)]
        stack: Option<Stack>,
    },
    /// Object `id` made to wear `material`, or none when it's empty.
    Wear { id: String, material: String },
    RenameMaterial { material: String, name: String },
    /// A material nothing wears, taken out.
    RemoveMaterial { material: String },
    /// A camera's field of view, in degrees top to bottom.
    SetFov { id: String, degrees: f64 },
    /// A light's kind, colour and strength.
    SetLight { id: String, light: Light },
}

#[uniffi::export]
impl SceneEditor {
    /// A new, empty scene, not written until saved.
    #[uniffi::constructor]
    pub fn create() -> Arc<SceneEditor> {
        Arc::new(SceneEditor { held: Mutex::new(Held::new(Scene::new(), None)) })
    }

    /// The scene in the file at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<SceneEditor>, DiffuseError> {
        let path = PathBuf::from(path);
        let scene = Scene::read(&path).map_err(failed)?;
        Ok(Arc::new(SceneEditor { held: Mutex::new(Held::new(scene, Some(path))) }))
    }

    /// What the outliner and inspector show: `{objects, materials, shaders,
    /// undo, redo, dirty}` — objects parents first, with their depth.
    pub fn view(&self) -> String {
        let h = lock(&self.held);
        let materials = h.scene.materials();
        let shaders: Vec<_> = materials.iter().map(Material::compile).collect();
        json(&serde_json::json!({
            "objects": h.scene.objects(),
            "materials": materials,
            "shaders": shaders,
            // Each material as a layer stack, or null for a graph that isn't one.
            "stacks": materials.iter().map(|m| (m.id.clone(), Stack::read(m))).collect::<HashMap<_, _>>(),
            "undo": h.undo.last().map(|s| &s.1),
            "redo": h.redo.last().map(|s| &s.1),
            "dirty": h.scene.to_text() != h.saved,
        }))
    }

    /// Apply an edit (JSON, see `Edit`) as one undo step named `label`.
    /// Answers `{changed, id}`: whether anything did, and an added object's id.
    pub fn edit(&self, edit_json: String, label: String) -> Result<String, DiffuseError> {
        self.apply(edit_json, label, false)
    }

    /// As `edit`, but joining the newest step when it has the same name: the
    /// rest of a colour dragged, or a number scrubbed, undoes as one.
    pub fn edit_joined(&self, edit_json: String, label: String) -> Result<String, DiffuseError> {
        self.apply(edit_json, label, true)
    }

    /// Take back the newest step; its name, or `None` with nothing to undo.
    pub fn undo(&self) -> Option<String> {
        let mut h = lock(&self.held);
        let (text, label) = h.undo.pop()?;
        let now = h.scene.to_text();
        h.scene = Scene::parse(&text).ok()?;
        h.redo.push((now, label.clone()));
        Some(label)
    }

    pub fn redo(&self) -> Option<String> {
        let mut h = lock(&self.held);
        let (text, label) = h.redo.pop()?;
        let now = h.scene.to_text();
        h.scene = Scene::parse(&text).ok()?;
        h.undo.push((now, label.clone()));
        Some(label)
    }

    /// Write the scene to `path`, or where it was opened; it lives there
    /// from now on.
    pub fn save(&self, path: Option<String>) -> Result<(), DiffuseError> {
        let mut h = lock(&self.held);
        let path = path.map(PathBuf::from).or_else(|| h.path.clone()).ok_or_else(|| failed("say where to save a new scene"))?;
        h.scene.write(&path).map_err(failed)?;
        h.saved = h.scene.to_text();
        if h.path.as_ref() != Some(&path) {
            h.files.clear();
        }
        h.path = Some(path);
        Ok(())
    }

    /// The scene as its file is written.
    pub fn text(&self) -> String {
        lock(&self.held).scene.to_text()
    }

    /// An object's triangles: its mesh, its modifier stack applied, shaded.
    /// One with no mesh, or a mesh that can't be read or is over the budget,
    /// answers no triangles and why — with the box it would fill, when known.
    pub fn mesh(&self, id: String) -> SceneMesh {
        let mut h = lock(&self.held);
        let Some(node) = h.scene.objects().into_iter().find(|one| one.id == id) else {
            return SceneMesh::missing(format!("there is no object {id:?}"), None);
        };
        if node.mesh.is_empty() {
            return SceneMesh::missing("it has no mesh", None);
        }
        let base = match h.file(&node.mesh) {
            Ok(mesh) => mesh,
            Err(why) => return SceneMesh::missing(why, None),
        };
        let steps = steps_of(&node.modifiers);
        let would = base.count() as f64 * proton_mesh::growth(&steps);
        if would > BUDGET as f64 {
            return SceneMesh::missing(format!("its modifiers would make {} triangles, over the {} drawn", would as u64, BUDGET), Some(base.bounds));
        }
        let mesh = if steps.is_empty() { base.shade(proton_mesh::CREASE) } else { base.apply(&steps).shade(proton_mesh::CREASE) };
        SceneMesh { positions: mesh.positions, normals: mesh.normals, triangles: mesh.triangles, bounds: mesh.bounds.to_vec(), closed: mesh.closed, skipped: mesh.skipped as u32, problem: None }
    }
}

impl SceneEditor {
    fn apply(&self, edit_json: String, label: String, join: bool) -> Result<String, DiffuseError> {
        let edit: Edit = serde_json::from_str(&edit_json).map_err(|e| failed(format!("not an edit: {e}")))?;
        let mut h = lock(&self.held);
        let before = h.scene.clone();
        let mut made = None;
        let changed = match edit {
            Edit::Add { kind, name, parent, mesh, position } => {
                let id = h.scene.add(&kind, &name, &parent);
                if !mesh.is_empty() {
                    h.scene.set_mesh(&id, &mesh).map_err(failed)?;
                }
                if let Some(at) = position {
                    h.scene.set_transform(&id, Part::Position, at).map_err(failed)?;
                }
                made = Some(id);
                true
            }
            Edit::Remove { id } => h.scene.remove(&id).map_err(failed)? > 0,
            Edit::Rename { id, name } => {
                let name = name.trim();
                if name.is_empty() {
                    return Err(failed("a name can't be empty"));
                }
                h.scene.rename(&id, name).map_err(failed)?
            }
            Edit::Reparent { id, parent } => h.scene.reparent(&id, &parent).map_err(failed)?,
            Edit::SetTransform { id, part, to } => h.scene.set_transform(&id, part, to).map_err(failed)?,
            Edit::SetMesh { id, path } => h.scene.set_mesh(&id, &path).map_err(failed)?,
            Edit::AddModifier { id, kind } => {
                h.scene.add_modifier(&id, &kind).map_err(failed)?;
                true
            }
            Edit::RemoveModifier { id, index } => h.scene.remove_modifier(&id, index).map_err(failed)?,
            Edit::MoveModifier { id, index, to } => h.scene.move_modifier(&id, index, to).map_err(failed)?,
            Edit::SetModifier { id, index, field, value } => h.scene.set_modifier(&id, index, &field, &value).map_err(failed)?,
            Edit::NewMaterial { id, name } => {
                let name = name.trim();
                let name = if name.is_empty() { "Material" } else { name };
                let made_id = h.scene.fresh_material_id(name);
                h.scene.put_material(&Stack::default().graph(&made_id, name));
                h.scene.wear(&id, &made_id).map_err(failed)?;
                made = Some(made_id);
                true
            }
            Edit::SetLayers { material, stack } => {
                let had = h.scene.materials().into_iter().find(|m| m.id == material).ok_or_else(|| failed(format!("there is no material {material:?}")))?;
                let stack = stack.unwrap_or_else(|| Stack::starting_from(&had)).checked().map_err(failed)?;
                h.scene.put_material(&stack.graph(&had.id, &had.name))
            }
            Edit::Wear { id, material } => h.scene.wear(&id, &material).map_err(failed)?,
            Edit::RenameMaterial { material, name } => h.scene.rename_material(&material, &name).map_err(failed)?,
            Edit::RemoveMaterial { material } => h.scene.remove_material(&material).map_err(failed)?,
            Edit::SetFov { id, degrees } => h.scene.set_fov(&id, degrees).map_err(failed)?,
            Edit::SetLight { id, light } => h.scene.set_light(&id, &light).map_err(failed)?,
        };
        if changed && join && h.undo.last().is_some_and(|s| s.1 == label) {
            h.redo.clear();
        } else if changed {
            let text = before.to_text();
            h.redo.clear();
            h.undo.push((text, label));
            if h.undo.len() > STEPS {
                h.undo.remove(0);
            }
        } else {
            h.scene = before;
        }
        Ok(json(&serde_json::json!({ "changed": changed, "id": made })))
    }
}

impl Held {
    fn new(scene: Scene, path: Option<PathBuf>) -> Held {
        let saved = if path.is_some() { scene.to_text() } else { String::new() };
        Held { scene, path, saved, undo: Vec::new(), redo: Vec::new(), files: HashMap::new() }
    }

    /// The `.obj` at `relative`, read once and again when it changes.
    fn file(&mut self, relative: &str) -> Result<Mesh, String> {
        let clean = mesh_path(relative)?;
        let folder = self.path.as_deref().and_then(Path::parent).ok_or("save the scene first: a mesh is found beside it")?;
        let full = folder.join(&clean);
        let changed = std::fs::metadata(&full).and_then(|m| m.modified()).ok();
        if let Some((when, mesh)) = self.files.get(&clean) {
            if *when == changed && changed.is_some() {
                return Ok(mesh.clone());
            }
        }
        let mesh = Mesh::read(&full)?;
        self.files.insert(clean, (changed, mesh.clone()));
        Ok(mesh)
    }
}

/// A modifier stack as operations to run: one switched off, or of a kind
/// this build doesn't know, runs nothing (Proton's `steps_of`).
fn steps_of(stack: &[Modifier]) -> Vec<Step> {
    stack
        .iter()
        .filter(|one| one.known && !one.off)
        .filter_map(|one| match one.kind.as_str() {
            "mirror" => Some(Step::Mirror { axis: match one.axis.as_str() { "y" => 1, "z" => 2, _ => 0 }, weld: one.weld }),
            "array" => Some(Step::Array { count: one.count, offset: [one.offset[0] as f32, one.offset[1] as f32, one.offset[2] as f32] }),
            "subdivide" => Some(Step::Subdivide { levels: one.levels }),
            _ => None,
        })
        .collect()
}

/// A primitive as an `.obj`, for a new object to name: `cube`, `sphere`,
/// `cylinder`, `cone`, `plane` or `torus`, about the origin, a metre across.
#[uniffi::export]
pub fn scene_primitive(kind: String) -> Option<String> {
    let mut v: Vec<[f64; 3]> = Vec::new();
    let mut f: Vec<Vec<usize>> = Vec::new();
    let tau = std::f64::consts::TAU;
    match kind.as_str() {
        "cube" => {
            for z in [-0.5, 0.5] {
                for y in [-0.5, 0.5] {
                    for x in [-0.5, 0.5] {
                        v.push([x, y, z]);
                    }
                }
            }
            // Counter-clockwise from outside.
            f = vec![vec![0, 2, 3, 1], vec![4, 5, 7, 6], vec![0, 1, 5, 4], vec![2, 6, 7, 3], vec![0, 4, 6, 2], vec![1, 3, 7, 5]];
        }
        "plane" => {
            v = vec![[-1.0, 0.0, -1.0], [1.0, 0.0, -1.0], [1.0, 0.0, 1.0], [-1.0, 0.0, 1.0]];
            f = vec![vec![0, 3, 2, 1]];
        }
        "sphere" => {
            let (rings, segments) = (12usize, 24usize);
            v.push([0.0, 0.5, 0.0]);
            for r in 1..rings {
                let phi = std::f64::consts::PI * r as f64 / rings as f64;
                for s in 0..segments {
                    let theta = tau * s as f64 / segments as f64;
                    v.push([0.5 * phi.sin() * theta.cos(), 0.5 * phi.cos(), 0.5 * phi.sin() * theta.sin()]);
                }
            }
            v.push([0.0, -0.5, 0.0]);
            let at = |r: usize, s: usize| 1 + (r - 1) * segments + s % segments;
            for s in 0..segments {
                f.push(vec![0, at(1, s + 1), at(1, s)]);
            }
            for r in 1..rings - 1 {
                for s in 0..segments {
                    f.push(vec![at(r, s), at(r, s + 1), at(r + 1, s + 1), at(r + 1, s)]);
                }
            }
            let bottom = v.len() - 1;
            for s in 0..segments {
                f.push(vec![bottom, at(rings - 1, s), at(rings - 1, s + 1)]);
            }
        }
        "cylinder" => {
            let segments = 24usize;
            for s in 0..segments {
                let theta = tau * s as f64 / segments as f64;
                v.push([0.5 * theta.cos(), -0.5, 0.5 * theta.sin()]);
                v.push([0.5 * theta.cos(), 0.5, 0.5 * theta.sin()]);
            }
            for s in 0..segments {
                let (a, b) = (2 * s, 2 * ((s + 1) % segments));
                f.push(vec![a, a + 1, b + 1, b]);
            }
            f.push((0..segments).map(|s| 2 * s).collect());
            f.push((0..segments).rev().map(|s| 2 * s + 1).collect());
        }
        "cone" => {
            // One apex, so the sides meet there and it reads as a solid.
            let segments = 24usize;
            for s in 0..segments {
                let theta = tau * s as f64 / segments as f64;
                v.push([0.5 * theta.cos(), -0.5, 0.5 * theta.sin()]);
            }
            v.push([0.0, 0.5, 0.0]);
            for s in 0..segments {
                f.push(vec![s, segments, (s + 1) % segments]);
            }
            f.push((0..segments).collect());
        }
        "torus" => {
            let (rings, sides) = (32usize, 16usize);
            for r in 0..rings {
                let u = tau * r as f64 / rings as f64;
                for s in 0..sides {
                    let w = tau * s as f64 / sides as f64;
                    let d = 0.375 + 0.125 * w.cos();
                    v.push([d * u.cos(), 0.125 * w.sin(), d * u.sin()]);
                }
            }
            let at = |r: usize, s: usize| (r % rings) * sides + s % sides;
            for r in 0..rings {
                for s in 0..sides {
                    f.push(vec![at(r, s), at(r, s + 1), at(r + 1, s + 1), at(r + 1, s)]);
                }
            }
        }
        _ => return None,
    }
    let mut out = format!("# A {kind}, made by Aether.\n");
    for p in &v {
        out.push_str(&format!("v {:.6} {:.6} {:.6}\n", p[0], p[1], p[2]));
    }
    for face in &f {
        out.push('f');
        for i in face {
            out.push_str(&format!(" {}", i + 1));
        }
        out.push('\n');
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("aether-scene-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("meshes")).unwrap();
        dir
    }

    fn view(e: &SceneEditor) -> serde_json::Value {
        serde_json::from_str(&e.view()).unwrap()
    }

    #[test]
    fn edits_are_undone_one_at_a_time() {
        let editor = SceneEditor::create();
        let made: serde_json::Value = serde_json::from_str(&editor.edit(r#"{"edit": "add", "kind": "empty", "name": "Rig"}"#.into(), "Add Rig".into()).unwrap()).unwrap();
        let rig = made["id"].as_str().unwrap().to_string();
        let lamp: serde_json::Value = serde_json::from_str(&editor.edit(format!(r#"{{"edit": "add", "kind": "light", "name": "Lamp", "parent": "{rig}", "position": [1, 2, 3]}}"#), "Add Lamp".into()).unwrap()).unwrap();
        let v = view(&editor);
        assert_eq!(v["objects"].as_array().unwrap().len(), 2);
        assert_eq!((v["objects"][1]["depth"].as_u64(), v["objects"][1]["position"][1].as_f64()), (Some(1), Some(2.0)), "under the rig, where it was put");
        assert_eq!(v["undo"], "Add Lamp");
        let same = editor.edit(format!(r#"{{"edit": "rename", "id": "{rig}", "name": "Rig"}}"#), "Rename".into()).unwrap();
        assert!(same.contains("\"changed\":false") && view(&editor)["undo"] == "Add Lamp", "nothing changed, no step");
        assert!(editor.edit(format!(r#"{{"edit": "reparent", "id": "{rig}", "parent": "{}"}}"#, lamp["id"].as_str().unwrap()), "Reparent".into()).is_err(), "a loop is refused");
        assert_eq!(editor.undo().as_deref(), Some("Add Lamp"));
        assert_eq!(view(&editor)["objects"].as_array().unwrap().len(), 1);
        assert_eq!(editor.redo().as_deref(), Some("Add Lamp"));
        editor.edit(format!(r#"{{"edit": "remove", "id": "{rig}"}}"#), "Remove".into()).unwrap();
        assert!(view(&editor)["objects"].as_array().unwrap().is_empty(), "with what's under it");
    }

    #[test]
    fn a_material_is_a_layer_stack_and_a_drag_is_one_step() {
        let editor = SceneEditor::create();
        let cube: serde_json::Value = serde_json::from_str(&editor.edit(r#"{"edit": "add", "kind": "mesh", "name": "Cube"}"#.into(), "Add Cube".into()).unwrap()).unwrap();
        let cube = cube["id"].as_str().unwrap().to_string();
        let made: serde_json::Value = serde_json::from_str(&editor.edit(format!(r#"{{"edit": "newMaterial", "id": "{cube}", "name": "Paint"}}"#), "New Material".into()).unwrap()).unwrap();
        let paint = made["id"].as_str().unwrap().to_string();
        let v = view(&editor);
        assert_eq!(v["objects"][0]["material"], paint.as_str());
        assert_eq!(v["stacks"][&paint]["layers"].as_array().map(Vec::len), Some(0), "a stack with nothing over its base");
        assert_eq!(v["shaders"][0]["problem"], "");

        let red = |r: f64| format!(r#"{{"edit": "setLayers", "material": "{paint}", "stack": {{"base": {{"color": [{r}, 0, 0], "metallic": 0, "roughness": 0.5}}, "layers": [
            {{"pattern": "noise", "surface": {{"color": [0, 0, 0], "metallic": 0, "roughness": 1}}, "amount": 1, "scale": 4, "detail": 3, "coverage": 0.5, "edge": 0.5}}]}}}}"#);
        editor.edit_joined(red(0.5), "Base Colour".into()).unwrap();
        editor.edit_joined(red(0.7), "Base Colour".into()).unwrap();
        editor.edit_joined(red(0.9), "Base Colour".into()).unwrap();
        let v = view(&editor);
        assert_eq!(v["stacks"][&paint]["base"]["color"][0].as_f64(), Some(0.9));
        assert_eq!(v["stacks"][&paint]["layers"][0]["pattern"], "noise");
        assert_eq!(editor.undo().as_deref(), Some("Base Colour"), "three changes, one step");
        assert_eq!(view(&editor)["stacks"][&paint]["layers"].as_array().map(Vec::len), Some(0));
        assert_eq!(editor.undo().as_deref(), Some("New Material"));
        assert!(view(&editor)["objects"][0]["material"].is_null() || view(&editor)["objects"][0]["material"] == "");
        assert!(editor.edit(format!(r#"{{"edit": "wear", "id": "{cube}", "material": "nothing-1"}}"#), "Wear".into()).is_err());
    }

    #[test]
    fn a_mesh_is_read_beside_the_scene_and_its_modifiers_run() {
        let dir = folder();
        std::fs::write(dir.join("meshes/cube.obj"), scene_primitive("cube".into()).unwrap()).unwrap();
        let editor = SceneEditor::create();
        assert!(editor.mesh("x".into()).problem.is_some());
        let made: serde_json::Value = serde_json::from_str(&editor.edit(r#"{"edit": "add", "kind": "mesh", "name": "Cube", "mesh": "meshes/cube.obj"}"#.into(), "Add".into()).unwrap()).unwrap();
        let id = made["id"].as_str().unwrap().to_string();
        assert!(editor.mesh(id.clone()).problem.unwrap().contains("save the scene first"));
        editor.save(Some(dir.join("lab.scene.json").display().to_string())).unwrap();
        assert_eq!(view(&editor)["dirty"], false);

        let cube = editor.mesh(id.clone());
        assert_eq!((cube.triangles.len() / 3, cube.closed, cube.problem), (12, true, None));
        assert_eq!(cube.normals.len(), cube.positions.len(), "shaded");
        assert_eq!(cube.bounds, vec![-0.5, -0.5, -0.5, 0.5, 0.5, 0.5]);

        editor.edit(format!(r#"{{"edit": "addModifier", "id": "{id}", "kind": "array"}}"#), "Array".into()).unwrap();
        editor.edit(format!(r#"{{"edit": "setModifier", "id": "{id}", "index": 0, "field": "count", "value": "20"}}"#), "Count".into()).unwrap();
        let row = editor.mesh(id.clone());
        assert_eq!((row.triangles.len() / 3, row.bounds[3]), (240, 19.5), "twenty in a row, a metre apart");
        assert_eq!(view(&editor)["dirty"], true);

        editor.edit(format!(r#"{{"edit": "addModifier", "id": "{id}", "kind": "subdivide"}}"#), "Subdivide".into()).unwrap();
        editor.edit(format!(r#"{{"edit": "setModifier", "id": "{id}", "index": 1, "field": "levels", "value": "6"}}"#), "Levels".into()).unwrap();
        let big = editor.mesh(id.clone());
        assert!(big.triangles.is_empty() && big.problem.unwrap().contains("over the") && big.bounds.len() == 6, "over the budget: a box, and why");

        assert!(editor.edit(format!(r#"{{"edit": "setMesh", "id": "{id}", "path": "../../etc/passwd"}}"#), "Mesh".into()).is_err(), "outside the scene's folder");
        editor.edit(format!(r#"{{"edit": "setMesh", "id": "{id}", "path": "meshes/none.obj"}}"#), "Mesh".into()).unwrap();
        assert!(editor.mesh(id).problem.is_some(), "a file that isn't there says so");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn every_primitive_reads_back_as_a_mesh() {
        for kind in ["cube", "plane", "sphere", "cylinder", "cone", "torus"] {
            let mesh = Mesh::parse(&scene_primitive(kind.into()).unwrap()).unwrap();
            assert!(mesh.count() > 0 && mesh.skipped == 0, "{kind}");
            assert_eq!(mesh.closed, kind != "plane", "{kind} is {}", if mesh.closed { "closed" } else { "open" });
        }
        assert!(scene_primitive("teapot".into()).is_none());
    }
}
