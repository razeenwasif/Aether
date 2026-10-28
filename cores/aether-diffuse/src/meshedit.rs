//! A mesh open in Model's Edit mode: an `.obj` kept as polygons (through
//! `aether-poly`), edited, with an undo history, and written back.
//!
//! As with a scene, each edit keeps the whole mesh as it was before, which
//! for the meshes Edit mode is for (thousands of faces, not millions) is
//! simpler and safer than inverting every edit. A drag is one step: its
//! first move makes the step and the rest join it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use aether_poly::Poly;

use crate::{failed, lock, DiffuseError};

/// The most undo steps kept.
const STEPS: usize = 200;

#[derive(uniffi::Object)]
pub struct MeshEditor {
    held: Mutex<Held>,
}

struct Held {
    poly: Poly,
    path: PathBuf,
    saved: Poly,
    dropped: Vec<String>,
    undo: Vec<(Poly, String)>,
    redo: Vec<(Poly, String)>,
    /// Steps made since it was opened, to tell a new one.
    made: u32,
}

impl Held {
    /// Keep `before` as a step named `label`, if anything changed.
    fn step(&mut self, before: Poly, label: &str) -> bool {
        if before == self.poly {
            return false;
        }
        self.undo.push((before, label.to_string()));
        if self.undo.len() > STEPS {
            self.undo.remove(0);
        }
        self.redo.clear();
        self.made = self.made.wrapping_add(1);
        true
    }
}

/// What Edit mode draws and picks from.
#[derive(uniffi::Record)]
pub struct MeshCage {
    /// Three floats a vertex.
    pub positions: Vec<f32>,
    /// Every face's corners, one face after another.
    pub faces: Vec<u32>,
    /// How many corners each face has.
    pub face_sizes: Vec<u32>,
    /// Two vertex numbers an edge, every edge once.
    pub edges: Vec<u32>,
    /// Three vertex numbers a triangle, fanned from each face's first corner.
    pub triangles: Vec<u32>,
    /// The face each triangle belongs to.
    pub triangle_faces: Vec<u32>,
    pub closed: bool,
    pub undo: Option<String>,
    pub redo: Option<String>,
    /// Steps made since it was opened, so a caller can tell one was kept.
    pub steps: u32,
    /// Changed since it was read or written.
    pub dirty: bool,
}

fn pairs(flat: &[u32]) -> Vec<[u32; 2]> {
    flat.chunks_exact(2).map(|p| [p[0], p[1]]).collect()
}

#[uniffi::export]
impl MeshEditor {
    /// The mesh in the `.obj` at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<MeshEditor>, DiffuseError> {
        let path = PathBuf::from(path);
        let text = std::fs::read_to_string(&path).map_err(|e| failed(format!("{}: {e}", path.display())))?;
        let read = Poly::parse(&text).map_err(|e| failed(format!("{} can’t be edited: {e}", path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default())))?;
        Ok(Arc::new(MeshEditor {
            held: Mutex::new(Held { saved: read.poly.clone(), poly: read.poly, path, dropped: read.dropped, undo: Vec::new(), redo: Vec::new(), made: 0 }),
        }))
    }

    /// What the file had that writing it would drop: texture coordinates,
    /// normals, materials, group names.
    pub fn dropped(&self) -> Vec<String> {
        lock(&self.held).dropped.clone()
    }

    pub fn cage(&self) -> MeshCage {
        let h = lock(&self.held);
        let (triangles, triangle_faces) = h.poly.triangles();
        MeshCage {
            positions: h.poly.positions.iter().flat_map(|p| p.map(|x| x as f32)).collect(),
            faces: h.poly.faces.iter().flatten().copied().collect(),
            face_sizes: h.poly.faces.iter().map(|f| f.len() as u32).collect(),
            edges: h.poly.edges().into_iter().flatten().collect(),
            triangles,
            triangle_faces,
            closed: h.poly.closed(),
            undo: h.undo.last().map(|s| s.1.clone()),
            redo: h.redo.last().map(|s| s.1.clone()),
            steps: h.made,
            dirty: h.poly != h.saved,
        }
    }

    /// Move `vertices` by (`dx`, `dy`, `dz`). `continuing` joins the step
    /// before (the rest of a drag), so a drag undoes as one. Answers whether
    /// a new step was made.
    pub fn move_vertices(&self, vertices: Vec<u32>, dx: f64, dy: f64, dz: f64, label: String, continuing: bool) -> bool {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        h.poly.translate(&vertices, [dx, dy, dz]);
        !continuing && h.step(before, &label)
    }

    /// Extrude `faces` as one region by `distance`; answers them.
    pub fn extrude(&self, faces: Vec<u32>, distance: f64) -> Vec<u32> {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        let kept = h.poly.extrude(&faces, distance);
        h.step(before, "Extrude");
        kept
    }

    /// Inset each of `faces` by `amount`; answers the inner faces.
    pub fn inset(&self, faces: Vec<u32>, amount: f64) -> Vec<u32> {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        let kept = h.poly.inset(&faces, amount);
        h.step(before, "Inset");
        kept
    }

    /// A loop cut across the ring of quads the edge `a`–`b` is part of, `t`
    /// of the way from `a`'s side; answers the new loop's edges, flattened.
    pub fn loop_cut(&self, a: u32, b: u32, t: f64) -> Result<Vec<u32>, DiffuseError> {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        let made = h.poly.loop_cut([a, b], t).map_err(failed)?;
        h.step(before, "Loop Cut");
        Ok(made.into_iter().flatten().collect())
    }

    pub fn delete_faces(&self, faces: Vec<u32>) {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        h.poly.delete_faces(&faces);
        h.step(before, "Delete");
    }

    pub fn delete_vertices(&self, vertices: Vec<u32>) {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        h.poly.delete_vertices(&vertices);
        h.step(before, "Delete");
    }

    /// `edges` flattened, two vertex numbers each.
    pub fn delete_edges(&self, edges: Vec<u32>) {
        let mut h = lock(&self.held);
        let before = h.poly.clone();
        h.poly.delete_edges(&pairs(&edges));
        h.step(before, "Delete");
    }

    pub fn faces_of_vertices(&self, vertices: Vec<u32>) -> Vec<u32> {
        lock(&self.held).poly.faces_of_vertices(&vertices)
    }

    pub fn faces_of_edges(&self, edges: Vec<u32>) -> Vec<u32> {
        lock(&self.held).poly.faces_of_edges(&pairs(&edges))
    }

    /// Which way `vertices` slide: the faces round them, together.
    pub fn direction(&self, vertices: Vec<u32>) -> Vec<f64> {
        lock(&self.held).poly.direction(&vertices).to_vec()
    }

    pub fn undo(&self) -> Option<String> {
        let mut h = lock(&self.held);
        let (poly, label) = h.undo.pop()?;
        let now = std::mem::replace(&mut h.poly, poly);
        h.redo.push((now, label.clone()));
        Some(label)
    }

    pub fn redo(&self) -> Option<String> {
        let mut h = lock(&self.held);
        let (poly, label) = h.redo.pop()?;
        let now = std::mem::replace(&mut h.poly, poly);
        h.undo.push((now, label.clone()));
        Some(label)
    }

    /// Write the mesh to `path`, or where it was read; it lives there from
    /// now on, and nothing it dropped is missed any more.
    pub fn save(&self, path: Option<String>) -> Result<(), DiffuseError> {
        let mut h = lock(&self.held);
        let path = path.map(PathBuf::from).unwrap_or_else(|| h.path.clone());
        let text = h.poly.write();
        let temp = path.with_extension("obj.writing");
        std::fs::write(&temp, text).and_then(|_| std::fs::rename(&temp, &path)).map_err(|e| failed(format!("{}: {e}", path.display())))?;
        h.saved = h.poly.clone();
        h.path = path;
        h.dropped.clear();
        Ok(())
    }

    /// The mesh as its file is written.
    pub fn text(&self) -> String {
        lock(&self.held).poly.write()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cube_file() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("aether-meshedit-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cube.obj");
        std::fs::write(&path, crate::model::scene_primitive("cube".into()).unwrap()).unwrap();
        path
    }

    #[test]
    fn edits_are_steps_and_a_drag_is_one() {
        let path = cube_file();
        let editor = MeshEditor::open(path.display().to_string()).unwrap();
        let cage = editor.cage();
        assert_eq!((cage.face_sizes.len(), cage.edges.len() / 2, cage.triangles.len() / 3), (6, 12, 12));
        assert!(cage.closed && !cage.dirty && cage.undo.is_none());

        let top = (0..6u32).find(|&f| editor.direction(cage.faces[f as usize * 4..f as usize * 4 + 4].to_vec())[1] > 0.9).unwrap();
        assert_eq!(editor.extrude(vec![top], 0.5), vec![top]);
        let corners = editor.cage().faces[top as usize * 4..top as usize * 4 + 4].to_vec();
        assert!(editor.move_vertices(corners.clone(), 0.0, 0.1, 0.0, "Move".into(), false));
        assert!(!editor.move_vertices(corners.clone(), 0.0, 0.1, 0.0, "Move".into(), true), "the rest of the drag joins it");
        assert_eq!(editor.cage().undo.as_deref(), Some("Move"));
        assert_eq!(editor.undo().as_deref(), Some("Move"));
        assert_eq!(editor.undo().as_deref(), Some("Extrude"));
        assert_eq!(editor.cage().face_sizes.len(), 6, "back to the cube");
        assert!(!editor.cage().dirty);
        assert_eq!(editor.redo().as_deref(), Some("Extrude"));
        assert!(editor.extrude(vec![99], 1.0).is_empty() && editor.cage().undo.as_deref() == Some("Extrude"), "nothing chosen is no step");

        let edge = editor.cage().edges[0..2].to_vec();
        assert!(editor.loop_cut(edge[0], edge[1], 0.5).is_ok());
        editor.save(None).unwrap();
        let again = MeshEditor::open(path.display().to_string()).unwrap();
        assert_eq!(again.cage().face_sizes, editor.cage().face_sizes, "written and read back the same");
        assert!(!editor.cage().dirty);
    }

    #[test]
    fn a_file_with_more_than_faces_says_so() {
        let path = cube_file();
        std::fs::write(&path, "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nf 1/1 2/1 3/1\n").unwrap();
        let editor = MeshEditor::open(path.display().to_string()).unwrap();
        assert_eq!(editor.dropped(), ["texture coordinates"]);
        std::fs::write(&path, "nothing here\n").unwrap();
        assert!(MeshEditor::open(path.display().to_string()).is_err());
    }
}
