//! Material layers: Model's "Simple" materials, a base surface and a short
//! stack of layers over it, each covering what's below where its pattern
//! says.
//!
//! ## Written as a graph
//!
//! A scene's materials are Proton's node graphs, and stay so: a stack is
//! written as an ordinary graph of `mix`, `ramp`, `noise`, `checker`,
//! `principled` and `output` nodes, so Proton reads the file, the
//! compiler that turns graphs into shaders needs nothing new, and the full
//! graph is the same material seen another way. [`Stack::graph`] writes one;
//! [`Stack::read`] reads one back, and answers `None` for a graph that isn't
//! the shape a stack writes (one made by hand, or a stack's graph rewired),
//! rather than showing a stack that would lose part of it when written.
//!
//! ## The shape
//!
//! The base is the `principled` node's own settings. Each layer mixes the
//! colour, metal and roughness so far towards its own, by how much it
//! covers: its amount everywhere for a solid layer, or its amount times its
//! pattern for noise or checker. Noise passes through a ramp first, which
//! stretches it about a threshold: how much of the surface it covers, and
//! how hard its edge is. Mix clamps its factor, so a ramp whose ends lie
//! beyond 0 and 1 is a threshold and a contrast in one node the compiler
//! already knows.

use std::collections::BTreeSet;

use proton_scene::{GraphNode, Link, Material, Param, ParamValue};
use serde::{Deserialize, Serialize};

/// The most layers a stack takes: past a handful, a graph is the better
/// view.
pub const MOST: usize = 8;

/// A surface: its colour (linear RGB), how metallic and how rough.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Surface {
    pub color: [f64; 3],
    pub metallic: f64,
    pub roughness: f64,
}

impl Default for Surface {
    /// The principled node's own defaults.
    fn default() -> Surface {
        Surface { color: [0.8, 0.8, 0.8], metallic: 0.0, roughness: 0.5 }
    }
}

/// What decides where a layer covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pattern {
    /// Everywhere, by its amount.
    Solid,
    /// Fractal noise, thresholded.
    Noise,
    /// A three-dimensional checkerboard.
    Checker,
}

/// One layer over the base.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Layer {
    pub pattern: Pattern,
    pub surface: Surface,
    /// How much it covers where it covers, 0 to 1.
    pub amount: f64,
    /// A pattern's cells or blots a metre, in the object's own space.
    pub scale: f64,
    /// Noise's octaves, 1 to 8.
    pub detail: f64,
    /// How much of the surface noise covers, 0 to 1.
    pub coverage: f64,
    /// How hard noise's edge is: 0 the noise as it is, 1 a sharp line.
    pub edge: f64,
}

impl Layer {
    pub fn new(pattern: Pattern, surface: Surface) -> Layer {
        Layer { pattern, surface, amount: 1.0, scale: 4.0, detail: 3.0, coverage: 0.5, edge: 0.5 }
    }
}

/// A base surface and the layers over it, bottom first.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stack {
    pub base: Surface,
    pub layers: Vec<Layer>,
}

/// The noise's gain at the hardest edge: fractal noise mostly lies between
/// 0.25 and 0.75, so this takes a tenth of its range to cross from bare to
/// covered.
const GAIN: f64 = 15.0;

/// A layer's edge and coverage as the ramp's two ends, and back.
fn ramp_ends(edge: f64, coverage: f64) -> (f64, f64) {
    let gain = 1.0 + GAIN * edge.clamp(0.0, 1.0);
    let threshold = 0.75 - 0.5 * coverage.clamp(0.0, 1.0);
    (0.5 - threshold * gain, 0.5 + (1.0 - threshold) * gain)
}

fn edge_and_coverage(from: f64, to: f64) -> (f64, f64) {
    let gain = (to - from).max(1e-9);
    let threshold = (0.5 - from) / gain;
    (((gain - 1.0) / GAIN).clamp(0.0, 1.0), ((0.75 - threshold) / 0.5).clamp(0.0, 1.0))
}

/// The graph's node ids for layer `i` (from 1).
fn id(i: usize, part: &str) -> String {
    format!("layer{i}-{part}")
}

impl Stack {
    /// The stack as a material's graph, with `id` and `name`.
    pub fn graph(&self, id_: &str, name: &str) -> Material {
        let mut g = Graph::default();
        let base = &self.base;
        g.node("surface", "principled", [240.0 * (self.layers.len() + 1) as f64, 0.0], vec![
            ("baseColor", ParamValue::Color(base.color)),
            ("metallic", ParamValue::Number(base.metallic)),
            ("roughness", ParamValue::Number(base.roughness)),
        ]);
        g.node("out", "output", [240.0 * (self.layers.len() + 2) as f64, 0.0], vec![]);
        g.link("surface:bsdf", "out:surface");

        for (k, layer) in self.layers.iter().enumerate() {
            let i = k + 1;
            let x = 240.0 * i as f64;
            // Where it covers: a wire into each channel's mix, or the amount
            // as the mix's own factor for a solid layer.
            let cover = match layer.pattern {
                Pattern::Solid => None,
                Pattern::Noise => {
                    g.node(&id(i, "noise"), "noise", [x - 120.0, 300.0], vec![("scale", ParamValue::Number(layer.scale)), ("detail", ParamValue::Number(layer.detail))]);
                    let (from, to) = ramp_ends(layer.edge, layer.coverage);
                    g.node(&id(i, "edge"), "ramp", [x - 60.0, 300.0], vec![("from", ParamValue::Number(from)), ("to", ParamValue::Number(to))]);
                    g.link(&format!("{}:fac", id(i, "noise")), &format!("{}:fac", id(i, "edge")));
                    Some(id(i, "edge"))
                }
                Pattern::Checker => {
                    g.node(&id(i, "checker"), "checker", [x - 60.0, 300.0], vec![("scale", ParamValue::Number(layer.scale))]);
                    Some(id(i, "checker"))
                }
            };
            if let Some(source) = &cover {
                g.node(&id(i, "cover"), "mix", [x, 300.0], vec![("a", ParamValue::Number(0.0)), ("b", ParamValue::Number(layer.amount))]);
                g.link(&format!("{source}:result"), &format!("{}:fac", id(i, "cover")));
            }
            let channels = [
                ("color", ParamValue::Color(layer.surface.color), ParamValue::Color(base.color), "baseColor"),
                ("metal", ParamValue::Number(layer.surface.metallic), ParamValue::Number(base.metallic), "metallic"),
                ("rough", ParamValue::Number(layer.surface.roughness), ParamValue::Number(base.roughness), "roughness"),
            ];
            for (row, (part, value, under, _)) in channels.iter().enumerate() {
                let mut params = vec![("b", value.clone())];
                if i == 1 {
                    params.push(("a", under.clone()));
                }
                if cover.is_none() {
                    params.push(("fac", ParamValue::Number(layer.amount)));
                }
                g.node(&id(i, part), "mix", [x, 80.0 * row as f64], params);
                if i > 1 {
                    g.link(&format!("{}:result", id(i - 1, part)), &format!("{}:a", id(i, part)));
                }
                if cover.is_some() {
                    g.link(&format!("{}:result", id(i, "cover")), &format!("{}:fac", id(i, part)));
                }
            }
            if i == self.layers.len() {
                for (part, _, _, port) in channels {
                    g.link(&format!("{}:result", id(i, part)), &format!("surface:{port}"));
                }
            }
        }
        Material { id: id_.into(), name: name.into(), nodes: g.nodes, links: g.links }
    }

    /// The stack a graph was written from, or `None` when it isn't one a
    /// stack writes.
    pub fn read(material: &Material) -> Option<Stack> {
        let node = |id: &str| material.nodes.iter().find(|n| n.id == id);
        let number = |id: &str, name: &str| -> Option<f64> {
            match node(id)?.params.iter().find(|p| p.name == name)?.value {
                ParamValue::Number(n) => Some(n),
                ParamValue::Color(_) => None,
            }
        };
        let color = |id: &str, name: &str| -> Option<[f64; 3]> {
            match node(id)?.params.iter().find(|p| p.name == name)?.value {
                ParamValue::Color(c) => Some(c),
                ParamValue::Number(_) => None,
            }
        };
        let base = Surface { color: color("surface", "baseColor")?, metallic: number("surface", "metallic")?, roughness: number("surface", "roughness")? };
        let mut layers = Vec::new();
        let mut i = 1;
        while node(&id(i, "color")).is_some() {
            let pattern = if node(&id(i, "noise")).is_some() {
                Pattern::Noise
            } else if node(&id(i, "checker")).is_some() {
                Pattern::Checker
            } else {
                Pattern::Solid
            };
            let surface = Surface { color: color(&id(i, "color"), "b")?, metallic: number(&id(i, "metal"), "b")?, roughness: number(&id(i, "rough"), "b")? };
            let mut layer = Layer::new(pattern, surface);
            match pattern {
                Pattern::Solid => layer.amount = number(&id(i, "color"), "fac")?,
                Pattern::Noise => {
                    layer.amount = number(&id(i, "cover"), "b")?;
                    layer.scale = number(&id(i, "noise"), "scale")?;
                    layer.detail = number(&id(i, "noise"), "detail")?;
                    (layer.edge, layer.coverage) = edge_and_coverage(number(&id(i, "edge"), "from")?, number(&id(i, "edge"), "to")?);
                }
                Pattern::Checker => {
                    layer.amount = number(&id(i, "cover"), "b")?;
                    layer.scale = number(&id(i, "checker"), "scale")?;
                }
            }
            layers.push(layer);
            i += 1;
        }
        let stack = Stack { base, layers };
        // Only if writing it again makes the same graph: the same nodes of
        // the same kinds, wired the same way. Settings were read above, and
        // where boxes sit doesn't matter.
        let again = stack.graph(&material.id, &material.name);
        let shape = |m: &Material| -> (Pairs, Pairs) {
            (m.nodes.iter().map(|n| (n.id.clone(), n.kind.clone())).collect(), m.links.iter().map(|l| (l.from.clone(), l.to.clone())).collect())
        };
        (shape(&again) == shape(material)).then_some(stack)
    }

    /// A stack to start from for any material: one already, or the base its
    /// principled node sets, with no layers.
    pub fn starting_from(material: &Material) -> Stack {
        if let Some(stack) = Stack::read(material) {
            return stack;
        }
        let mut base = Surface::default();
        if let Some(surface) = material.nodes.iter().find(|n| n.kind == "principled") {
            for p in &surface.params {
                match (p.name.as_str(), &p.value) {
                    ("baseColor", ParamValue::Color(c)) => base.color = *c,
                    ("metallic", ParamValue::Number(n)) => base.metallic = *n,
                    ("roughness", ParamValue::Number(n)) => base.roughness = *n,
                    _ => {}
                }
            }
        }
        Stack { base, layers: Vec::new() }
    }

    /// The stack with its numbers in range and its layers no more than
    /// [`MOST`], or why it can't be kept.
    pub fn checked(mut self) -> Result<Stack, String> {
        if self.layers.len() > MOST {
            return Err(format!("a stack takes {MOST} layers at most"));
        }
        let fix = |s: &mut Surface| {
            s.color = s.color.map(|c| c.clamp(0.0, 1.0));
            s.metallic = s.metallic.clamp(0.0, 1.0);
            s.roughness = s.roughness.clamp(0.0, 1.0);
        };
        fix(&mut self.base);
        for layer in &mut self.layers {
            fix(&mut layer.surface);
            layer.amount = layer.amount.clamp(0.0, 1.0);
            layer.scale = layer.scale.clamp(0.01, 1000.0);
            layer.detail = layer.detail.round().clamp(1.0, 8.0);
            layer.coverage = layer.coverage.clamp(0.0, 1.0);
            layer.edge = layer.edge.clamp(0.0, 1.0);
        }
        let finite = |s: &Surface| s.color.iter().chain([&s.metallic, &s.roughness]).all(|x| x.is_finite());
        if !finite(&self.base) || self.layers.iter().any(|l| !finite(&l.surface) || ![l.amount, l.scale, l.detail, l.coverage, l.edge].iter().all(|x| x.is_finite())) {
            return Err("a layer's numbers must be numbers".into());
        }
        Ok(self)
    }
}

/// Node ids and kinds, or links' two ends: a graph's shape.
type Pairs = BTreeSet<(String, String)>;

/// A graph being written.
#[derive(Default)]
struct Graph {
    nodes: Vec<GraphNode>,
    links: Vec<Link>,
}

impl Graph {
    fn node(&mut self, id: &str, kind: &str, at: [f64; 2], params: Vec<(&str, ParamValue)>) {
        let mut params: Vec<Param> = params.into_iter().map(|(name, value)| Param { name: name.into(), value }).collect();
        // Sorted, as the scene reads them back.
        params.sort_by(|a, b| a.name.cmp(&b.name));
        self.nodes.push(GraphNode { id: id.into(), kind: kind.into(), at, params });
    }

    fn link(&mut self, from: &str, to: &str) {
        self.links.push(Link { from: from.into(), to: to.into() });
    }
}
