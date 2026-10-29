use aether_layers::{Layer, Pattern, Stack, Surface, MOST};
use proton_scene::{Material, Op, Scene};

fn surface(color: [f64; 3], metallic: f64, roughness: f64) -> Surface {
    Surface { color, metallic, roughness }
}

fn three() -> Stack {
    let mut noise = Layer::new(Pattern::Noise, surface([0.3, 0.2, 0.1], 0.0, 0.9));
    noise.coverage = 0.3;
    noise.edge = 0.8;
    noise.scale = 6.5;
    let mut solid = Layer::new(Pattern::Solid, surface([0.1, 0.2, 0.9], 0.5, 0.2));
    solid.amount = 0.25;
    let checker = Layer::new(Pattern::Checker, surface([0.0, 0.0, 0.0], 1.0, 0.1));
    Stack { base: surface([0.9, 0.1, 0.1], 0.0, 0.5), layers: vec![noise, solid, checker] }
}

/// Through a scene file and back, as a save and an open would.
fn through_a_file(material: &Material) -> Material {
    let mut scene = Scene::new();
    assert!(scene.put_material(material));
    assert!(!scene.put_material(material), "the same graph again is no change");
    Scene::parse(&scene.to_text()).unwrap().materials().remove(0)
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-5
}

#[test]
fn a_stack_reads_back_from_its_graph_after_a_save() {
    let stack = three();
    let back = Stack::read(&through_a_file(&stack.graph("paint-1", "Paint"))).expect("a stack's own graph");
    assert_eq!(back.base, stack.base);
    assert_eq!(back.layers.len(), 3);
    for (a, b) in back.layers.iter().zip(&stack.layers) {
        assert_eq!((a.pattern, a.surface), (b.pattern, b.surface));
        assert!(close(a.amount, b.amount) && close(a.scale, b.scale) && close(a.detail, b.detail));
        if a.pattern == Pattern::Noise {
            assert!(close(a.coverage, b.coverage) && close(a.edge, b.edge), "{a:?}");
        }
    }
    assert_eq!(Stack::read(&Stack::default().graph("m", "M")), Some(Stack::default()), "no layers: the base alone");
}

/// The compiled program run at `point`, for the colour, metal and roughness.
fn run(material: &Material, point: [f32; 3]) -> ([f32; 3], f32, f32) {
    let shader = material.compile();
    assert!(shader.problem.is_empty(), "{}", shader.problem);
    let mut r: Vec<[f32; 3]> = Vec::new();
    for op in &shader.ops {
        let v = match *op {
            Op::Constant { value } => value,
            Op::Position => point,
            Op::Checker { at, scale } => {
                let c = r[at].map(|x| (x * scale).floor());
                [((c[0] + c[1] + c[2]).abs() % 2.0); 3]
            }
            Op::Noise { .. } => [0.5; 3],
            Op::Mix { a, b, fac } => {
                let f = r[fac][0].clamp(0.0, 1.0);
                [0, 1, 2].map(|i| r[a][i] + (r[b][i] - r[a][i]) * f)
            }
        };
        r.push(v);
    }
    (r[shader.base], r[shader.metallic][0], r[shader.roughness][0])
}

#[test]
fn each_layer_covers_what_is_under_it_by_its_amount_and_pattern() {
    let base = surface([1.0, 0.0, 0.0], 0.0, 0.5);
    let mut tint = Layer::new(Pattern::Solid, surface([0.0, 0.0, 1.0], 1.0, 0.1));
    tint.amount = 0.25;
    let (c, m, r) = run(&Stack { base, layers: vec![tint] }.graph("m", "M"), [0.1, 0.1, 0.1]);
    assert!(close(c[0] as f64, 0.75) && close(c[2] as f64, 0.25), "{c:?}");
    assert!(close(m as f64, 0.25) && close(r as f64, 0.5 + (0.1 - 0.5) * 0.25));

    // A checker over it: the odd cells are the checker's, the even the tint's.
    let mut checker = Layer::new(Pattern::Checker, surface([0.0, 1.0, 0.0], 0.0, 0.9));
    checker.scale = 1.0;
    let graph = Stack { base, layers: vec![tint, checker] }.graph("m", "M");
    let (even, _, _) = run(&graph, [0.5, 0.5, 0.5]);
    let (odd, _, rough) = run(&graph, [1.5, 0.5, 0.5]);
    assert!(close(even[0] as f64, 0.75) && close(even[1] as f64, 0.0));
    assert!(close(odd[1] as f64, 1.0) && close(rough as f64, 0.9), "{odd:?}");

    // Noise at its middle value, half covered, a hard edge: the threshold
    // sits at the middle, so the noise's 0.5 is exactly half way.
    let mut blots = Layer::new(Pattern::Noise, surface([0.0, 1.0, 0.0], 0.0, 0.5));
    blots.coverage = 0.5;
    blots.edge = 1.0;
    let (c, _, _) = run(&Stack { base, layers: vec![blots] }.graph("m", "M"), [0.0; 3]);
    assert!(close(c[1] as f64, 0.5), "{c:?}");
    blots.coverage = 0.9;
    let (c, _, _) = run(&Stack { base, layers: vec![blots] }.graph("m", "M"), [0.0; 3]);
    assert!(close(c[1] as f64, 1.0), "more coverage, past the edge: {c:?}");
}

#[test]
fn a_graph_made_by_hand_is_not_a_stack_but_starts_one() {
    let text = r#"{"format": "proton.scene", "objects": [], "materials": [{"id": "alu", "name": "Brushed aluminium",
      "nodes": [{"id": "noise-1", "kind": "noise", "at": [0, 0], "params": {"scale": 6}},
                {"id": "bsdf-1", "kind": "principled", "at": [1, 0], "params": {"baseColor": [0.55, 0.56, 0.58], "metallic": 0.9, "roughness": 0.24}},
                {"id": "out-1", "kind": "output", "at": [2, 0]}],
      "links": [{"from": "noise-1:fac", "to": "bsdf-1:roughness"}, {"from": "bsdf-1:bsdf", "to": "out-1:surface"}]}]}"#;
    let alu = Scene::parse(text).unwrap().materials().remove(0);
    assert_eq!(Stack::read(&alu), None);
    let start = Stack::starting_from(&alu);
    assert_eq!(start.base, surface([0.55, 0.56, 0.58], 0.9, 0.24));
    assert!(start.layers.is_empty());

    // A stack's graph with one wire moved is no longer one.
    let mut rewired = three().graph("m", "M");
    rewired.links.pop();
    assert_eq!(Stack::read(&rewired), None);
    assert_eq!(Stack::starting_from(&rewired).base, three().base, "but its base still starts one");
}

#[test]
fn checking_keeps_numbers_in_range_and_the_stack_short() {
    let mut stack = three();
    stack.base.roughness = 3.0;
    stack.layers[0].detail = 20.4;
    stack.layers[1].amount = -1.0;
    let fixed = stack.clone().checked().unwrap();
    assert_eq!((fixed.base.roughness, fixed.layers[0].detail, fixed.layers[1].amount), (1.0, 8.0, 0.0));
    stack.layers = vec![stack.layers[0]; MOST + 1];
    assert!(stack.clone().checked().is_err());
    stack.layers = vec![];
    stack.base.metallic = f64::NAN;
    assert!(stack.checked().is_err());
}

#[test]
fn an_object_wears_a_material_and_ids_are_fresh() {
    let mut scene = Scene::parse(r#"{"format": "proton.scene", "objects": [{"id": "cube-1", "name": "Cube", "kind": "mesh"}]}"#).unwrap();
    let id = scene.fresh_material_id("Cube’s paint");
    assert_eq!(id, "cube-s-paint-1");
    assert!(scene.wear("cube-1", &id).is_err(), "not there yet");
    scene.put_material(&three().graph(&id, "Cube’s paint"));
    assert_eq!(scene.fresh_material_id("Cube’s paint"), "cube-s-paint-2");
    assert!(scene.wear("cube-1", &id).unwrap());
    assert!(!scene.wear("cube-1", &id).unwrap());
    assert_eq!(scene.material_of("cube-1").map(|m| m.name), Some("Cube’s paint".into()));
    assert!(scene.wear("cube-1", "").unwrap());
    assert!(!scene.to_text().contains("\"material\":"), "none is no key");
    assert!(scene.wear("nobody", "").is_err());
}

#[test]
fn a_material_is_renamed_and_only_one_nobody_wears_is_taken_out() {
    let mut scene = Scene::parse(r#"{"format": "proton.scene", "objects": [
        {"id": "a-1", "name": "Cube", "kind": "mesh", "material": "paint-1"},
        {"id": "b-1", "name": "Ball", "kind": "mesh", "material": "paint-1"}]}"#).unwrap();
    scene.put_material(&three().graph("paint-1", "Paint"));
    scene.put_material(&Stack::default().graph("spare-1", "Spare"));
    assert!(scene.rename_material("paint-1", "Red paint").unwrap());
    assert!(!scene.rename_material("paint-1", " Red paint ").unwrap(), "trimmed, the same");
    assert!(scene.rename_material("paint-1", "  ").is_err());
    assert_eq!(scene.remove_material("paint-1").unwrap_err(), "Cube and 1 more wear it");
    assert!(scene.remove_material("spare-1").unwrap());
    assert_eq!(scene.materials().iter().map(|m| m.name.as_str()).collect::<Vec<_>>(), ["Red paint"]);
    assert!(scene.remove_material("spare-1").is_err(), "gone");
}

#[test]
fn a_stacks_graph_is_laid_out_wide_with_nothing_on_top_of_anything() {
    let graph = three().graph("m", "M");
    let mut places: Vec<[i64; 2]> = graph.nodes.iter().map(|n| [n.at[0] as i64, n.at[1] as i64]).collect();
    places.sort();
    let before = places.len();
    places.dedup();
    assert_eq!(places.len(), before, "no two nodes in one place");
    let x = |id: &str| graph.nodes.iter().find(|n| n.id == id).unwrap().at[0];
    assert!(x("layer1-color") < x("layer2-color") && x("layer3-color") < x("surface") && x("surface") < x("out"), "left to right as it flows");
    assert!(x("layer1-noise") < x("layer1-color"), "a layer's pattern before its mixes");
    let y = |id: &str| graph.nodes.iter().find(|n| n.id == id).unwrap().at[1];
    let tallest = graph.nodes.iter().map(|n| n.at[1]).fold(0.0, f64::max);
    assert!(tallest <= 180.0 && y("layer2-rough") == 180.0, "wide, not tall: three rows");
}
