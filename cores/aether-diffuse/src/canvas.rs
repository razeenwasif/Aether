//! Canvas: one canvas open for editing, carried to Swift.
//!
//! Proton kept two copies of a canvas: the core's, which it saved, and the
//! window's, in `proton-raster` built as WebAssembly (`proton-raster-runtime`),
//! painted the moment the pen moved and checked against the core's by hash.
//! Aether needs one: this object holds the canvas, its undo history and what
//! was last saved, as Proton's core did, and paints a stroke live and lays
//! the layers together as Proton's runtime did. The live half is that
//! runtime's, ported from a C ABI over thread-local state to an object:
//!
//! - A stroke is painted as the pen moves on the canvas itself, each tile
//!   from what was under it when the stroke began, and kept as the op it is.
//!   When it ends those tiles are put back and the op is applied through the
//!   history — the engine is whole numbers only, so it makes the same pixels
//!   — so it is one undo step; cancelled, the tiles are put back.
//! - Only what changed is laid together again: whole tiles, or the parts of
//!   them a brush's dabs fell in. While a stroke is drawn, the layers under
//!   its layer are laid together once per tile and kept, so a frame lays
//!   only the stroke's layer and those over it.
//! - A shape being dragged is shown and not kept: a preview, taken back.
//! - What is selected is given as its edges, for the marching ants, and
//!   lifted as pixels to be moved: the window draws them where the
//!   transform puts them until it is kept, then sends the one op it is.
//! - One frame is shown and drawn in. With onion skin, the frames either
//!   side are laid faintly under each layer, fainter the further they are,
//!   tinted red before and blue after; only cels in the frame shown or its
//!   onion skin are laid again when they change.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use proton_raster::blend::Onion;
use proton_raster::history::Patch;
use proton_raster::tile::TILE;
use proton_raster::{blend, brush, cel_of, file, port, select, stroke, Brush, Canvas, Dabs, Grid, History, Op, Preset, Stroke, Tile, Tip, Tool, SELECTION};
use serde::Deserialize;

use crate::{failed, json, lock, DiffuseError};

/// A whole tile, as a part of it.
const WHOLE: [u32; 4] = [0, 0, TILE, TILE];
/// Tiles of the layers under a stroke kept laid together: 8 MB at 16 bits.
const BELOW_MOST: usize = 256;
/// The most frames onion skin reaches each way.
const ONION_MOST: u32 = 5;

/// Onion skin as asked for: how many frames before and after, how strongly
/// the nearest shows (of 255), and whether tinted.
#[derive(Clone, Copy, Default)]
struct Skin {
    before: u32,
    after: u32,
    opacity: u8,
    tint: bool,
}

/// What a stroke being drawn covers: a pencil's pixels, or a brush's dabs.
enum Marks {
    Pencil(Stroke),
    Brush(Dabs),
}

/// A stroke as it is drawn: the tiles as they were under it, and what it
/// covers so far.
struct Live {
    layer: u32,
    tool: Tool,
    color: [u8; 4],
    lock: bool,
    marks: Marks,
    bases: BTreeMap<u32, Option<Arc<Tile>>>,
    sel: Option<Grid>,
}

impl Live {
    fn paint(&self, index: u32, base: Option<&Arc<Tile>>, part: Option<(&Option<Arc<Tile>>, [u32; 4])>, width: u32, height: u32) -> Option<Arc<Tile>> {
        let painted = match &self.marks {
            Marks::Pencil(s) => stroke::paint(&s.mask, index, base, self.tool, self.color, self.lock, width, height),
            Marks::Brush(d) => brush::paint(&d.mask, index, base, part, self.tool == Tool::Eraser, self.color, self.lock, width, height),
        };
        match &self.sel {
            Some(sel) => select::clip(sel, index, base, painted),
            None => painted,
        }
    }

    fn op(self) -> Op {
        match self.marks {
            Marks::Pencil(s) => Op::Stroke { layer: self.layer, tool: self.tool, tip: s.tip, color: self.color, pixel_perfect: s.pixel_perfect, points: s.points },
            Marks::Brush(d) => Op::Brush { layer: self.layer, erase: self.tool == Tool::Eraser, brush: d.brush, color: self.color, points: d.points },
        }
    }
}

/// The layers under a stroke's layer, laid together tile by tile while the
/// stroke is drawn: they don't change under it.
struct Below {
    place: u32,
    tiles: BTreeMap<u32, Vec<u16>>,
    order: VecDeque<u32>,
}

struct Held {
    canvas: Canvas,
    history: History,
    /// The canvas's state when last saved or opened; dirty when it differs.
    saved: u64,
    /// The folder it was opened from or saved to.
    dir: Option<PathBuf>,
    /// Premultiplied RGBA, the canvas's size.
    composite: Vec<u8>,
    /// Parts of tiles to lay together again.
    dirty: BTreeMap<u32, [u32; 4]>,
    live: Option<Live>,
    below: Option<Below>,
    preview: Option<Patch>,
    /// Bumped whenever what is selected may have changed.
    selection: u64,
    /// The frame shown and drawn in, from 0.
    shown: u32,
    skin: Skin,
    /// The frames onion skin shows now, nearest last.
    onion: Vec<Onion>,
}

impl Held {
    fn new(canvas: Canvas, dir: Option<PathBuf>) -> Held {
        let history = History::new(canvas.preset);
        let mut held = Held {
            saved: canvas.state,
            composite: vec![0; (canvas.width * canvas.height * 4) as usize],
            canvas,
            history,
            dir,
            dirty: BTreeMap::new(),
            live: None,
            below: None,
            preview: None,
            selection: 0,
            shown: 0,
            skin: Skin::default(),
            onion: Vec::new(),
        };
        held.redo_all();
        held
    }

    /// Whether a cel is seen: in the frame shown, or in its onion skin.
    fn seen(&self, id: u32) -> bool {
        let frame = cel_of(id).1;
        frame == self.shown || self.onion.iter().any(|o| o.frame == frame)
    }

    /// The frames onion skin shows, for the frame shown and the frames
    /// there are: the nearest strongest, the furthest faintest.
    fn reskin(&mut self) {
        let frames = self.canvas.frames.len().max(1) as u32;
        self.shown = self.shown.min(frames - 1);
        let s = self.skin;
        let reach = s.before.max(s.after).max(1);
        let mut onion = Vec::new();
        for d in (1..=reach).rev() {
            let opacity = (s.opacity as u32 * (reach + 1 - d) / reach) as u8;
            if d <= s.before && self.shown >= d {
                onion.push(Onion { frame: self.shown - d, opacity, tint: s.tint.then_some([255, 40, 40]) });
            }
            if d <= s.after && self.shown + d < frames {
                onion.push(Onion { frame: self.shown + d, opacity, tint: s.tint.then_some([40, 90, 255]) });
            }
        }
        self.onion = onion;
    }

    /// How many tiles the canvas is cut into.
    fn tiles(&self) -> u32 {
        let grid = Grid::new(self.canvas.width, self.canvas.height);
        grid.cols * grid.rows
    }

    /// Everything laid together again: the layers or the size changed.
    fn redo_all(&mut self) {
        self.below = None;
        let size = (self.canvas.width * self.canvas.height * 4) as usize;
        if self.composite.len() != size {
            self.composite = vec![0; size];
        }
        self.dirty = (0..self.tiles()).map(|i| (i, WHOLE)).collect();
    }

    fn mark(&mut self, index: u32, part: [u32; 4]) {
        let r = self.dirty.entry(index).or_insert(part);
        *r = [r[0].min(part[0]), r[1].min(part[1]), r[2].max(part[2]), r[3].max(part[3])];
    }

    /// What an op or an undo changed, to be laid together again.
    fn changed(&mut self, touched: &[(u32, u32)], meta: bool) {
        // A whole-canvas change — turned, cropped — moves the selection too.
        if meta || touched.iter().any(|&(layer, _)| layer == SELECTION) {
            self.selection += 1;
        }
        // Frames added or taken out move what is shown and its onion skin.
        let before = (self.shown, self.onion.iter().map(|o| o.frame).collect::<Vec<_>>());
        self.reskin();
        if meta || before != (self.shown, self.onion.iter().map(|o| o.frame).collect::<Vec<_>>()) {
            return self.redo_all();
        }
        for &(layer, index) in touched {
            if layer != SELECTION && self.seen(layer) {
                self.mark(index, WHOLE);
            }
        }
    }

    /// Lay together what is dirty, as much as `budget` pixel-layers allow;
    /// the parts laid, with their pixels.
    fn lay(&mut self, budget: u64) -> Vec<Laid> {
        let canvas = &self.canvas;
        let (frame, onion) = (self.shown, &self.onion);
        // Each layer is laid once, and once more for every frame of onion skin.
        let skins = 1 + onion.len() as u64;
        let grid = Grid::new(canvas.width, canvas.height);
        let layers = canvas.layers.len() as u32;
        let mut laid = Vec::new();
        let mut spent = 0u64;
        while let Some((index, part)) = self.dirty.pop_first() {
            let (x, y, tw, th) = grid.bounds(index);
            let part = [part[0], part[1], part[2].min(tw), part[3].min(th)];
            if part[0] >= part[2] || part[1] >= part[3] {
                continue;
            }
            let (w, h) = (part[2] - part[0], part[3] - part[1]);
            let present = canvas.layers.iter().filter(|l| !l.info.hidden && l.cels.get(frame as usize).and_then(|g| g.tile(index)).is_some()).count() as u64;
            let cost = skins
                * match self.below.as_ref() {
                    Some(b) if b.tiles.contains_key(&index) => (w * h) as u64 * (layers - b.place) as u64,
                    Some(b) => (TILE * TILE) as u64 * b.place as u64 + (w * h) as u64 * (layers - b.place) as u64,
                    None => (w * h) as u64 * present.max(1),
                };
            if spent > 0 && spent.saturating_add(cost) > budget {
                self.dirty.insert(index, part);
                break;
            }
            spent += cost;
            let acc = match self.below.as_mut() {
                Some(below) => {
                    if !below.tiles.contains_key(&index) {
                        let under = blend::fold(canvas, frame, index, WHOLE, 0, below.place, vec![0; (TILE * TILE * 4) as usize], onion);
                        below.tiles.insert(index, under.into_iter().map(|v| v as u16).collect());
                        below.order.push_back(index);
                        while below.order.len() > BELOW_MOST {
                            if let Some(gone) = below.order.pop_front() {
                                below.tiles.remove(&gone);
                            }
                        }
                    }
                    let under = &below.tiles[&index];
                    let mut acc = Vec::with_capacity((w * h * 4) as usize);
                    for row in 0..h {
                        let from = Tile::at(part[0], part[1] + row);
                        acc.extend(under[from..from + (w * 4) as usize].iter().map(|&v| v as u64));
                    }
                    blend::fold(canvas, frame, index, part, below.place, layers, acc, onion)
                }
                None => blend::fold(canvas, frame, index, part, 0, layers, vec![0; (w * h * 4) as usize], onion),
            };
            let px = blend::premultiplied(&acc);
            for row in 0..h {
                let from = (row * w * 4) as usize;
                let to = (((y + part[1] + row) * canvas.width + x + part[0]) * 4) as usize;
                self.composite[to..to + (w * 4) as usize].copy_from_slice(&px[from..from + (w * 4) as usize]);
            }
            laid.push(Laid { x: x + part[0], y: y + part[1], width: w, height: h, pixels: px });
        }
        laid
    }

    fn cancel(&mut self) {
        let Some(live) = self.live.take() else { return };
        self.below = None;
        let Some(target) = self.canvas.grid_mut(live.layer) else { return };
        let mut put = Vec::new();
        for (index, base) in live.bases {
            target.put(index, base);
            put.push(index);
        }
        for index in put {
            self.mark(index, WHOLE);
        }
    }

    fn clear_preview(&mut self) {
        let Some(patch) = self.preview.take() else { return };
        self.below = None;
        let (_, applied) = self.canvas.restore(patch);
        self.changed(&applied.touched, applied.meta);
    }
}

/// A part of the canvas laid together again: where, and its pixels,
/// premultiplied RGBA row by row.
#[derive(uniffi::Record)]
pub struct Laid {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

/// What is selected of a layer, lifted to be moved: the rectangle round
/// what it has, and its pixels, premultiplied RGBA row by row.
#[derive(uniffi::Record)]
pub struct Lifted {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

/// A colour's ramp for a palette: `steps` colours, darkest first, from
/// `spread` below its lightness to `spread` above (1/65536), the hue turning
/// by up to `shift` degrees as a painter's shading does. Straight RGBA, four
/// numbers a colour.
#[uniffi::export]
pub fn canvas_ramp(base: Vec<u8>, steps: u32, shift: u32, spread: u32) -> Vec<u8> {
    let base = [0, 1, 2, 3].map(|i| base.get(i).copied().unwrap_or(255));
    proton_raster::gen::color::ramp(base, steps, shift, spread).into_iter().flatten().collect()
}

/// The colours of a small picture, when it has few (32 at most): a pixel
/// canvas's palette, in the order first met, as Proton's import makes one.
fn palette_of(canvas: &Canvas) -> Vec<[u8; 4]> {
    let mut colours: Vec<[u8; 4]> = Vec::new();
    for grid in canvas.layers.iter().flat_map(|l| l.cels.iter()) {
        for y in 0..canvas.height {
            for x in 0..canvas.width {
                let p = grid.pixel(x, y);
                if p[3] == 255 && !colours.contains(&p) {
                    if colours.len() == 32 {
                        return Vec::new();
                    }
                    colours.push(p);
                }
            }
        }
    }
    colours
}

/// The pixels of `grid` within `rect`, straight RGBA row by row.
fn cut(grid: &Grid, [x, y, w, h]: [u32; 4]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for py in y..y + h {
        for px in x..x + w {
            rgba.extend_from_slice(&grid.pixel(px, py));
        }
    }
    rgba
}

/// A stroke begun: a pencil or eraser with a tip, or a brush.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Begin {
    layer: u32,
    tool: Tool,
    #[serde(default)]
    tip: Option<Tip>,
    #[serde(default)]
    brush: Option<Brush>,
    color: [u8; 4],
    #[serde(default)]
    pixel_perfect: bool,
}

/// One canvas open for editing (see the module's notes).
#[derive(uniffi::Object)]
pub struct CanvasEditor {
    held: Mutex<Held>,
}

fn preset(name: &str) -> Result<Preset, DiffuseError> {
    match name {
        "pixel" => Ok(Preset::Pixel),
        "paint" => Ok(Preset::Paint),
        other => Err(failed(format!("a canvas is pixel or paint, not {other}"))),
    }
}

#[uniffi::export]
impl CanvasEditor {
    /// A new canvas of `width` × `height`, `preset` "pixel" or "paint", with
    /// one layer; not written until saved.
    #[uniffi::constructor]
    pub fn create(width: u32, height: u32, preset_name: String) -> Result<Arc<CanvasEditor>, DiffuseError> {
        let preset = preset(&preset_name)?;
        let mut canvas = Canvas::new(width, height, preset).map_err(failed)?;
        if canvas.layers.is_empty() {
            canvas.push_layer("Layer 1".into());
        }
        // A pixel canvas starts with colours to pick from, as Proton's does.
        if preset == Preset::Pixel {
            canvas.palette = proton_raster::canvas::PALETTE16.to_vec();
        }
        let mut held = Held::new(canvas, None);
        // A new canvas is not dirty until something is drawn.
        held.saved = held.canvas.state;
        Ok(Arc::new(CanvasEditor { held: Mutex::new(held) }))
    }

    /// The canvas in folder `dir` (a `.canvas`: canvas.json and its PNGs).
    #[uniffi::constructor]
    pub fn open(dir: String) -> Result<Arc<CanvasEditor>, DiffuseError> {
        let canvas = file::load(Path::new(&dir)).map_err(failed)?;
        Ok(Arc::new(CanvasEditor { held: Mutex::new(Held::new(canvas, Some(PathBuf::from(dir)))) }))
    }

    /// A new canvas of a picture — a PNG, a PSD or an Aseprite file, its
    /// layers kept — Pixel when small, Paint when not, as Proton's import
    /// makes one. Not written until saved.
    #[uniffi::constructor]
    pub fn import(bytes: Vec<u8>, name: String) -> Result<Arc<CanvasEditor>, DiffuseError> {
        let picture = port::read(&bytes, &name).map_err(failed)?;
        let preset = port::preset_for(picture.width, picture.height);
        let mut canvas = port::canvas_of(&picture, preset).map_err(failed)?;
        if preset == Preset::Pixel && canvas.palette.is_empty() {
            canvas.palette = palette_of(&canvas);
        }
        let mut held = Held::new(canvas, None);
        // Not saved anywhere yet: dirty until it is.
        held.saved = u64::MAX;
        Ok(Arc::new(CanvasEditor { held: Mutex::new(held) }))
    }

    /// The canvas but its pixels, as JSON: `{width, height, preset, palette,
    /// layers (bottom to top), frames (each one's milliseconds), tags, shown,
    /// dirty, canUndo, canRedo, undo, redo}`.
    pub fn view(&self) -> String {
        let h = lock(&self.held);
        let (undo, redo) = h.history.labels();
        json(&serde_json::json!({
            "width": h.canvas.width,
            "height": h.canvas.height,
            "preset": h.canvas.preset,
            "palette": h.canvas.palette,
            "layers": h.canvas.infos(),
            "frames": h.canvas.frames,
            "tags": h.canvas.tags,
            "shown": h.shown,
            "dirty": h.canvas.state != h.saved,
            "canUndo": h.history.can_undo(),
            "canRedo": h.history.can_redo(),
            "undo": undo,
            "redo": redo,
        }))
    }

    /// Apply an op (JSON, Proton's shape) as one undo step, named `label`.
    /// Answers `{changed, touched, meta, made}`.
    pub fn apply(&self, op_json: String, label: String) -> Result<String, DiffuseError> {
        let op: Op = serde_json::from_str(&op_json).map_err(|e| failed(format!("not an edit: {e}")))?;
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let held = &mut *h;
        let applied = held.history.apply(&mut held.canvas, &op, &label).map_err(failed)?;
        let size_changed = held.composite.len() != (held.canvas.width * held.canvas.height * 4) as usize;
        held.changed(&applied.touched, applied.meta || size_changed);
        Ok(json(&serde_json::json!({ "changed": applied.changed, "touched": applied.touched, "meta": applied.meta, "made": applied.made })))
    }

    /// Undo a step; what it was, or `None` with nothing to undo.
    pub fn undo(&self) -> Option<String> {
        self.step(true)
    }

    pub fn redo(&self) -> Option<String> {
        self.step(false)
    }

    /// Begin a stroke (JSON: `{layer, tool, tip | brush, color, pixelPerfect}`).
    /// One being drawn is taken away first.
    pub fn stroke_begin(&self, begin_json: String) -> Result<(), DiffuseError> {
        let b: Begin = serde_json::from_str(&begin_json).map_err(|e| failed(format!("not a stroke: {e}")))?;
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let held = &mut *h;
        let canvas = &held.canvas;
        let layer = canvas.cel(b.layer).ok_or_else(|| failed(format!("there is no layer {}", b.layer)))?;
        if layer.info.locked {
            return Err(failed(format!("{} is locked", layer.info.name)));
        }
        let marks = match (b.brush, b.tip) {
            (Some(brush), _) => {
                brush.check().map_err(failed)?;
                Marks::Brush(Dabs::new(brush, canvas.width, canvas.height))
            }
            (None, Some(tip)) => {
                if !(1..=Tip::MOST).contains(&tip.size) {
                    return Err(failed(format!("a tip is 1 to {} pixels across", Tip::MOST)));
                }
                Marks::Pencil(Stroke::new(tip, b.pixel_perfect, canvas.width, canvas.height))
            }
            (None, None) => return Err(failed("a stroke needs a tip or a brush")),
        };
        let sel = canvas.selecting().then(|| canvas.selection.clone());
        let lock_alpha = layer.info.alpha_lock;
        held.below = canvas.place(cel_of(b.layer).0).filter(|&p| p > 0).map(|place| Below { place, tiles: BTreeMap::new(), order: VecDeque::new() });
        held.live = Some(Live { layer: b.layer, tool: b.tool, color: b.color, lock: lock_alpha, marks, bases: BTreeMap::new(), sel });
        Ok(())
    }

    /// More of the stroke: numbers in threes — x and y in 1/256 px, and the
    /// pen's pressure, 0 to 65535.
    pub fn stroke_add(&self, points: Vec<i32>) -> Result<(), DiffuseError> {
        let mut h = lock(&self.held);
        let held = &mut *h;
        let live = held.live.as_mut().ok_or_else(|| failed("no stroke is being drawn"))?;
        // A pencil's tiles are made again whole; a brush's only where its
        // dabs fell.
        let changed: Vec<(u32, Option<[u32; 4]>)> = match &mut live.marks {
            Marks::Pencil(s) => s.add(&points).into_iter().map(|i| (i, None)).collect(),
            Marks::Brush(d) => {
                d.add(&points);
                d.take_rects().into_iter().map(|(i, r)| (i, Some(r))).collect()
            }
        };
        let target = held.canvas.grid_mut(live.layer).ok_or_else(|| failed("the stroke's layer has gone"))?;
        let (width, height) = (target.width, target.height);
        let mut marks = Vec::new();
        for (index, part) in changed {
            let base = live.bases.entry(index).or_insert_with(|| target.tile(index).cloned()).clone();
            let now = target.tile(index).cloned();
            let painted = live.paint(index, base.as_ref(), part.map(|p| (&now, p)), width, height);
            target.put(index, painted);
            marks.push((index, part.unwrap_or(WHOLE)));
        }
        let layer = live.layer;
        if held.seen(layer) {
            for (index, part) in marks {
                held.mark(index, part);
            }
        }
        Ok(())
    }

    /// The stroke finished: one undo step, named `label`. Answers what
    /// changed, as `apply` does; a stroke that covered nothing changes
    /// nothing.
    pub fn stroke_end(&self, label: String) -> Result<String, DiffuseError> {
        let mut h = lock(&self.held);
        let held = &mut *h;
        let live = held.live.take().ok_or_else(|| failed("no stroke is being drawn"))?;
        held.below = None;
        // The tiles as they were, then the stroke made through the history:
        // the same pixels, as one step.
        if let Some(target) = held.canvas.grid_mut(live.layer) {
            for (index, base) in &live.bases {
                target.put(*index, base.clone());
            }
        }
        let touched_before: Vec<u32> = live.bases.keys().copied().collect();
        let op = live.op();
        let applied = held.history.apply(&mut held.canvas, &op, &label).map_err(failed)?;
        for index in touched_before {
            held.mark(index, WHOLE);
        }
        held.changed(&applied.touched, applied.meta);
        Ok(json(&serde_json::json!({ "changed": applied.changed, "touched": applied.touched, "meta": applied.meta, "made": applied.made })))
    }

    /// The stroke taken away, nothing kept.
    pub fn stroke_cancel(&self) {
        lock(&self.held).cancel();
    }

    /// An op shown and not kept — a shape being dragged. The last one shown
    /// is taken away first.
    pub fn preview(&self, op_json: String) -> Result<(), DiffuseError> {
        let op: Op = serde_json::from_str(&op_json).map_err(|e| failed(format!("not an edit: {e}")))?;
        if matches!(op, Op::Orient { .. } | Op::Resize { .. } | Op::Crop { .. } | Op::Upscale { .. } | Op::AddFrame { .. } | Op::RemoveFrame { .. } | Op::MoveFrame { .. }) {
            return Err(failed("that change isn't previewed"));
        }
        let mut h = lock(&self.held);
        h.clear_preview();
        let held = &mut *h;
        let (state, made, clip) = (held.canvas.state, held.canvas.made, held.canvas.clip.clone());
        held.below = None;
        let (applied, patch) = held.canvas.apply(&op).map_err(failed)?;
        (held.canvas.state, held.canvas.made, held.canvas.clip) = (state, made, clip);
        held.changed(&applied.touched, applied.meta);
        held.preview = Some(patch);
        Ok(())
    }

    pub fn preview_clear(&self) {
        lock(&self.held).clear_preview();
    }

    /// Lay together what changed, as much as `budget` pixel-layers allow
    /// (the rest waits for the next call): the parts laid, with pixels.
    pub fn lay(&self, budget: u64) -> Vec<Laid> {
        lock(&self.held).lay(budget)
    }

    /// How many parts wait to be laid together.
    pub fn pending(&self) -> u32 {
        lock(&self.held).dirty.len() as u32
    }

    /// Everything to be laid together again, as after opening.
    pub fn relay_all(&self) {
        lock(&self.held).redo_all();
    }

    /// A pixel of everything laid together, straight RGBA: the eyedropper's.
    pub fn pick(&self, x: u32, y: u32) -> Option<Vec<u8>> {
        let h = lock(&self.held);
        if x >= h.canvas.width || y >= h.canvas.height {
            return None;
        }
        let grid = Grid::new(h.canvas.width, h.canvas.height);
        let (index, tx, ty) = grid.locate(x, y);
        let acc = blend::tile(&h.canvas, h.shown, index);
        let i = Tile::at(tx, ty);
        Some(blend::straight(&acc[i..i + 4]))
    }

    /// Write the canvas into `dir` (a `.canvas` folder, made if it isn't
    /// there) — or where it was opened from or last saved, with none.
    pub fn save(&self, dir: Option<String>) -> Result<String, DiffuseError> {
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let dir = dir.map(PathBuf::from).or_else(|| h.dir.clone()).ok_or_else(|| failed("say where to save a new canvas"))?;
        file::save(&dir, &h.canvas).map_err(failed)?;
        h.saved = h.canvas.state;
        h.dir = Some(dir.clone());
        Ok(dir.display().to_string())
    }

    /// The frame shown laid together, as a PNG: for exporting and sending.
    pub fn png(&self) -> Result<Vec<u8>, DiffuseError> {
        let h = lock(&self.held);
        port::png(&h.canvas, h.shown, 1).map_err(failed)
    }

    // Frames and onion skin.

    /// Show frame `frame` (from 0, held to the frames there are): laid
    /// together again, its onion skin with it. A stroke or a preview under
    /// way is taken away first. Answers the frame shown.
    pub fn show_frame(&self, frame: u32) -> u32 {
        let mut h = lock(&self.held);
        let frame = frame.min(h.canvas.frames.len().max(1) as u32 - 1);
        if frame != h.shown {
            h.cancel();
            h.clear_preview();
            h.shown = frame;
            h.reskin();
            h.redo_all();
        }
        h.shown
    }

    /// Onion skin: how many frames before and after (to 5 each), how
    /// strongly the nearest shows (of 255), tinted or not; none with both
    /// counts 0.
    pub fn onion(&self, before: u32, after: u32, opacity: u32, tint: bool) {
        let mut h = lock(&self.held);
        h.skin = Skin { before: before.min(ONION_MOST), after: after.min(ONION_MOST), opacity: opacity.min(255) as u8, tint };
        h.reskin();
        h.redo_all();
    }

    /// Frame `frame` laid together at `width` × `height` (to 256 each), each
    /// pixel the one at its middle: premultiplied RGBA, for the timeline.
    pub fn thumb(&self, frame: u32, width: u32, height: u32) -> Vec<u8> {
        let held = lock(&self.held);
        let canvas = &held.canvas;
        let (w, h) = (width.clamp(1, 256), height.clamp(1, 256));
        let mut out = vec![0u8; (w * h * 4) as usize];
        if frame as usize >= canvas.frames.len() {
            return out;
        }
        let grid = Grid::new(canvas.width, canvas.height);
        for y in 0..h {
            let sy = ((2 * y + 1) * canvas.height / (2 * h)).min(canvas.height - 1);
            for x in 0..w {
                let sx = ((2 * x + 1) * canvas.width / (2 * w)).min(canvas.width - 1);
                let (index, tx, ty) = grid.locate(sx, sy);
                let px = blend::premultiplied(&blend::region(canvas, frame, index, [tx, ty, tx + 1, ty + 1]));
                let at = ((y * w + x) * 4) as usize;
                out[at..at + 4].copy_from_slice(&px);
            }
        }
        out
    }

    // Selections, moving pixels and the clipboard.

    /// A number that changes whenever what is selected may have: ask for
    /// the outline again when it does.
    pub fn selection_version(&self) -> u64 {
        lock(&self.held).selection
    }

    /// The edges of what is selected, as segments along pixels' sides — x0,
    /// y0, x1, y1, four numbers each — for the marching ants. None when
    /// nothing is.
    pub fn outline(&self) -> Vec<i32> {
        let h = lock(&self.held);
        if !h.canvas.selecting() {
            return Vec::new();
        }
        select::outline(&h.canvas.selection)
    }

    /// The rectangle round what is selected — left, top, width, height — or
    /// none when nothing is.
    pub fn selected(&self) -> Option<Vec<u32>> {
        let h = lock(&self.held);
        h.canvas.selecting().then(|| select::bounds(&h.canvas.selection)).flatten().map(Vec::from)
    }

    /// What is selected of cel `layer` — all of it, with nothing selected —
    /// cut out to the rectangle it covers, to be moved. None when there is
    /// nothing there, or the layer is locked.
    pub fn lift(&self, layer: u32) -> Option<Lifted> {
        let h = lock(&self.held);
        let cel = h.canvas.cel(layer).filter(|c| !c.info.locked)?;
        let (lifted, _) = select::split(cel.grid, &h.canvas.selection, h.canvas.selecting());
        let rect = select::bounds(&lifted)?;
        let pixels = cut(&lifted, rect)
            .chunks_exact(4)
            .flat_map(|p| {
                let a = p[3] as u32;
                [p[0], p[1], p[2]].map(|c| ((c as u32 * a + 127) / 255) as u8).into_iter().chain([p[3]])
            })
            .collect();
        Some(Lifted { x: rect[0], y: rect[1], width: rect[2], height: rect[3], pixels })
    }

    /// What was last copied, as a PNG of the part of the canvas it covers,
    /// for the system's clipboard. None if nothing was.
    pub fn clip_png(&self) -> Option<Vec<u8>> {
        let h = lock(&self.held);
        let clip = h.canvas.clip.as_ref()?;
        let rect = select::bounds(clip)?;
        file::encode_png(rect[2], rect[3], &cut(clip, rect)).ok()
    }

    /// A picture — a PNG, a PSD or an Aseprite file — brought in as layers
    /// over cel `above` (on top with none), one undo step. A lone picture
    /// smaller than the canvas goes in its middle; a file's layers where its
    /// own canvas has them. Answers what `apply` does, and `notes`: what was
    /// left out.
    pub fn bring_in(&self, bytes: Vec<u8>, name: String, above: Option<u32>) -> Result<String, DiffuseError> {
        let picture = port::read(&bytes, &name).map_err(failed)?;
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let held = &mut *h;
        let (w, ht, shown) = (held.canvas.width, held.canvas.height, held.shown);
        let frames = held.canvas.frames.len();
        let still = picture.frames.len() <= 1;
        fn first(p: &port::Part) -> Option<&port::Image> {
            p.cels.first().and_then(|c| c.as_ref())
        }
        let lone = still && picture.parts.len() == 1 && first(&picture.parts[0]).is_some_and(|c| c.left == 0 && c.top == 0);
        let centre = |pw: u32, ph: u32| if pw <= w && ph <= ht { [(w - pw) as i32 / 2, (ht - ph) as i32 / 2] } else { [0, 0] };
        let layers = picture
            .parts
            .iter()
            .map(|p| {
                let cels = if still {
                    // In the frame shown; clear in those before it.
                    let mut cels = vec![Grid::new(w, ht); shown as usize + 1];
                    if let Some(image) = first(p) {
                        cels[shown as usize] = port::grid_of(image, w, ht, if lone { centre(image.width, image.height) } else { [image.left, image.top] });
                    }
                    cels
                } else {
                    port::cels_of(p, w, ht, picture.frames.len().min(frames) as u32)
                };
                (p.name.clone(), p.opacity, !p.visible, p.blend, cels)
            })
            .collect();
        let mut notes = picture.notes.clone();
        if picture.frames.len() > frames {
            notes.push(format!("{name} has {} frames and the canvas {frames}; the frames past them were left out", picture.frames.len()));
        }
        let label = if picture.parts.len() == 1 { format!("Bring in {name}") } else { format!("Bring in {} layers", picture.parts.len()) };
        let applied = held.history.record(&mut held.canvas, &label, |c| c.bring_in(layers, above)).map_err(failed)?;
        held.changed(&applied.touched, applied.meta);
        Ok(json(&serde_json::json!({ "changed": applied.changed, "touched": applied.touched, "meta": applied.meta, "made": applied.made, "notes": notes })))
    }

    /// Cel `cel`'s pixels made a picture's (a PNG, one layer), one undo step
    /// named `label`: a linked layer taking its asset's newer version. A
    /// picture smaller than the canvas goes in its middle; a bigger one is cut
    /// at its right and bottom. Locked or not, as the link owns the layer.
    pub fn put_picture(&self, cel: u32, bytes: Vec<u8>, name: String, label: String) -> Result<String, DiffuseError> {
        let picture = port::read(&bytes, &name).map_err(failed)?;
        let image = match picture.parts.as_slice() {
            [part] => part.cels.first().and_then(|c| c.as_ref()).ok_or_else(|| failed(format!("{name} is empty")))?,
            parts => return Err(failed(format!("{name} has {} layers; a linked picture has one", parts.len()))),
        };
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let held = &mut *h;
        let (w, ht) = (held.canvas.width, held.canvas.height);
        let at = if image.width <= w && image.height <= ht { [(w - image.width) as i32 / 2, (ht - image.height) as i32 / 2] } else { [0, 0] };
        let grid = port::grid_of(image, w, ht, at);
        let applied = held
            .history
            .record(&mut held.canvas, &label, |c| {
                let patch = Patch { layers: Some((c.layers.clone(), c.next_id)), ..Patch::default() };
                let target = c.grid_mut(cel).ok_or_else(|| format!("there is no layer {cel}"))?;
                let changed = *target != grid;
                let touched = (0..grid.cols * grid.rows).map(|i| (cel, i)).collect();
                *target = grid;
                if changed {
                    c.advance();
                }
                Ok((proton_raster::Applied { changed, touched, meta: false, made: None }, patch))
            })
            .map_err(failed)?;
        held.changed(&applied.touched, applied.meta);
        Ok(json(&serde_json::json!({ "changed": applied.changed, "touched": applied.touched, "meta": applied.meta, "made": applied.made })))
    }
}

impl CanvasEditor {
    fn step(&self, back: bool) -> Option<String> {
        let mut h = lock(&self.held);
        h.cancel();
        h.clear_preview();
        let held = &mut *h;
        let (applied, label) = if back { held.history.undo(&mut held.canvas)? } else { held.history.redo(&mut held.canvas)? };
        let size_changed = held.composite.len() != (held.canvas.width * held.canvas.height * 4) as usize;
        held.changed(&applied.touched, applied.meta || size_changed);
        Some(json(&serde_json::json!({ "label": label, "touched": applied.touched, "meta": applied.meta })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn brush() -> String {
        r#"{"layer": 1, "tool": "pencil", "brush": {"size": 20, "hardness": 80, "spacing": 10, "flow": 255, "opacity": 255}, "color": [200, 40, 40, 255]}"#.into()
    }

    #[test]
    fn a_stroke_paints_live_and_ends_as_one_undo_step() {
        let editor = CanvasEditor::create(128, 128, "paint".into()).unwrap();
        let first = editor.lay(u64::MAX);
        assert!(!first.is_empty() && !serde_json::from_str::<serde_json::Value>(&editor.view()).unwrap()["dirty"].as_bool().unwrap());
        editor.stroke_begin(brush()).unwrap();
        editor.stroke_add(vec![10 * 256, 10 * 256, 65535, 100 * 256, 90 * 256, 65535]).unwrap();
        let live = editor.lay(u64::MAX);
        assert!(!live.is_empty(), "the stroke shows before it ends");
        let painted = editor.pick(55, 50).unwrap();
        assert!(painted[0] > 150 && painted[3] == 255, "{painted:?}");
        let ended: serde_json::Value = serde_json::from_str(&editor.stroke_end("Brush".into()).unwrap()).unwrap();
        assert_eq!(ended["changed"], true);
        assert_eq!(editor.pick(55, 50).unwrap(), painted, "the history makes the same pixels");
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!(view["dirty"], true);
        assert_eq!(view["undo"], "Brush");
        editor.undo().unwrap();
        editor.lay(u64::MAX);
        assert_eq!(editor.pick(55, 50).unwrap()[3], 0, "undone");
    }

    #[test]
    fn a_cancelled_stroke_leaves_nothing() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        editor.stroke_begin(r#"{"layer": 1, "tool": "pencil", "tip": {"size": 1, "round": false, "mirror": [null, null]}, "color": [0, 0, 0, 255]}"#.into()).unwrap();
        editor.stroke_add(vec![5 * 256, 5 * 256, 65535, 20 * 256, 5 * 256, 65535]).unwrap();
        assert_eq!(editor.pick(10, 5).unwrap()[3], 255);
        editor.stroke_cancel();
        assert_eq!(editor.pick(10, 5).unwrap()[3], 0);
        assert!(!serde_json::from_str::<serde_json::Value>(&editor.view()).unwrap()["canUndo"].as_bool().unwrap());
    }

    #[test]
    fn layers_and_previews_change_what_is_laid() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        let made: serde_json::Value = serde_json::from_str(&editor.apply(r#"{"op": "addLayer", "name": "Ink"}"#.into(), "New layer".into()).unwrap()).unwrap();
        let ink = made["made"].as_u64().unwrap();
        editor.apply(format!(r#"{{"op": "fillRect", "layer": {ink}, "rect": [0, 0, 8, 8], "color": [0, 255, 0, 255]}}"#), "Fill".into()).unwrap();
        assert_eq!(editor.pick(3, 3).unwrap(), vec![0, 255, 0, 255]);
        editor.preview(format!(r#"{{"op": "fillRect", "layer": {ink}, "rect": [10, 10, 4, 4], "color": [0, 0, 255, 255]}}"#)).unwrap();
        assert_eq!(editor.pick(11, 11).unwrap()[2], 255, "shown");
        editor.preview_clear();
        assert_eq!(editor.pick(11, 11).unwrap()[3], 0, "and taken back");
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!(view["layers"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn a_canvas_saves_reopens_and_imports_a_picture() {
        let dir = std::env::temp_dir().join(format!("aether-canvas-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let editor = CanvasEditor::create(32, 32, "pixel".into()).unwrap();
        editor.apply(r#"{"op": "fillRect", "layer": 1, "rect": [0, 0, 32, 32], "color": [10, 20, 30, 255]}"#.into(), "Fill".into()).unwrap();
        let path = dir.join("square.canvas").display().to_string();
        editor.save(Some(path.clone())).unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&editor.view()).unwrap()["dirty"], false);
        let again = CanvasEditor::open(path).unwrap();
        assert_eq!(again.pick(31, 31).unwrap(), vec![10, 20, 30, 255]);

        let png = editor.png().unwrap();
        let imported = CanvasEditor::import(png, "square.png".into()).unwrap();
        let view: serde_json::Value = serde_json::from_str(&imported.view()).unwrap();
        assert_eq!((view["width"].as_u64(), view["preset"].as_str()), (Some(32), Some("pixel")));
        assert_eq!(view["palette"], serde_json::json!([[10, 20, 30, 255]]), "a small picture's colours are its palette");
        let fresh: serde_json::Value = serde_json::from_str(&CanvasEditor::create(16, 16, "pixel".into()).unwrap().view()).unwrap();
        assert_eq!(fresh["palette"].as_array().unwrap().len(), 16, "a new pixel canvas starts with sixteen");
        assert_eq!(imported.pick(5, 5).unwrap(), vec![10, 20, 30, 255]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn what_is_selected_is_outlined_lifted_and_moved() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        editor.apply(r#"{"op": "fillRect", "layer": 1, "rect": [0, 0, 64, 64], "color": [255, 0, 0, 255]}"#.into(), "Fill".into()).unwrap();
        assert!(editor.outline().is_empty() && editor.selected().is_none());
        let before = editor.selection_version();
        editor.apply(r#"{"op": "select", "area": {"kind": "rect", "rect": [4, 4, 8, 6]}}"#.into(), "Select".into()).unwrap();
        assert_ne!(editor.selection_version(), before, "the window is told to ask again");
        assert_eq!(editor.selected(), Some(vec![4, 4, 8, 6]));
        let length: i32 = editor.outline().chunks_exact(4).map(|s| (s[2] - s[0]) + (s[3] - s[1])).sum();
        assert_eq!(length, 2 * 8 + 2 * 6);

        let lifted = editor.lift(1).unwrap();
        assert_eq!((lifted.x, lifted.y, lifted.width, lifted.height), (4, 4, 8, 6));
        assert_eq!(&lifted.pixels[..4], &[255, 0, 0, 255]);

        // Moved 20 right: each pixel of the result came from 20 to its left.
        let one = 65536;
        editor.apply(format!(r#"{{"op": "transform", "layer": 1, "bounds": [24, 4, 8, 6], "inverse": [{one}, 0, {}, 0, {one}, 0]}}"#, -20 * one), "Move".into()).unwrap();
        assert_eq!(editor.pick(5, 5).unwrap()[3], 0, "lifted from where it was");
        assert_eq!(editor.pick(25, 5).unwrap(), vec![255, 0, 0, 255]);
        assert_eq!(editor.selected(), Some(vec![24, 4, 8, 6]), "the selection moves with it");
        editor.undo().unwrap();
        assert_eq!(editor.selected(), Some(vec![4, 4, 8, 6]));

        // With nothing selected, all of the layer is lifted.
        editor.apply(r#"{"op": "select", "area": {"kind": "nothing"}}"#.into(), "Select nothing".into()).unwrap();
        let all = editor.lift(1).unwrap();
        assert_eq!((all.width, all.height), (64, 64));
    }

    #[test]
    fn a_copy_goes_to_the_clipboard_and_a_picture_comes_in_as_a_layer() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        assert!(editor.clip_png().is_none());
        editor.apply(r#"{"op": "fillRect", "layer": 1, "rect": [10, 10, 5, 3], "color": [0, 0, 255, 255]}"#.into(), "Fill".into()).unwrap();
        editor.apply(r#"{"op": "copy", "layer": 1}"#.into(), "Copy".into()).unwrap();
        let png = editor.clip_png().unwrap();
        let (w, h, rgba) = file::decode_png(&png).unwrap();
        assert_eq!((w, h, &rgba[..4]), (5, 3, &[0, 0, 255, 255][..]), "cut to what it covers");

        let applied: serde_json::Value = serde_json::from_str(&editor.bring_in(png, "Pasted".into(), Some(1)).unwrap()).unwrap();
        let made = applied["made"].as_u64().unwrap();
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        let layers = view["layers"].as_array().unwrap();
        assert_eq!((layers.len(), layers[1]["id"].as_u64()), (2, Some(made)), "over the layer said");
        // In the middle: (64 - 5) / 2, (64 - 3) / 2.
        let lifted = editor.lift(made as u32).unwrap();
        assert_eq!((lifted.x, lifted.y, lifted.width, lifted.height), (29, 30, 5, 3));
        editor.undo().unwrap();
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!(view["layers"].as_array().unwrap().len(), 1, "one undo step");
    }

    #[test]
    fn a_linked_layer_takes_a_newer_picture_as_one_step() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        editor.apply(r#"{"op": "fillRect", "layer": 1, "rect": [0, 0, 64, 64], "color": [255, 0, 0, 255]}"#.into(), "Fill".into()).unwrap();
        let other = CanvasEditor::create(8, 8, "pixel".into()).unwrap();
        other.apply(r#"{"op": "fillRect", "layer": 1, "rect": [0, 0, 8, 8], "color": [0, 0, 255, 255]}"#.into(), "Fill".into()).unwrap();
        let applied: serde_json::Value = serde_json::from_str(&editor.put_picture(1, other.png().unwrap(), "v2.png".into(), "Update".into()).unwrap()).unwrap();
        assert_eq!(applied["changed"], true);
        editor.lay(u64::MAX);
        // Smaller: in the middle, and the rest clear.
        assert_eq!((editor.pick(30, 30).unwrap(), editor.pick(1, 1).unwrap()[3]), (vec![0, 0, 255, 255], 0));
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!(view["undo"], "Update");
        editor.undo().unwrap();
        editor.lay(u64::MAX);
        assert_eq!(editor.pick(1, 1).unwrap(), vec![255, 0, 0, 255], "one undo step");
        assert!(editor.put_picture(9, other.png().unwrap(), "v2.png".into(), "Update".into()).is_err(), "no layer 9");
    }

    #[test]
    fn one_frame_is_shown_with_its_onion_skin_and_each_has_a_thumbnail() {
        let editor = CanvasEditor::create(64, 64, "pixel".into()).unwrap();
        let view = |e: &CanvasEditor| serde_json::from_str::<serde_json::Value>(&e.view()).unwrap();
        editor.apply(r#"{"op": "fillRect", "layer": 1, "rect": [0, 0, 4, 4], "color": [255, 0, 0, 255]}"#.into(), "Fill".into()).unwrap();
        editor.apply(r#"{"op": "addFrame"}"#.into(), "New frame".into()).unwrap();
        let second = 1 + 65536;
        editor.apply(format!(r#"{{"op": "fillRect", "layer": {second}, "rect": [10, 10, 4, 4], "color": [0, 0, 255, 255]}}"#), "Fill".into()).unwrap();
        assert_eq!((editor.pick(1, 1).unwrap(), editor.pick(11, 11).unwrap()[3]), (vec![255, 0, 0, 255], 0), "the first frame is shown");
        assert_eq!(view(&editor)["frames"].as_array().unwrap().len(), 2);

        assert_eq!(editor.show_frame(1), 1);
        editor.lay(u64::MAX);
        assert_eq!((editor.pick(11, 11).unwrap(), editor.pick(1, 1).unwrap()[3]), (vec![0, 0, 255, 255], 0), "and now the second");
        assert_eq!(view(&editor)["shown"], 1);

        // The frame before, faintly and tinted red, under the frame shown.
        editor.onion(1, 0, 110, true);
        let laid = editor.lay(u64::MAX);
        let tile = laid.iter().find(|l| l.x == 0 && l.y == 0 && l.width == 64).unwrap();
        let p = &tile.pixels[(64 + 1) * 4..(64 + 1) * 4 + 4];
        assert!(p[3] > 0 && p[3] < 255 && p[0] > p[2], "{p:?}");
        assert_eq!(editor.pick(1, 1).unwrap()[3], 0, "what is picked is the frame alone");

        let thumb = editor.thumb(0, 16, 16);
        assert_eq!((thumb.len(), &thumb[..4]), (16 * 16 * 4, &[255, 0, 0, 255][..]));
        assert_eq!(editor.show_frame(9), 1, "held to the frames there are");
        editor.apply(r#"{"op": "removeFrame", "frame": 1}"#.into(), "Remove frame".into()).unwrap();
        assert_eq!(view(&editor)["shown"], 0, "the frame shown taken out: the one before");
        assert_eq!(view(&editor)["tags"], serde_json::json!([]));
    }

    #[test]
    fn a_ramp_runs_dark_to_light_and_a_swatch_recolours_its_pixels() {
        let ramp = canvas_ramp(vec![176, 48, 63, 255], 5, 25, 24000);
        assert_eq!(ramp.len(), 5 * 4);
        let light = |c: &[u8]| c[0] as u32 + c[1] as u32 + c[2] as u32;
        assert!(ramp.chunks_exact(4).collect::<Vec<_>>().windows(2).all(|w| light(w[0]) < light(w[1])), "{ramp:?}");

        let editor = CanvasEditor::create(16, 16, "pixel".into()).unwrap();
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        let first: Vec<u8> = serde_json::from_value(view["palette"][0].clone()).unwrap();
        editor.apply(format!(r#"{{"op": "fillRect", "layer": 1, "rect": [0, 0, 4, 4], "color": {first:?}}}"#), "Fill".into()).unwrap();
        editor.apply(format!(r#"{{"op": "replaceColor", "from": {first:?}, "to": [1, 2, 3, 255], "swatch": 0}}"#), "Recolour".into()).unwrap();
        assert_eq!(editor.pick(1, 1).unwrap(), vec![1, 2, 3, 255], "every pixel of it");
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!(view["palette"][0], serde_json::json!([1, 2, 3, 255]), "and the swatch, one edit");
        editor.apply(r#"{"op": "resize", "width": 32, "height": 8}"#.into(), "Resize".into()).unwrap();
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        assert_eq!((view["width"].as_u64(), view["height"].as_u64()), (Some(32), Some(8)));
        assert_eq!(editor.pick(2, 0).unwrap(), vec![1, 2, 3, 255], "by the nearest pixel");
    }
}
