use photon_poly::{key, Poly};

const CUBE: &str = "\
v -0.5 -0.5 -0.5
v 0.5 -0.5 -0.5
v -0.5 0.5 -0.5
v 0.5 0.5 -0.5
v -0.5 -0.5 0.5
v 0.5 -0.5 0.5
v -0.5 0.5 0.5
v 0.5 0.5 0.5
f 1 3 4 2
f 5 6 8 7
f 1 2 6 5
f 3 7 8 4
f 1 5 7 3
f 2 4 8 6
";

fn cube() -> Poly {
    Poly::parse(CUBE).unwrap().poly
}

/// The face pointing most nearly along `dir`.
fn facing(poly: &Poly, dir: [f64; 3]) -> u32 {
    (0..poly.faces.len())
        .max_by(|&a, &b| {
            let d = |f: usize| {
                let n = poly.face_normal(f);
                n[0] * dir[0] + n[1] * dir[1] + n[2] * dir[2]
            };
            d(a).total_cmp(&d(b))
        })
        .unwrap() as u32
}

fn close(a: [f64; 3], b: [f64; 3]) -> bool {
    (0..3).all(|i| (a[i] - b[i]).abs() < 1e-9)
}

#[test]
fn a_file_reads_as_faces_and_writes_back_the_same() {
    let read = Poly::parse(CUBE).unwrap();
    assert_eq!(read.poly.faces.len(), 6);
    assert!(read.poly.faces.iter().all(|f| f.len() == 4), "quads stay quads");
    assert!(read.dropped.is_empty() && read.skipped == 0);
    assert!(read.poly.closed());
    assert_eq!(read.poly.edges().len(), 12);
    let again = Poly::parse(&read.poly.write()).unwrap().poly;
    assert_eq!(again, read.poly);
    let (tris, owners) = read.poly.triangles();
    assert_eq!(tris.len(), 36);
    assert_eq!(owners[0..2], [0, 0], "each quad fans into two of its own");
}

#[test]
fn reading_says_what_writing_would_drop() {
    let read = Poly::parse("mtllib a.mtl\no Thing\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvn 0 0 1\nusemtl red\nf 1/1/1 2/1/1 3/1/1\nf 1 2 9\nf -3 -2 -1\n").unwrap();
    assert_eq!(read.poly.faces, vec![vec![0, 1, 2], vec![0, 1, 2]], "slashes and backward indices both read");
    assert_eq!(read.skipped, 1, "a corner past the end");
    assert_eq!(read.dropped, ["materials", "normals", "object and group names", "texture coordinates"]);
    assert!(Poly::parse("# nothing\n").is_err());
    assert!(Poly::parse("v 1 2\n").is_err());
}

#[test]
fn extruding_the_top_pulls_it_up_with_four_walls() {
    let mut poly = cube();
    let top = facing(&poly, [0.0, 1.0, 0.0]);
    let kept = poly.extrude(&[top], 1.0);
    assert_eq!(kept, [top], "the moved face stays at its number");
    assert_eq!(poly.faces.len(), 10, "four walls added");
    assert_eq!(poly.positions.len(), 12, "four new corners, none lost");
    assert!(poly.faces[top as usize].iter().all(|&v| (poly.positions[v as usize][1] - 1.5).abs() < 1e-9));
    assert!(poly.closed(), "still a solid");
    for wall in &poly.faces[6..] {
        let n = poly.face_normal(poly.faces.iter().position(|f| f == wall).unwrap());
        assert!(n[1].abs() < 1e-9, "the walls stand upright, facing out: {n:?}");
    }
}

#[test]
fn extruding_two_faces_together_makes_walls_only_round_the_rim() {
    let mut poly = cube();
    let top = facing(&poly, [0.0, 1.0, 0.0]);
    let side = facing(&poly, [1.0, 0.0, 0.0]);
    poly.extrude(&[top, side], 0.5);
    assert_eq!(poly.faces.len(), 6 + 6, "a rim of six edges, not eight walls");
    assert!(poly.closed());
}

#[test]
fn insetting_a_face_leaves_a_smaller_one_and_a_ring_of_quads() {
    let mut poly = cube();
    let top = facing(&poly, [0.0, 1.0, 0.0]);
    let kept = poly.inset(&[top], 0.1);
    assert_eq!(kept, [top]);
    assert_eq!(poly.faces.len(), 10);
    let inner: Vec<[f64; 3]> = poly.faces[top as usize].iter().map(|&v| poly.positions[v as usize]).collect();
    assert!(inner.iter().all(|p| (p[0].abs() - 0.4).abs() < 1e-9 && (p[2].abs() - 0.4).abs() < 1e-9), "every edge 0.1 in: {inner:?}");
    assert!(poly.closed());
    assert!(close(poly.face_normal(top as usize), [0.0, 1.0, 0.0]), "still facing up");
    let mut huge = cube();
    huge.inset(&[top], 10.0);
    assert!(huge.faces[top as usize].iter().all(|&v| huge.positions[v as usize][0].abs() > 0.0), "held short of the middle");
}

#[test]
fn a_loop_cut_goes_all_the_way_round_a_cube() {
    let mut poly = cube();
    // A vertical edge: the ring runs round the four sides.
    let edge = [0u32, 2u32];
    let made = poly.loop_cut(edge, 0.5).unwrap();
    assert_eq!(made.len(), 4, "a closed loop of four edges");
    assert_eq!(poly.faces.len(), 10, "four sides split in two");
    assert_eq!(poly.positions.len(), 12);
    assert!(poly.closed());
    for &[a, _] in &made {
        assert!(poly.positions[a as usize][1].abs() < 1e-9, "half way up");
    }
    let mut low = cube();
    low.loop_cut(edge, 0.25).unwrap();
    assert!(low.positions[8..].iter().all(|p| (p[1] + 0.25).abs() < 1e-9), "a quarter of the way from the first vertex's side");
}

#[test]
fn a_loop_cut_stops_at_the_edge_of_an_open_grid_and_beside_a_triangle() {
    // Two quads side by side, a triangle beside the second.
    let text = "v 0 0 0\nv 1 0 0\nv 2 0 0\nv 0 0 1\nv 1 0 1\nv 2 0 1\nv 3 0 0.5\nf 1 4 5 2\nf 2 5 6 3\nf 3 6 7\n";
    let mut poly = Poly::parse(text).unwrap().poly;
    let made = poly.loop_cut([0, 3], 0.5).unwrap();
    assert_eq!(made.len(), 2, "across both quads");
    assert_eq!(poly.faces.len(), 5);
    assert_eq!(poly.faces[2].len(), 4, "the triangle took the last new vertex into its rim");
    let edges = poly.edges();
    let rim = edges.iter().filter(|e| {
        let n = poly.faces.iter().filter(|f| (0..f.len()).any(|i| key(f[i], f[(i + 1) % f.len()]) == key(e[0], e[1]))).count();
        n == 1
    });
    assert_eq!(rim.count(), 8, "no gap opened: the outline gains one corner, the other new vertex is inside");
    assert!(Poly::parse(text).unwrap().poly.loop_cut([5, 6], 0.5).is_err(), "an edge with only a triangle beside it");
    assert!(poly.loop_cut([0, 6], 0.5).is_err(), "not an edge");
}

#[test]
fn moving_and_deleting() {
    let mut poly = cube();
    let top = facing(&poly, [0.0, 1.0, 0.0]);
    let corners = poly.faces[top as usize].clone();
    assert!(close(poly.direction(&corners), [0.0, 1.0, 0.0]), "the sides round them cancel, the top doesn't");
    assert!(close(poly.direction(&corners[..1]), { let k = 1.0 / 3f64.sqrt(); let p = poly.positions[corners[0] as usize]; [p[0].signum() * k, k, p[2].signum() * k] }), "one corner: out along its diagonal");
    poly.translate(&corners, [0.0, 0.25, 0.0]);
    assert!(corners.iter().all(|&v| (poly.positions[v as usize][1] - 0.75).abs() < 1e-9));
    assert_eq!(poly.faces_of_vertices(&corners), [top]);
    let edges: Vec<[u32; 2]> = (0..4).map(|i| [corners[i], corners[(i + 1) % 4]]).collect();
    assert_eq!(poly.faces_of_edges(&edges), [top]);

    let mut open = poly.clone();
    open.delete_faces(&[top]);
    assert_eq!((open.faces.len(), open.positions.len()), (5, 8), "the corners are still used by the sides");
    assert!(!open.closed());
    let mut fewer = poly.clone();
    fewer.delete_vertices(&[corners[0]]);
    assert_eq!((fewer.faces.len(), fewer.positions.len()), (3, 7));
    assert!(fewer.faces.iter().flatten().all(|&v| (v as usize) < fewer.positions.len()), "renumbered");
    let mut cut = poly;
    cut.delete_edges(&edges[..1]);
    assert_eq!(cut.faces.len(), 4, "the two faces along it");
}

/// A solid whose faces all wind the same way, outward from the middle,
/// with V − E + F = 2.
fn sound(poly: &Poly) {
    assert!(poly.closed(), "closed");
    let mut directed = std::collections::HashSet::new();
    for f in &poly.faces {
        for i in 0..f.len() {
            assert!(directed.insert((f[i], f[(i + 1) % f.len()])), "each edge run once each way");
        }
    }
    for f in 0..poly.faces.len() {
        let (c, n) = (poly.centroid(f), poly.face_normal(f));
        assert!(c[0] * n[0] + c[1] * n[1] + c[2] * n[2] > 0.0, "face {f} faces out");
    }
    let (v, e, f) = (poly.positions.len() as i64, poly.edges().len() as i64, poly.faces.len() as i64);
    assert_eq!(v - e + f, 2, "a sphere's worth of faces");
}

/// The cube's edge between the faces facing `a` and `b`.
fn between(poly: &Poly, a: [f64; 3], b: [f64; 3]) -> [u32; 2] {
    let (fa, fb) = (&poly.faces[facing(poly, a) as usize], &poly.faces[facing(poly, b) as usize]);
    let shared: Vec<u32> = fa.iter().copied().filter(|v| fb.contains(v)).collect();
    [shared[0], shared[1]]
}

#[test]
fn bevelling_one_edge_makes_a_face_and_two_pentagons() {
    let mut poly = cube();
    let edge = between(&poly, [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
    let made = poly.bevel(&[edge], 0.1).unwrap();
    assert_eq!(made, vec![6], "one new face, after the old ones");
    assert_eq!((poly.positions.len(), poly.faces.len()), (10, 7));
    let sizes: Vec<usize> = poly.faces.iter().map(|f| f.len()).collect();
    assert_eq!(sizes.iter().filter(|&&s| s == 5).count(), 2, "the ends take a corner each");
    sound(&poly);
    // The bevel faces up and forward, its sides 0.1 in from the edge.
    let n = poly.face_normal(6);
    assert!((n[1] - n[2]).abs() < 1e-9 && n[1] > 0.7);
    for &v in &poly.faces[6] {
        let p = poly.positions[v as usize];
        assert!(close([0.0, (p[1] - 0.5).abs().max((p[2] - 0.5).abs()), 0.0], [0.0, 0.1, 0.0]), "{p:?}");
    }
}

#[test]
fn bevelling_every_edge_of_a_cube_fills_its_corners() {
    let mut poly = cube();
    let edges = poly.edges();
    let made = poly.bevel(&edges, 0.1).unwrap();
    assert_eq!(made.len(), 12 + 8, "a face an edge, a triangle a corner");
    assert_eq!((poly.positions.len(), poly.faces.len()), (24, 26));
    assert!(poly.faces[20..].iter().all(|f| f.len() == 3));
    assert!(poly.faces[..6].iter().all(|f| f.len() == 4), "the old faces shrink, still quads");
    sound(&poly);
    let top = facing(&poly, [0.0, 1.0, 0.0]) as usize;
    assert!(poly.faces[top].iter().all(|&v| close(poly.positions[v as usize].map(f64::abs), [0.4, 0.5, 0.4])));
}

#[test]
fn bevelling_two_edges_meeting_at_a_corner_shares_their_end() {
    let mut poly = cube();
    let a = between(&poly, [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
    let b = between(&poly, [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]);
    let made = poly.bevel(&[a, b], 0.1).unwrap();
    assert_eq!(made.len(), 2, "two bevels, no corner to fill");
    sound(&poly);
}

#[test]
fn a_bevel_ending_among_four_faces_takes_in_the_gap() {
    let mut poly = cube();
    let cut = between(&poly, [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]);
    // A loop round the cube's middle, across the top at x = 0: the ends of
    // its edge there have four faces round them.
    poly.loop_cut(cut, 0.5).unwrap();
    let edge = poly
        .edges()
        .into_iter()
        .find(|e| [e[0], e[1]].iter().all(|&v| {
            let p = poly.positions[v as usize];
            p[0].abs() < 1e-9 && p[1] > 0.49
        }))
        .expect("the loop's edge across the top");
    let made = poly.bevel(&[edge], 0.1).unwrap();
    assert_eq!(made.len(), 1, "no triangle at the ends: they'd be flat");
    assert_eq!(poly.faces[made[0] as usize].len(), 6, "the bevel reaches back to where each end was");
    sound(&poly);
}

#[test]
fn a_bevel_too_wide_or_on_an_open_edge_is_refused() {
    let mut poly = cube();
    let before = poly.clone();
    let edges = poly.edges();
    assert!(poly.bevel(&edges, 0.5).is_err(), "two bevels meeting across a 1 m edge");
    assert!(poly.bevel(&[edges[0]], 0.0).is_err());
    assert!(poly.bevel(&[[0, 7]], 0.1).is_err(), "not an edge");
    assert_eq!(poly, before, "nothing changed");
    poly.delete_faces(&[0]);
    let rim = poly.edges().into_iter().find(|e| poly.faces.iter().filter(|f| f.contains(&e[0]) && f.contains(&e[1])).count() == 1).unwrap();
    assert!(poly.bevel(&[rim], 0.1).is_err());
}
