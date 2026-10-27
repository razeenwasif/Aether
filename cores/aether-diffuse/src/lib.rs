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
use proton_diffuse::{check, doc, layout, png, seal, templates, Catalogue, Client, FlowDoc, Graph, Key, Models, Op, Seal};

uniffi::setup_scaffolding!();

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
        match lock(&self.doc).get().graph(&catalogue.inner, models.as_ref()) {
            Ok(graph) => Ok(json(&graph)),
            Err(problems) => {
                let each: Vec<String> = problems
                    .iter()
                    .map(|p| match &p.node {
                        Some(node) => format!("node {node}: {}", p.message),
                        None => p.message.clone(),
                    })
                    .collect();
                Err(failed(each.join("; ")))
            }
        }
    }
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

    const CATALOGUE: &str = include_str!("../../../../Proton/crates/proton-diffuse/tests/fixtures/catalogue-v1.json");
    const FLOW: &str = include_str!("../../../../Proton/crates/proton-diffuse/tests/fixtures/lighthouse.flow.json");

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
