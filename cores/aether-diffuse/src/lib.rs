//! Aether's bridge to Proton's Diffuse core.
//!
//! `proton-diffuse` owns the flow format, every edit and its undo, what stops
//! a flow running, and the client for Nexus's image server. This crate only
//! carries those across to Swift. Anything structured crosses as JSON in the
//! shapes the crate's serde types already define, so Aether decodes exactly
//! what Proton's window decodes and nothing here has to change when a node
//! type or an event gains a field.
//!
//! Every call is synchronous and may block (a file, the network): Swift calls
//! them off the main actor.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use proton_diffuse::client::Events;
use proton_diffuse::{check, doc, layout, png, seal, templates, Catalogue, Client, Flow, FlowDoc, Graph, Key, Kind, Models, Op, Port, Problem, Seal};

uniffi::setup_scaffolding!();

mod canvas;
mod design;
mod game;
mod game_import;
pub use canvas::{CanvasEditor, Laid};
mod model;
pub use model::{SceneEditor, SceneMesh};
mod meshedit;
pub use meshedit::{MeshCage, MeshEditor};

/// What went wrong, in words a person can act on.
#[derive(Debug, uniffi::Error)]
pub enum DiffuseError {
    /// A file, a flow or an edit that could not be done.
    Failed { message: String },
    /// The gateway or forge: `kind` is `unreachable`, `key`, `offline`,
    /// `invalid`, `server`, `unreadable` or `lost`.
    Gateway { kind: String, message: String },
}

impl std::fmt::Display for DiffuseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DiffuseError::Failed { message } | DiffuseError::Gateway { message, .. } => f.write_str(message),
        }
    }
}

impl std::error::Error for DiffuseError {}

fn failed(message: impl Into<String>) -> DiffuseError {
    DiffuseError::Failed { message: message.into() }
}

impl From<proton_diffuse::Error> for DiffuseError {
    fn from(e: proton_diffuse::Error) -> DiffuseError {
        use proton_diffuse::Error as E;
        let kind = match &e {
            E::Unreachable(_) => "unreachable",
            E::Key => "key",
            E::Offline => "offline",
            E::Invalid { .. } => "invalid",
            E::Server { .. } => "server",
            E::Unreadable(_) => "unreadable",
            E::Lost(_) => "lost",
        };
        DiffuseError::Gateway { kind: kind.into(), message: e.describe() }
    }
}

/// A lock that a panic elsewhere does not poison: the value behind it is
/// replaced whole by every edit, so it is never half-changed.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|e| format!("{{\"error\":{:?}}}", e.to_string()))
}

fn models(models_json: Option<String>) -> Result<Option<Models>, DiffuseError> {
    models_json
        .map(|text| serde_json::from_str::<Models>(&text).map_err(|e| failed(format!("the model lists: {e}"))))
        .transpose()
}

// MARK: - The node catalogue

/// What a server can run: its node types and their inputs and outputs.
#[derive(uniffi::Object)]
pub struct NodeCatalogue {
    inner: Catalogue,
}

#[uniffi::export]
impl NodeCatalogue {
    /// The catalogue from a server's `GET /nodes` JSON, or a copy of it.
    #[uniffi::constructor]
    pub fn parse(json: String) -> Result<Arc<NodeCatalogue>, DiffuseError> {
        Catalogue::parse(&json).map(|inner| Arc::new(NodeCatalogue { inner })).map_err(failed)
    }

    /// The catalogue as the server wrote it.
    pub fn json(&self) -> String {
        json(&self.inner)
    }
}

// MARK: - Sealed files

/// The key Proton seals Diffuse's files with, out of the person's keychain.
/// Its bytes go in and never come back out.
#[derive(uniffi::Object)]
pub struct SealKey {
    seal: Seal,
}

#[uniffi::export]
impl SealKey {
    #[uniffi::constructor]
    pub fn new(key: Vec<u8>) -> Result<Arc<SealKey>, DiffuseError> {
        let key: [u8; 32] = key.as_slice().try_into().map_err(|_| failed("a seal key is 32 bytes"))?;
        Ok(Arc::new(SealKey { seal: Seal::new(key) }))
    }
}

impl std::fmt::Debug for SealKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SealKey(…)")
    }
}

/// A file's bytes, `path` being the file itself, `.sealed` or not: opened
/// with `key` when they are sealed, as they are when they are not.
#[uniffi::export]
pub fn read_file(path: String, key: Option<Arc<SealKey>>) -> Result<Vec<u8>, DiffuseError> {
    let bytes = std::fs::read(&path).map_err(|e| failed(format!("{path}: {e}")))?;
    if !seal::is_sealed(&bytes) {
        return Ok(bytes);
    }
    let key = key.ok_or_else(|| failed(format!("{path} is sealed: unlock Diffuse to read it")))?;
    key.seal.open(&bytes).map_err(|why| failed(format!("{path}: {why}")))
}

/// Write `bytes` for `path`, whole or not at all: sealed beside it as
/// `path.sealed` with `key`, plain without. Answers where it went.
#[uniffi::export]
pub fn write_file(path: String, bytes: Vec<u8>, key: Option<Arc<SealKey>>) -> Result<String, DiffuseError> {
    seal::write(Path::new(&path), &bytes, key.as_ref().map(|k| &k.seal))
        .map(|to| to.display().to_string())
        .map_err(failed)
}

// MARK: - Pictures a flow sends

/// Keep a picture for a flow's Load Image under `root`'s `inputs/`, as
/// Proton's Diffuse keeps one: only a PNG, named `inputs/<name>.png` from
/// `name` made safe; the same bytes as a picture already of that name are
/// that file, other bytes take `-2`, `-3`. Sealed with `key`, plain
/// without. Answers the name the flow gives it, relative to `root`.
#[uniffi::export]
pub fn keep_picture(root: String, name: String, bytes: Vec<u8>, key: Option<Arc<SealKey>>) -> Result<String, DiffuseError> {
    png::head(bytes.as_slice()).ok_or_else(|| failed("only a PNG is kept"))?;
    let stem: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '-' }).collect();
    let stem = stem.trim_matches('-');
    let stem = if stem.is_empty() { "picture" } else { stem };
    let root = Path::new(&root);
    let seal = key.as_ref().map(|k| &k.seal);
    let mut rel = format!("inputs/{stem}.png");
    let mut n = 2;
    while seal::exists(&root.join(&rel)) {
        if seal::read(&root.join(&rel), seal).is_ok_and(|there| there == bytes) {
            return Ok(rel);
        }
        rel = format!("inputs/{stem}-{n}.png");
        n += 1;
    }
    seal::write(&root.join(&rel), &bytes, seal).map_err(|e| failed(format!("{rel}: {e}")))?;
    Ok(rel)
}

/// A picture as forge takes it, read from its plain name `file` (sealed or
/// not): with a mask (white where painted, Proton's `<flow>.<node>.mask.png`)
/// put in its alpha, transparent where masked, as ComfyUI's Load Image reads
/// one; without, the file as it is.
#[uniffi::export]
pub fn upload_bytes(file: String, mask: Option<String>, key: Option<Arc<SealKey>>) -> Result<Vec<u8>, DiffuseError> {
    let seal = key.as_ref().map(|k| &k.seal);
    let name = |p: &str| Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let bytes = seal::read(Path::new(&file), seal).map_err(failed)?;
    let Some(mask) = mask else { return Ok(bytes) };
    let (w, h, mut rgba) = proton_raster::file::decode_png(&bytes).map_err(|e| failed(format!("{}: {e}", name(&file))))?;
    let painted = seal::read(Path::new(&mask), seal).map_err(failed)?;
    let (mw, mh, shade) = proton_raster::file::decode_png(&painted).map_err(|e| failed(format!("{}: {e}", name(&mask))))?;
    if (mw, mh) != (w, h) {
        return Err(failed(format!("the mask is {mw} × {mh} and the picture {w} × {h}: paint the mask again")));
    }
    for (pixel, painted) in rgba.chunks_exact_mut(4).zip(shade.chunks_exact(4)) {
        // How much is masked: the mask's brightness, as far as it is opaque.
        let masked = (painted[0] as u32 * painted[3] as u32 / 255) as u8;
        pixel[3] = pixel[3].min(255 - masked);
    }
    proton_raster::file::encode_png(w, h, &rgba).map_err(failed)
}

/// A mask's pixels: how painted each is, 0 to 255, row by row.
#[derive(uniffi::Record)]
pub struct MaskPixels {
    pub width: u32,
    pub height: u32,
    pub coverage: Vec<u8>,
}

/// A mask kept as a PNG, read as `upload_bytes` reads it: each pixel's
/// brightness, as far as it is opaque, is how painted it is.
#[uniffi::export]
pub fn mask_from_png(bytes: Vec<u8>) -> Result<MaskPixels, DiffuseError> {
    let (width, height, rgba) = proton_raster::file::decode_png(&bytes).map_err(failed)?;
    let coverage = rgba.chunks_exact(4).map(|p| (p[0] as u32 * p[3] as u32 / 255) as u8).collect();
    Ok(MaskPixels { width, height, coverage })
}

/// A mask as Proton keeps it: a PNG, white where painted on black.
#[uniffi::export]
pub fn mask_to_png(width: u32, height: u32, coverage: Vec<u8>) -> Result<Vec<u8>, DiffuseError> {
    if coverage.len() != width as usize * height as usize {
        return Err(failed(format!("a {width} × {height} mask has {} pixels, not {}", width * height, coverage.len())));
    }
    let rgba: Vec<u8> = coverage.iter().flat_map(|&c| [c, c, c, 255]).collect();
    proton_raster::file::encode_png(width, height, &rgba).map_err(failed)
}

/// The pictures a graph sends: each upload field with a value, as
/// `[{"node", "field", "value"}]`, the value being the picture's plain name
/// relative to the flow's folder.
#[uniffi::export]
pub fn graph_pictures(graph_json: String, catalogue: Arc<NodeCatalogue>) -> Result<String, DiffuseError> {
    let graph: Graph = serde_json::from_str(&graph_json).map_err(|e| failed(format!("a graph: {e}")))?;
    let mut out = Vec::new();
    for node in &graph.nodes {
        let Some(kind) = catalogue.inner.node(&node.kind) else { continue };
        for field in kind.fields().filter(|f| f.kind() == Kind::Upload) {
            if let Some(value) = node.values.get(&field.name).and_then(serde_json::Value::as_str) {
                out.push(serde_json::json!({ "node": node.id, "field": field.name, "value": value }));
            }
        }
    }
    Ok(json(&out))
}

/// The graph with each picture named by forge's upload of it:
/// `uploads_json` is `[{"node", "field", "id"}]`.
#[uniffi::export]
pub fn graph_with_uploads(graph_json: String, uploads_json: String) -> Result<String, DiffuseError> {
    #[derive(serde::Deserialize)]
    struct Named {
        node: String,
        field: String,
        id: String,
    }
    let mut graph: Graph = serde_json::from_str(&graph_json).map_err(|e| failed(format!("a graph: {e}")))?;
    let named: Vec<Named> = serde_json::from_str(&uploads_json).map_err(|e| failed(format!("the uploads: {e}")))?;
    for upload in named {
        if let Some(node) = graph.nodes.iter_mut().find(|n| n.id == upload.node) {
            node.values.insert(upload.field, serde_json::Value::String(upload.id));
        }
    }
    Ok(json(&graph))
}

// MARK: - A flow open for editing

/// One `.flow.json`: changed by batches of ops, each one undo step, written
/// on save beside the file and renamed over it.
#[derive(uniffi::Object)]
pub struct FlowDocument {
    doc: Mutex<FlowDoc>,
    sealed: AtomicBool,
}

#[uniffi::export]
impl FlowDocument {
    /// The flow `path` names: its sealed file, `path.sealed`, opened with
    /// `key` when there is one, else the plain file. It is saved the way it
    /// was found, so a plain flow stays plain even when a key is given.
    #[uniffi::constructor]
    pub fn open(path: String, key: Option<Arc<SealKey>>) -> Result<Arc<FlowDocument>, DiffuseError> {
        let path = Path::new(&path);
        let sealed = seal::sealed_path(path).is_file();
        let seal = if sealed { key.as_ref().map(|k| &k.seal) } else { None };
        let doc = FlowDoc::read_sealed(path, seal).map_err(failed)?;
        Ok(Arc::new(FlowDocument { doc: Mutex::new(doc), sealed: AtomicBool::new(sealed) }))
    }

    /// A flow that exists in memory until it is saved to `path`.
    #[uniffi::constructor]
    pub fn create(path: String, flow_json: String) -> Result<Arc<FlowDocument>, DiffuseError> {
        let flow = doc::parse(&flow_json).map_err(failed)?;
        Ok(Arc::new(FlowDocument { doc: Mutex::new(FlowDoc::fresh(Path::new(&path), flow)), sealed: AtomicBool::new(false) }))
    }

    /// Whether it is saved sealed.
    pub fn is_sealed(&self) -> bool {
        self.sealed.load(Ordering::Relaxed)
    }

    /// Save it sealed with `key` from now on, or plain without. For a flow
    /// not yet written, or written somewhere new: one already on disk would
    /// leave its other file behind.
    pub fn seal_with(&self, key: Option<Arc<SealKey>>) {
        let mut doc = lock(&self.doc);
        self.sealed.store(key.is_some(), Ordering::Relaxed);
        *doc = doc.clone().sealed_with(key.map(|k| k.seal.clone()));
    }

    pub fn path(&self) -> String {
        lock(&self.doc).path().display().to_string()
    }

    /// The flow now, in the `.flow.json` shape.
    pub fn flow_json(&self) -> String {
        json(lock(&self.doc).get())
    }

    /// The flow as its file's text.
    pub fn text(&self) -> String {
        lock(&self.doc).text()
    }

    /// Apply a batch of ops (a JSON array) as one undo step, all of it or
    /// none, checked against `catalogue`. Answers what it did as JSON:
    /// `{"changed": bool, "added": [ids]}`.
    pub fn apply(&self, ops_json: String, catalogue: Arc<NodeCatalogue>) -> Result<String, DiffuseError> {
        let ops: Vec<Op> = serde_json::from_str(&ops_json).map_err(|e| failed(format!("an edit: {e}")))?;
        let applied = lock(&self.doc).apply(&ops, &catalogue.inner).map_err(failed)?;
        Ok(json(&applied))
    }

    /// Replace the whole flow as one undo step.
    pub fn replace(&self, flow_json: String) -> Result<(), DiffuseError> {
        let flow = doc::parse(&flow_json).map_err(failed)?;
        lock(&self.doc).replace(flow);
        Ok(())
    }

    pub fn undo(&self) -> bool {
        lock(&self.doc).undo()
    }

    pub fn redo(&self) -> bool {
        lock(&self.doc).redo()
    }

    pub fn can_undo(&self) -> bool {
        lock(&self.doc).can_undo()
    }

    pub fn can_redo(&self) -> bool {
        lock(&self.doc).can_redo()
    }

    pub fn is_dirty(&self) -> bool {
        lock(&self.doc).is_dirty()
    }

    /// Write it, whole or not at all.
    pub fn save(&self) -> Result<(), DiffuseError> {
        lock(&self.doc).save().map_err(failed)
    }

    /// The file changed under it: take what it says, as an undoable step.
    pub fn reread(&self) -> Result<bool, DiffuseError> {
        lock(&self.doc).reread().map_err(failed)
    }

    /// Everything that stops the flow running, as a JSON array of
    /// `{"node", "input", "message"}`. `models_json` is the server's model
    /// lists when known.
    pub fn problems(&self, catalogue: Arc<NodeCatalogue>, models_json: Option<String>) -> Result<String, DiffuseError> {
        let models = models(models_json)?;
        Ok(json(&check(lock(&self.doc).get(), &catalogue.inner, models.as_ref())))
    }

    /// The graph a run sends, as JSON, or the problems that stop it.
    pub fn graph(&self, catalogue: Arc<NodeCatalogue>, models_json: Option<String>) -> Result<String, DiffuseError> {
        let models = models(models_json)?;
        let graph = lock(&self.doc).get().graph(&catalogue.inner, models.as_ref()).map_err(refused)?;
        Ok(json(&graph))
    }

    /// The graph a run to `node` sends: only what that node needs, every
    /// other output left out. A node that is not an output itself is
    /// followed by a Preview Image — after a VAE Decode when it makes a
    /// latent — so the run shows what it makes. The flow itself is not
    /// changed.
    pub fn graph_to(&self, node: String, catalogue: Arc<NodeCatalogue>, models_json: Option<String>) -> Result<GraphTo, DiffuseError> {
        let models = models(models_json)?;
        let catalogue = &catalogue.inner;
        let flow = lock(&self.doc).get().clone();
        let target = flow.nodes.iter().find(|n| n.id == node).ok_or_else(|| failed(format!("there is no node {node}")))?;
        if target.bypass.0 {
            return Err(failed(format!("node {node} is bypassed: restore it to run to it")));
        }
        let kind = catalogue.node(&target.kind).ok_or_else(|| failed(format!("the server has no {} node", target.kind)))?;
        let mut run = FlowDoc::fresh(Path::new("run-to-here.flow.json"), flow.clone());
        // Every other output bypassed, not removed: a removed node's id
        // would be free for a node added here, and the run's news about
        // it would land on the flow's own node of that id.
        let others: Vec<Op> = flow
            .nodes
            .iter()
            .filter(|n| n.id != node && catalogue.node(&n.kind).is_some_and(|k| k.is_output()))
            .map(|n| Op::Bypass { id: n.id.clone(), on: true })
            .collect();
        if !others.is_empty() {
            run.apply(&others, catalogue).map_err(failed)?;
        }
        let mut shows = node.clone();
        if !kind.is_output() {
            let output = |socket: &str| kind.outputs.iter().find(|o| o.socket == socket).map(|o| format!("{node}:{}", o.name));
            let right = [target.at[0] + 260.0, target.at[1]];
            let add = |run: &mut FlowDoc, kind: &str, at: [f64; 2]| -> Result<String, DiffuseError> {
                let op = Op::Add { kind: kind.into(), at, values: Default::default() };
                run.apply(&[op], catalogue).map_err(failed)?.added.pop().ok_or_else(|| failed(format!("no {kind} was added")))
            };
            let image = if let Some(image) = output("IMAGE") {
                image
            } else if let Some(latent) = output("LATENT") {
                let vae = vae_for(&flow, catalogue, &node)
                    .ok_or_else(|| failed("a latent is shown through a VAE: the flow needs a Load Checkpoint or a VAE loader"))?;
                let decode = add(&mut run, "VAEDecode", right)?;
                run.apply(
                    &[Op::Connect { from: vae, to: format!("{decode}:vae") }, Op::Connect { from: latent, to: format!("{decode}:latent") }],
                    catalogue,
                )
                .map_err(failed)?;
                format!("{decode}:image")
            } else {
                return Err(failed(format!("Run to here shows a picture, and node {node} makes neither an image nor a latent")));
            };
            let preview = add(&mut run, "PreviewImage", [right[0] + 260.0, right[1]])?;
            run.apply(&[Op::Connect { from: image, to: format!("{preview}:images") }], catalogue).map_err(failed)?;
            shows = preview;
        }
        let graph = run.get().graph(catalogue, models.as_ref()).map_err(refused)?;
        Ok(GraphTo { graph: json(&graph), shows })
    }
}

/// A run to one node: the graph it sends, as JSON, and the node in it whose
/// picture is that node's — a Preview Image added after it, or itself.
#[derive(uniffi::Record)]
pub struct GraphTo {
    pub graph: String,
    pub shows: String,
}

/// What stops a flow running, in a line: each problem with its node.
fn refused(problems: Vec<Problem>) -> DiffuseError {
    let each: Vec<String> = problems
        .iter()
        .map(|p| match &p.node {
            Some(node) => format!("node {node}: {}", p.message),
            None => p.message.clone(),
        })
        .collect();
    failed(each.join("; "))
}

/// Where a latent from `from` is decoded from: the nearest node upstream of
/// it with a VAE out, else any in the flow.
fn vae_for(flow: &Flow, catalogue: &Catalogue, from: &str) -> Option<String> {
    let vae_of = |id: &str| {
        let node = flow.nodes.iter().find(|n| n.id == id)?;
        let output = catalogue.node(&node.kind)?.outputs.iter().find(|o| o.socket == "VAE")?;
        Some(format!("{id}:{}", output.name))
    };
    let mut seen = std::collections::BTreeSet::new();
    let mut queue = std::collections::VecDeque::from([from.to_string()]);
    while let Some(id) = queue.pop_front() {
        if !seen.insert(id.clone()) {
            continue;
        }
        if id != from {
            if let Some(vae) = vae_of(&id) {
                return Some(vae);
            }
        }
        for link in &flow.links {
            if let (Some(f), Some(t)) = (Port::parse(&link.from), Port::parse(&link.to)) {
                if t.node == id {
                    queue.push_back(f.node);
                }
            }
        }
    }
    flow.nodes.iter().find_map(|n| vae_of(&n.id))
}

// MARK: - Starter flows and layout

/// A starter flow: what the editor calls it and what it is for.
#[derive(uniffi::Record)]
pub struct Template {
    pub name: String,
    pub title: String,
    pub summary: String,
}

/// The starters there are.
#[uniffi::export]
pub fn templates() -> Vec<Template> {
    templates::TEMPLATES
        .iter()
        .map(|(name, title, summary)| Template {
            name: name.to_string(),
            title: title.to_string(),
            summary: summary.to_string(),
        })
        .collect()
}

/// A starter's ops as a JSON array, to apply to an empty flow.
#[uniffi::export]
pub fn template_ops(name: String) -> Option<String> {
    templates::ops(&name).map(|ops| json(&ops))
}

/// A graph that came without places — out of a PNG — laid out as a flow.
#[uniffi::export]
pub fn flow_from_graph(graph_json: String, catalogue: Arc<NodeCatalogue>) -> Result<String, DiffuseError> {
    let graph: Graph = serde_json::from_str(&graph_json).map_err(|e| failed(format!("a graph: {e}")))?;
    Ok(json(&layout::flow_from_graph(&graph, &catalogue.inner)))
}

/// The flow format this build writes and the latest it reads.
#[uniffi::export]
pub fn flow_format() -> u32 {
    proton_diffuse::FORMAT
}

/// What an output PNG says of itself, read from its head and never its
/// pixels: `{"width", "height", "graph", "made"}`, the graph being the one
/// forge wrote into it as `proton-flow` (or null) and `made` its seed,
/// settings and prompt. `None` for a file that is not a PNG, and for a
/// sealed one (`.png.sealed`) without `key`, which has to be opened whole.
#[uniffi::export]
pub fn png_head(path: String, key: Option<Arc<SealKey>>) -> Option<String> {
    let head = if path.ends_with(seal::SEALED) {
        let bytes = read_file(path, Some(key?)).ok()?;
        png::head(std::io::Cursor::new(bytes))?
    } else {
        let file = std::fs::File::open(&path).ok()?;
        png::head(std::io::BufReader::new(file))?
    };
    let graph = head.flow.as_deref().and_then(png::graph_of);
    let made = graph.as_ref().map(png::made);
    Some(json(&serde_json::json!({ "width": head.width, "height": head.height, "graph": graph, "made": made })))
}

// MARK: - Nexus's image server

/// The gateway on atlas, at its home and away addresses, with the key.
#[derive(uniffi::Object)]
pub struct Gateway {
    client: Client,
}

#[uniffi::export]
impl Gateway {
    /// A gateway at `bases` (`http://atlas:7420/img/v1`, then the Tailscale
    /// address), sending `key` as a bearer token. The key is never logged or
    /// shown.
    #[uniffi::constructor]
    pub fn new(bases: Vec<String>, key: String) -> Result<Arc<Gateway>, DiffuseError> {
        let key = Key::new(&key).ok_or_else(|| failed("the gateway key is empty or has spaces in it"))?;
        Ok(Arc::new(Gateway { client: Client::new(bases, key) }))
    }

    /// The address that answered last.
    pub fn base(&self) -> Option<String> {
        self.client.base().map(str::to_string)
    }

    /// How the gateway and forge are, as JSON (`state`, `url`, `ms`,
    /// `status`, `message`).
    pub fn health(&self) -> String {
        json(&self.client.health())
    }

    /// `GET /nodes`.
    pub fn catalogue(&self) -> Result<Arc<NodeCatalogue>, DiffuseError> {
        Ok(Arc::new(NodeCatalogue { inner: self.client.nodes()? }))
    }

    /// `GET /models`, as JSON.
    pub fn models(&self) -> Result<String, DiffuseError> {
        Ok(json(&self.client.models()?))
    }

    /// `POST /uploads`: a PNG or JPEG, answered as `{"id", "width", "height"}`.
    pub fn upload(&self, bytes: Vec<u8>) -> Result<String, DiffuseError> {
        Ok(json(&self.client.upload(&bytes)?))
    }

    /// `POST /runs`: queue a graph (as JSON); answered as `{"run", "position"}`.
    pub fn run(&self, graph_json: String) -> Result<String, DiffuseError> {
        let graph: Graph = serde_json::from_str(&graph_json).map_err(|e| failed(format!("a graph: {e}")))?;
        Ok(json(&self.client.run(&graph)?))
    }

    pub fn cancel(&self, run: String) -> Result<(), DiffuseError> {
        Ok(self.client.cancel(&run)?)
    }

    /// `GET /images/{image}`: an output's PNG.
    pub fn image(&self, image: String) -> Result<Vec<u8>, DiffuseError> {
        Ok(self.client.image(&image)?)
    }

    /// `GET /runs/{run}/events`: the run as it happens.
    pub fn events(&self, run: String) -> Result<Arc<RunEvents>, DiffuseError> {
        Ok(Arc::new(RunEvents { events: Mutex::new(self.client.events(&run)?) }))
    }
}

/// A run's events, read one at a time as they arrive.
#[derive(uniffi::Object)]
pub struct RunEvents {
    events: Mutex<Events>,
}

#[uniffi::export]
impl RunEvents {
    /// The next event as JSON (`{"event": "progress", ...}`), blocking until
    /// it arrives; `None` once the run has ended.
    pub fn next(&self) -> Result<Option<String>, DiffuseError> {
        match lock(&self.events).next() {
            None => Ok(None),
            Some(Ok(event)) => Ok(Some(json(&event))),
            Some(Err(e)) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOGUE: &str = include_str!("../../proton-diffuse/tests/fixtures/catalogue-v1.json");
    const FLOW: &str = include_str!("../../proton-diffuse/tests/fixtures/lighthouse.flow.json");

    #[test]
    fn edits_undo_and_graph_cross_as_json() {
        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        let doc = FlowDocument::create("/tmp/aether-test.flow.json".into(), FLOW.into()).unwrap();
        let applied = doc
            .apply(r#"[{"op":"place","id":"5","at":[420,20]}]"#.into(), catalogue.clone())
            .unwrap();
        assert!(applied.contains("\"changed\":true"));
        assert!(doc.can_undo());
        assert!(doc.undo());
        let problems = doc.problems(catalogue.clone(), None).unwrap();
        assert_eq!(problems, "[]");
        let graph = doc.graph(catalogue.clone(), None).unwrap();
        assert!(graph.contains("\"KSampler\""));
        let refused = doc.apply(r#"[{"op":"connect","from":"7:images","to":"1:checkpoint"}]"#.into(), catalogue);
        assert!(refused.is_err());
    }

    #[test]
    fn every_template_applies_to_an_empty_flow() {
        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        for t in templates() {
            let doc = FlowDocument::create("/tmp/aether-empty.flow.json".into(), r#"{"format":1}"#.into()).unwrap();
            let ops = template_ops(t.name.clone()).unwrap();
            doc.apply(ops, catalogue.clone()).unwrap_or_else(|e| panic!("{}: {e}", t.name));
        }
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("aether-seal-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_sealed_flow_opens_with_its_key_and_stays_sealed() {
        let dir = scratch("flow");
        let path = dir.join("lighthouse.flow.json").display().to_string();
        let key = SealKey::new(vec![7; 32]).unwrap();
        let written = write_file(path.clone(), FLOW.as_bytes().to_vec(), Some(key.clone())).unwrap();
        assert_eq!(written, format!("{path}.sealed"));

        let refused = FlowDocument::open(path.clone(), None).err().unwrap().to_string();
        assert!(refused.contains("unlock Diffuse"), "{refused}");
        assert!(FlowDocument::open(path.clone(), Some(SealKey::new(vec![8; 32]).unwrap())).is_err());

        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        let doc = FlowDocument::open(path.clone(), Some(key.clone())).unwrap();
        assert!(doc.is_sealed());
        doc.apply(r#"[{"op":"note","text":"kept sealed"}]"#.into(), catalogue).unwrap();
        doc.save().unwrap();
        let on_disk = std::fs::read(&written).unwrap();
        assert!(seal::is_sealed(&on_disk));
        assert!(!on_disk.windows(11).any(|w| w == b"kept sealed"), "the note shows through");
        assert!(!Path::new(&path).exists(), "a plain copy was written");
        assert!(FlowDocument::open(path, Some(key)).unwrap().flow_json().contains("kept sealed"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_plain_flow_stays_plain_with_a_key() {
        let dir = scratch("plain");
        let path = dir.join("plain.flow.json");
        std::fs::write(&path, FLOW).unwrap();
        let doc = FlowDocument::open(path.display().to_string(), Some(SealKey::new(vec![7; 32]).unwrap())).unwrap();
        assert!(!doc.is_sealed());
        doc.save().unwrap();
        assert!(!seal::sealed_path(&path).exists());
        assert!(SealKey::new(vec![1; 31]).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A PNG of `w` × `h` pixels, every one `rgba`.
    fn flat_png(w: u32, h: u32, rgba: [u8; 4]) -> Vec<u8> {
        proton_raster::file::encode_png(w, h, &rgba.repeat((w * h) as usize)).unwrap()
    }

    #[test]
    fn a_picture_is_kept_once_renamed_apart_and_only_as_a_png() {
        let dir = scratch("keep");
        let root = dir.display().to_string();
        let red = flat_png(4, 4, [255, 0, 0, 255]);
        let blue = flat_png(4, 4, [0, 0, 255, 255]);
        assert_eq!(keep_picture(root.clone(), "My photo.jpeg".into(), red.clone(), None).unwrap(), "inputs/My-photo-jpeg.png");
        assert_eq!(keep_picture(root.clone(), "My photo.jpeg".into(), red.clone(), None).unwrap(), "inputs/My-photo-jpeg.png");
        assert_eq!(keep_picture(root.clone(), "My photo.jpeg".into(), blue, None).unwrap(), "inputs/My-photo-jpeg-2.png");
        assert_eq!(keep_picture(root.clone(), "..".into(), red.clone(), None).unwrap(), "inputs/picture.png");
        assert!(keep_picture(root.clone(), "note".into(), b"plain text".to_vec(), None).is_err());
        let key = SealKey::new(vec![5; 32]).unwrap();
        let sealed = keep_picture(root, "private".into(), red.clone(), Some(key.clone())).unwrap();
        assert!(dir.join(format!("{sealed}.sealed")).is_file() && !dir.join(&sealed).exists());
        assert_eq!(upload_bytes(dir.join(&sealed).display().to_string(), None, Some(key)).unwrap(), red);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_mask_goes_into_the_pictures_alpha() {
        let dir = scratch("mask");
        let picture = dir.join("inputs/photo.png");
        std::fs::create_dir_all(picture.parent().unwrap()).unwrap();
        std::fs::write(&picture, flat_png(2, 1, [10, 20, 30, 255])).unwrap();
        // White on the left pixel, nothing painted on the right.
        let mask = dir.join("flow.3.mask.png");
        std::fs::write(&mask, proton_raster::file::encode_png(2, 1, &[255, 255, 255, 255, 0, 0, 0, 0]).unwrap()).unwrap();
        let sent = upload_bytes(picture.display().to_string(), Some(mask.display().to_string()), None).unwrap();
        let (_, _, rgba) = proton_raster::file::decode_png(&sent).unwrap();
        assert_eq!(rgba, vec![10, 20, 30, 0, 10, 20, 30, 255]);
        std::fs::write(&mask, flat_png(3, 1, [255; 4])).unwrap();
        assert!(upload_bytes(picture.display().to_string(), Some(mask.display().to_string()), None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_mask_round_trips_and_reads_as_the_upload_does() {
        let coverage = vec![0, 64, 128, 255, 10, 200];
        let png = mask_to_png(3, 2, coverage.clone()).unwrap();
        let back = mask_from_png(png.clone()).unwrap();
        assert_eq!((back.width, back.height, back.coverage), (3, 2, coverage));
        // A browser's mask: white with its paint in the alpha.
        let browser = proton_raster::file::encode_png(2, 1, &[255, 255, 255, 128, 255, 255, 255, 0]).unwrap();
        assert_eq!(mask_from_png(browser).unwrap().coverage, vec![128, 0]);
        assert!(mask_to_png(2, 2, vec![0; 3]).is_err());
    }

    #[test]
    fn a_graphs_pictures_are_listed_and_named_by_their_uploads() {
        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        let graph = r#"{"nodes":[{"id":"1","type":"LoadImage","values":{"image":"inputs/photo.png"}},{"id":"2","type":"KSampler","values":{"cfg":1.0}}],"links":[]}"#;
        let listed = graph_pictures(graph.into(), catalogue).unwrap();
        assert_eq!(listed, r#"[{"field":"image","node":"1","value":"inputs/photo.png"}]"#);
        let named = graph_with_uploads(graph.into(), r#"[{"node":"1","field":"image","id":"up_1.png"}]"#.into()).unwrap();
        assert!(named.contains(r#""image":"up_1.png""#) && named.contains(r#""cfg":1.0"#), "{named}");
    }

    /// A run to a node's graph, read back, and what shows its picture.
    fn graph_of(answer: GraphTo) -> (Graph, String) {
        (serde_json::from_str(&answer.graph).unwrap(), answer.shows)
    }

    #[test]
    fn a_run_to_a_sampler_decodes_and_previews_only_what_it_needs() {
        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        let doc = FlowDocument::create("/tmp/aether-to-here.flow.json".into(), FLOW.into()).unwrap();
        let before = doc.flow_json();
        // Node 5 is the KSampler; 6 and 7 decode and save what it makes.
        let (graph, shows) = graph_of(doc.graph_to("5".into(), catalogue.clone(), None).unwrap());
        let kinds: Vec<&str> = graph.nodes.iter().map(|n| n.kind.as_str()).collect();
        assert!(!kinds.contains(&"SaveImage"), "{kinds:?}");
        // The flow's own decode fed only the Save Image left out, so the
        // graph has just the one added.
        assert_eq!(graph.nodes.iter().filter(|n| n.kind == "VAEDecode").map(|n| n.id.as_str()).collect::<Vec<_>>().len(), 1, "{kinds:?}");
        let decode = graph.nodes.iter().find(|n| n.kind == "VAEDecode").unwrap();
        let ids: Vec<u32> = serde_json::from_str::<serde_json::Value>(&before).unwrap()["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["id"].as_str().unwrap().parse().unwrap())
            .collect();
        let highest = *ids.iter().max().unwrap();
        assert!(decode.id.parse::<u32>().unwrap() > highest && shows.parse::<u32>().unwrap() > highest, "an added node took a flow node's id");
        assert!(graph.links.iter().any(|l| l.from.starts_with("5:") && l.to == format!("{}:latent", decode.id)));
        assert!(kinds.contains(&"PreviewImage") && kinds.contains(&"KSampler"));
        let preview = graph.nodes.iter().find(|n| n.kind == "PreviewImage").unwrap();
        assert_eq!(shows, preview.id);
        assert!(graph.links.iter().any(|l| l.from == "1:vae" && l.to == format!("{}:vae", decode.id)), "decoded with the checkpoint's VAE");
        assert_eq!(doc.flow_json(), before, "the flow itself is not changed");
    }

    #[test]
    fn a_run_to_an_image_or_an_output_adds_what_it_must() {
        let catalogue = NodeCatalogue::parse(CATALOGUE.into()).unwrap();
        let doc = FlowDocument::create("/tmp/aether-to-here.flow.json".into(), FLOW.into()).unwrap();
        let (graph, shows) = graph_of(doc.graph_to("6".into(), catalogue.clone(), None).unwrap());
        assert_eq!(graph.nodes.iter().filter(|n| n.kind == "VAEDecode").count(), 1, "an image needs no decode");
        assert!(graph.links.iter().any(|l| l.from == "6:image" && l.to == format!("{shows}:images")));
        let (graph, shows) = graph_of(doc.graph_to("7".into(), catalogue.clone(), None).unwrap());
        assert_eq!(shows, "7");
        assert!(!graph.nodes.iter().any(|n| n.kind == "PreviewImage"));
        let refused = doc.graph_to("2".into(), catalogue.clone(), None).err().unwrap().to_string();
        assert!(refused.contains("neither an image nor a latent"), "{refused}");
        assert!(doc.graph_to("99".into(), catalogue, None).is_err());
    }

    #[test]
    fn a_sealed_pictures_head_needs_its_key() {
        let dir = scratch("png");
        // A PNG's signature and IHDR are all `png::head` needs before IEND.
        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        bytes.extend_from_slice(&[0, 0, 0, 13]);
        bytes.extend_from_slice(b"IHDR");
        bytes.extend_from_slice(&[0, 0, 5, 64, 0, 0, 3, 0, 8, 2, 0, 0, 0]);
        bytes.extend_from_slice(&[0; 4]);
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        bytes.extend_from_slice(b"IEND");
        bytes.extend_from_slice(&[0; 4]);
        let key = SealKey::new(vec![9; 32]).unwrap();
        let sealed = write_file(dir.join("image_0001.png").display().to_string(), bytes.clone(), Some(key.clone())).unwrap();
        assert!(png_head(sealed.clone(), None).is_none());
        let head = png_head(sealed.clone(), Some(key.clone())).unwrap();
        assert!(head.contains("\"width\":1344") && head.contains("\"height\":768"), "{head}");
        assert_eq!(read_file(sealed.clone(), Some(key)).unwrap(), bytes);
        assert!(read_file(sealed, None).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
