//! A mesh kept as polygons, for Model's Edit mode.
//!
//! `proton-mesh` reads an `.obj` into triangles, which is what a renderer
//! wants and what a modifier stack works on. Editing wants the faces as the
//! file has them: a quad stays a quad, so a loop cut can walk across it and
//! an extruded face keeps four sides. So this reads the same files into
//! [`Poly`], a list of positions and a list of faces (each a ring of vertex
//! numbers, counter-clockwise seen from outside, as OBJ has them), writes
//! them back, and makes the edits Edit mode offers: move, extrude, inset,
//! loop cut and delete.
//!
//! ## What writing loses
//!
//! The writer writes positions and faces, nothing else. Texture coordinates,
//! normals, materials and group names are dropped. Reading says which of
//! those a file had ([`Read::dropped`]), so the workspace can edit a copy
//! instead of losing them from a file Blender wrote.
//!
//! ## Face numbers stay put
//!
//! Every edit keeps the faces it was given at their numbers and adds new
//! ones at the end, so a selection of faces survives an edit. Vertices an
//! edit leaves unused are taken out, and the faces renumbered to match.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fmt::Write as _;

pub type Vec3 = [f64; 3];

/// Positions, and faces as rings of indices into them.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Poly {
    pub positions: Vec<Vec3>,
    pub faces: Vec<Vec<u32>>,
}

/// A file read: the mesh, the faces that couldn't be used, and what the
/// file had that writing it back would drop.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Read {
    pub poly: Poly,
    pub skipped: usize,
    pub dropped: Vec<String>,
}

fn sub(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn add(a: Vec3, b: Vec3) -> Vec3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn scale(a: Vec3, k: f64) -> Vec3 {
    [a[0] * k, a[1] * k, a[2] * k]
}
fn dot(a: Vec3, b: Vec3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: Vec3, b: Vec3) -> Vec3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn length(a: Vec3) -> f64 {
    dot(a, a).sqrt()
}
fn normalize(a: Vec3) -> Vec3 {
    let l = length(a);
    if l < 1e-12 {
        [0.0, 0.0, 0.0]
    } else {
        scale(a, 1.0 / l)
    }
}

/// An edge whichever way round it's named.
pub fn key(a: u32, b: u32) -> (u32, u32) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

/// A face's edges, in its winding: (v0, v1), (v1, v2), … (vn, v0).
fn ring(face: &[u32]) -> impl Iterator<Item = (u32, u32)> + '_ {
    (0..face.len()).map(move |i| (face[i], face[(i + 1) % face.len()]))
}

/// A number as the file writes it: six places, no `-0`, no trailing zeros.
fn num(x: f64) -> String {
    let r = (x * 1e6).round() / 1e6;
    if r == 0.0 {
        "0".into()
    } else {
        format!("{r}")
    }
}

impl Poly {
    /// Read an OBJ: its vertices and faces, any number of corners each.
    pub fn parse(text: &str) -> Result<Read, String> {
        let mut poly = Poly::default();
        let mut skipped = 0;
        let mut dropped = BTreeSet::new();
        for (at, line) in text.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            let mut words = line.split_whitespace();
            let Some(head) = words.next() else { continue };
            match head {
                "v" => {
                    let xs: Vec<f64> = words
                        .map(|w| w.parse::<f64>())
                        .collect::<Result<_, _>>()
                        .map_err(|_| format!("line {}: a vertex that isn't numbers", at + 1))?;
                    if xs.len() < 3 || xs[..3].iter().any(|x| !x.is_finite()) {
                        return Err(format!("line {}: a vertex needs three numbers", at + 1));
                    }
                    if xs.len() > 3 {
                        dropped.insert("vertex colours".to_string());
                    }
                    poly.positions.push([xs[0], xs[1], xs[2]]);
                }
                "f" => {
                    let count = poly.positions.len() as i64;
                    let mut face = Vec::new();
                    let mut bad = false;
                    for corner in words {
                        match corner.split('/').next().unwrap_or("").parse::<i64>() {
                            Ok(i) if i > 0 && i <= count => face.push((i - 1) as u32),
                            Ok(i) if i < 0 && -i <= count => face.push((count + i) as u32),
                            _ => bad = true,
                        }
                    }
                    face.dedup();
                    if face.len() > 1 && face.first() == face.last() {
                        face.pop();
                    }
                    if bad || face.len() < 3 {
                        skipped += 1;
                    } else {
                        poly.faces.push(face);
                    }
                }
                "vt" => {
                    dropped.insert("texture coordinates".to_string());
                }
                "vn" => {
                    dropped.insert("normals".to_string());
                }
                "usemtl" | "mtllib" => {
                    dropped.insert("materials".to_string());
                }
                "o" | "g" => {
                    dropped.insert("object and group names".to_string());
                }
                "s" => {
                    dropped.insert("smoothing groups".to_string());
                }
                "l" | "p" => {
                    dropped.insert("lines and points".to_string());
                }
                other => {
                    dropped.insert(format!("‘{other}’ lines"));
                }
            }
        }
        if poly.positions.is_empty() {
            return Err("there are no vertices in it".into());
        }
        Ok(Read { poly, skipped, dropped: dropped.into_iter().collect() })
    }

    /// The OBJ for it: positions and faces, nothing else.
    pub fn write(&self) -> String {
        let mut out = String::from("# Written by Aether's Model workspace\n");
        for p in &self.positions {
            let _ = writeln!(out, "v {} {} {}", num(p[0]), num(p[1]), num(p[2]));
        }
        for face in &self.faces {
            out.push('f');
            for v in face {
                let _ = write!(out, " {}", v + 1);
            }
            out.push('\n');
        }
        out
    }

    // MARK: Reading it

    /// A face's normal, its length twice the face's area (Newell's method,
    /// which holds for a face that isn't quite flat).
    fn area_normal(&self, face: usize) -> Vec3 {
        let mut n = [0.0; 3];
        for (a, b) in ring(&self.faces[face]) {
            let (p, q) = (self.positions[a as usize], self.positions[b as usize]);
            n[0] += (p[1] - q[1]) * (p[2] + q[2]);
            n[1] += (p[2] - q[2]) * (p[0] + q[0]);
            n[2] += (p[0] - q[0]) * (p[1] + q[1]);
        }
        n
    }

    pub fn face_normal(&self, face: usize) -> Vec3 {
        normalize(self.area_normal(face))
    }

    pub fn centroid(&self, face: usize) -> Vec3 {
        let f = &self.faces[face];
        let sum = f.iter().fold([0.0; 3], |s, &v| add(s, self.positions[v as usize]));
        scale(sum, 1.0 / f.len() as f64)
    }

    /// Every edge once, lower vertex first, in order.
    pub fn edges(&self) -> Vec<[u32; 2]> {
        let set: BTreeSet<(u32, u32)> = self.faces.iter().flat_map(|f| ring(f).map(|(a, b)| key(a, b))).collect();
        set.into_iter().map(|(a, b)| [a, b]).collect()
    }

    /// Triangles to draw, fanned from each face's first corner, and the face
    /// each one belongs to.
    pub fn triangles(&self) -> (Vec<u32>, Vec<u32>) {
        let mut tris = Vec::new();
        let mut owners = Vec::new();
        for (i, f) in self.faces.iter().enumerate() {
            for k in 1..f.len() - 1 {
                tris.extend_from_slice(&[f[0], f[k], f[k + 1]]);
                owners.push(i as u32);
            }
        }
        (tris, owners)
    }

    /// Whether every edge has a face on each side: a solid.
    pub fn closed(&self) -> bool {
        let mut uses: HashMap<(u32, u32), usize> = HashMap::new();
        for f in &self.faces {
            for (a, b) in ring(f) {
                *uses.entry(key(a, b)).or_default() += 1;
            }
        }
        !uses.is_empty() && uses.values().all(|&n| n == 2)
    }

    /// The faces whose every corner is among `vertices`.
    pub fn faces_of_vertices(&self, vertices: &[u32]) -> Vec<u32> {
        let set: HashSet<u32> = vertices.iter().copied().collect();
        (0..self.faces.len()).filter(|&f| self.faces[f].iter().all(|v| set.contains(v))).map(|f| f as u32).collect()
    }

    /// The faces whose every edge is among `edges`.
    pub fn faces_of_edges(&self, edges: &[[u32; 2]]) -> Vec<u32> {
        let set: HashSet<(u32, u32)> = edges.iter().map(|e| key(e[0], e[1])).collect();
        (0..self.faces.len()).filter(|&f| ring(&self.faces[f]).all(|(a, b)| set.contains(&key(a, b)))).map(|f| f as u32).collect()
    }

    /// Which way to slide `vertices`: the faces round them, averaged by
    /// area. Straight up when they have none, or cancel out.
    pub fn direction(&self, vertices: &[u32]) -> Vec3 {
        let set: HashSet<u32> = vertices.iter().copied().collect();
        let mut sum = [0.0; 3];
        for f in 0..self.faces.len() {
            if self.faces[f].iter().any(|v| set.contains(v)) {
                sum = add(sum, self.area_normal(f));
            }
        }
        let n = normalize(sum);
        if n == [0.0; 3] {
            [0.0, 1.0, 0.0]
        } else {
            n
        }
    }

    /// The faces' normal together.
    fn region_normal(&self, faces: &BTreeSet<usize>) -> Vec3 {
        let n = normalize(faces.iter().fold([0.0; 3], |s, &f| add(s, self.area_normal(f))));
        if n == [0.0; 3] {
            [0.0, 1.0, 0.0]
        } else {
            n
        }
    }

    fn chosen(&self, faces: &[u32]) -> BTreeSet<usize> {
        faces.iter().map(|&f| f as usize).filter(|&f| f < self.faces.len()).collect()
    }

    // MARK: Edits

    /// Move `vertices` by `delta`.
    pub fn translate(&mut self, vertices: &[u32], delta: Vec3) {
        let set: BTreeSet<u32> = vertices.iter().copied().filter(|&v| (v as usize) < self.positions.len()).collect();
        for v in set {
            let p = &mut self.positions[v as usize];
            *p = add(*p, delta);
        }
    }

    /// Pull `faces` out as one region by `distance` along their normal
    /// together, walls round its rim. Answers the faces moved, at their
    /// numbers, to stay chosen.
    pub fn extrude(&mut self, faces: &[u32], distance: f64) -> Vec<u32> {
        let chosen = self.chosen(faces);
        if chosen.is_empty() {
            return Vec::new();
        }
        let n = self.region_normal(&chosen);
        // An edge used once among the chosen faces is on the region's rim.
        let mut uses: HashMap<(u32, u32), usize> = HashMap::new();
        for &f in &chosen {
            for (a, b) in ring(&self.faces[f]) {
                *uses.entry(key(a, b)).or_default() += 1;
            }
        }
        let mut lifted: HashMap<u32, u32> = HashMap::new();
        let mut old = Vec::new();
        for &f in &chosen {
            for v in self.faces[f].clone() {
                if let std::collections::hash_map::Entry::Vacant(slot) = lifted.entry(v) {
                    slot.insert(self.positions.len() as u32);
                    self.positions.push(add(self.positions[v as usize], scale(n, distance)));
                    old.push(v);
                }
            }
        }
        let mut walls = Vec::new();
        for &f in &chosen {
            for (a, b) in ring(&self.faces[f]) {
                if uses[&key(a, b)] == 1 {
                    walls.push(vec![a, b, lifted[&b], lifted[&a]]);
                }
            }
        }
        for &f in &chosen {
            self.faces[f] = self.faces[f].iter().map(|v| lifted[v]).collect();
        }
        self.faces.extend(walls);
        self.compact(&old);
        chosen.into_iter().map(|f| f as u32).collect()
    }

    /// A smaller face inside each of `faces`, its edges `amount` in from
    /// the old ones, joined to them by a ring of quads. Answers the inner
    /// faces, at the old ones' numbers.
    pub fn inset(&mut self, faces: &[u32], amount: f64) -> Vec<u32> {
        let chosen = self.chosen(faces);
        if amount <= 0.0 {
            return chosen.into_iter().map(|f| f as u32).collect();
        }
        let mut sides = Vec::new();
        for &f in &chosen {
            let face = self.faces[f].clone();
            let k = face.len();
            let n = self.face_normal(f);
            let c = self.centroid(f);
            let pts: Vec<Vec3> = face.iter().map(|&v| self.positions[v as usize]).collect();
            let mut inner = Vec::with_capacity(k);
            for i in 0..k {
                let (prev, p, next) = (pts[(i + k - 1) % k], pts[i], pts[(i + 1) % k]);
                // Inward from each of the corner's two edges, and between.
                let a = normalize(cross(n, sub(p, prev)));
                let b = normalize(cross(n, sub(next, p)));
                let between = normalize(add(a, b));
                let d = dot(between, a);
                let reach = (if d > 1e-6 { amount / d } else { amount }).min(length(sub(c, p)) * 0.95);
                inner.push(self.positions.len() as u32);
                self.positions.push(add(p, scale(between, reach)));
            }
            for i in 0..k {
                sides.push(vec![face[i], face[(i + 1) % k], inner[(i + 1) % k], inner[i]]);
            }
            self.faces[f] = inner;
        }
        self.faces.extend(sides);
        chosen.into_iter().map(|f| f as u32).collect()
    }

    /// Cut a loop across the ring of quads `edge` is part of, `t` of the way
    /// along each edge it crosses (measured from `edge[0]`'s side). Answers
    /// the new loop's edges.
    pub fn loop_cut(&mut self, edge: [u32; 2], t: f64) -> Result<Vec<[u32; 2]>, String> {
        let t = t.clamp(0.02, 0.98);
        let mut faces_of: HashMap<(u32, u32), Vec<usize>> = HashMap::new();
        for (i, f) in self.faces.iter().enumerate() {
            for (a, b) in ring(f) {
                faces_of.entry(key(a, b)).or_default().push(i);
            }
        }
        let start = key(edge[0], edge[1]);
        let around = faces_of.get(&start).ok_or("that isn't an edge of the mesh")?.clone();
        let rail = (edge[0], edge[1]);
        let mut seen = HashSet::new();
        let (mut crosses, closed) = self.walk(&faces_of, around[0], rail, start, &mut seen);
        if !closed {
            if let Some(&other) = around.get(1) {
                let (back, _) = self.walk(&faces_of, other, rail, start, &mut seen);
                crosses.extend(back);
            }
        }
        if crosses.is_empty() {
            return Err("a loop cut runs across four-sided faces, and this edge has none beside it".into());
        }

        // A new vertex on each edge crossed, the same one from both sides.
        let mut cuts: HashMap<(u32, u32), u32> = HashMap::new();
        for c in &crosses {
            for (p, q) in [c.enter, c.leave] {
                cuts.entry(key(p, q)).or_insert_with(|| {
                    let (a, b) = (self.positions[p as usize], self.positions[q as usize]);
                    self.positions.push(add(a, scale(sub(b, a), t)));
                    (self.positions.len() - 1) as u32
                });
            }
        }
        let crossed: HashSet<usize> = crosses.iter().map(|c| c.face).collect();
        let mut loop_edges = Vec::new();
        for c in &crosses {
            let q = self.faces[c.face].clone();
            let j = (0..4).find(|&j| key(q[j], q[(j + 1) % 4]) == key(c.enter.0, c.enter.1)).expect("walked through it");
            let (m1, m2) = (cuts[&key(c.enter.0, c.enter.1)], cuts[&key(c.leave.0, c.leave.1)]);
            self.faces[c.face] = vec![q[j], m1, m2, q[(j + 3) % 4]];
            self.faces.push(vec![m1, q[(j + 1) % 4], q[(j + 2) % 4], m2]);
            loop_edges.push([m1.min(m2), m1.max(m2)]);
        }
        // A face beside the loop's ends that wasn't cut takes the new vertex
        // into its rim, so the surface stays whole.
        for (&(p, q), &m) in &cuts {
            for &f in faces_of.get(&(p, q)).into_iter().flatten() {
                if crossed.contains(&f) {
                    continue;
                }
                let face = &mut self.faces[f];
                let k = face.len();
                if let Some(i) = (0..k).find(|&i| key(face[i], face[(i + 1) % k]) == (p, q)) {
                    face.insert(i + 1, m);
                }
            }
        }
        loop_edges.sort();
        loop_edges.dedup();
        Ok(loop_edges)
    }

    /// From `face`, entered across `rail` (its first vertex on the side
    /// measured from), across each quad to its opposite edge, until a face
    /// that isn't a quad, the mesh's edge, or back at `start`.
    fn walk(&self, faces_of: &HashMap<(u32, u32), Vec<usize>>, mut face: usize, mut rail: (u32, u32), start: (u32, u32), seen: &mut HashSet<usize>) -> (Vec<Cross>, bool) {
        let mut crosses = Vec::new();
        loop {
            let q = &self.faces[face];
            if q.len() != 4 || !seen.insert(face) {
                return (crosses, false);
            }
            let Some(j) = (0..4).find(|&j| key(q[j], q[(j + 1) % 4]) == key(rail.0, rail.1)) else { return (crosses, false) };
            let leave = if q[j] == rail.0 { (q[(j + 3) % 4], q[(j + 2) % 4]) } else { (q[(j + 2) % 4], q[(j + 3) % 4]) };
            crosses.push(Cross { face, enter: rail, leave });
            if key(leave.0, leave.1) == start {
                return (crosses, true);
            }
            match faces_of.get(&key(leave.0, leave.1)).and_then(|fs| fs.iter().find(|&&g| g != face)) {
                Some(&g) => {
                    face = g;
                    rail = leave;
                }
                None => return (crosses, false),
            }
        }
    }

    /// Take out `faces`, and the vertices only they used.
    pub fn delete_faces(&mut self, faces: &[u32]) {
        let chosen = self.chosen(faces);
        let mut verts = Vec::new();
        for &f in chosen.iter().rev() {
            verts.extend(self.faces.remove(f));
        }
        self.compact(&verts);
    }

    /// Take out `vertices`, and every face using one.
    pub fn delete_vertices(&mut self, vertices: &[u32]) {
        let set: HashSet<u32> = vertices.iter().copied().collect();
        let faces: Vec<u32> = (0..self.faces.len()).filter(|&f| self.faces[f].iter().any(|v| set.contains(v))).map(|f| f as u32).collect();
        self.delete_faces(&faces);
        self.compact(vertices);
    }

    /// Take out every face along one of `edges`.
    pub fn delete_edges(&mut self, edges: &[[u32; 2]]) {
        let set: HashSet<(u32, u32)> = edges.iter().map(|e| key(e[0], e[1])).collect();
        let faces: Vec<u32> = (0..self.faces.len()).filter(|&f| ring(&self.faces[f]).any(|(a, b)| set.contains(&key(a, b)))).map(|f| f as u32).collect();
        self.delete_faces(&faces);
    }

    /// Take out those of `candidates` no face uses any more, renumbering.
    fn compact(&mut self, candidates: &[u32]) {
        let used: HashSet<u32> = self.faces.iter().flatten().copied().collect();
        let gone: HashSet<u32> = candidates.iter().copied().filter(|v| !used.contains(v) && (*v as usize) < self.positions.len()).collect();
        if gone.is_empty() {
            return;
        }
        let mut map = vec![0u32; self.positions.len()];
        let mut kept = Vec::with_capacity(self.positions.len() - gone.len());
        for (i, p) in self.positions.iter().enumerate() {
            if !gone.contains(&(i as u32)) {
                map[i] = kept.len() as u32;
                kept.push(*p);
            }
        }
        self.positions = kept;
        for f in &mut self.faces {
            for v in f.iter_mut() {
                *v = map[*v as usize];
            }
        }
    }
}

/// One quad a loop cut crosses: in across `enter`, out across `leave`, each
/// named from the side the cut is measured from.
#[derive(Debug, Clone, Copy)]
struct Cross {
    face: usize,
    enter: (u32, u32),
    leave: (u32, u32),
}
