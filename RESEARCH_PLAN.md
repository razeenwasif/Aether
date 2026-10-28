# RESEARCH_PLAN.md — Aether: a native creative studio for macOS

Owner: Claude (Principal Investigator) · Created: 2026-10-27 · Status: **Design approved and Q1–Q5 settled 27 Oct; Diffuse and Canvas are built, and M1's project graph links them (see §10a); the other four are designed and waiting**

Design canvas (12 boards, click-through prototype): https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv
Status & Plan (run order with live statuses, renders of every board): https://claude.ai/artifact/TwC8opexFRczYqjag3V8P7

---

## 0. Summary

Aether takes Proton's six creative modes (Design, Modeling, Game, Canvas, Diffuse, Video) out of the code editor and makes them a standalone, native macOS app. It uses Swift 6, SwiftUI, AppKit where SwiftUI can't reach, and Metal, with no web view.

One sentence carries the whole design: **one project graph, six views of it.** An asset made in one workspace is a live reference in every other. It is never an export.

The UI language is **Velvet Obsidian**:

- The chrome is greyscale, so the user's work is the only colour on screen.
- The viewport is full-bleed.
- Panels float over the viewport as glass.
- Controls appear next to the selection. There is no toolbar wall.

---

## 1. Goals and non-goals

**Goals**
- Port the six Proton modes, keeping what works and fixing what Proton could not do inside a web view (Video has no programme monitor; Diffuse can run only on forge).
- Make moving an asset between workspaces free: same memory, same ID, same undo history.
- Respond at 120 Hz and cold-start fast enough that opening Aether feels instant.
- Show the least UI by default: every panel is one keystroke away and none is required.

**Non-goals (v1)**
- Codex, Chat, Data, Research, Study, LaTeX and PDF stay in Proton.
- Collaboration, cloud sync, Windows and Linux.
- A general-purpose game engine. Game stays Proton's niche: painted 2D, parallax planes, low-poly, Metroidvania first.

---

## 2. What ports from Proton, and how

| Proton mode | Keep | Change in Aether |
|---|---|---|
| **Design**: web builder, layer tree, artboard, two-way bound to component source and tokens (`proton-design`) | Two-way code binding, tokens, breakpoints, Pagepilot-style layout review | Infinite canvas with several breakpoints side by side; tokens shown before raw values in the inspector; the code drawer is collapsed to `⌘/` |
| **Modeling**: `scene.proton.json`, outliner, modifier stack, shader graph (WebGL) | Diffable scene JSON, modifier stack, Object/Edit/Sculpt modes | Metal viewport; no transform gizmo (the selection is the handle, plus a contextual action bar); the shader graph becomes a short **material layer stack** ("Simple"), with the full graph one toggle away |
| **Game**: own engine, `game.json` / `world.json` / `.room.json`, ops applied whole, fixed-point simulation (Rust → WASM), PSD → parallax planes | File formats, all-or-nothing ops, deterministic fixed-point simulation, replay checks | Native simulation; **Play in the viewport** with no separate window; ECS outliner; a behaviour graph (with a Swift view of the same logic) instead of hand-edited JSON |
| **Canvas**: integer raster engine, 64 px tiles, Pixel and Paint presets, `Name.canvas/` (`proton-raster`) | Tile model, presets, folder format, hash-checked determinism | Metal brush engine with pressure; **vector layers and booleans** (new); a layer can feed a Game parallax plane live |
| **Diffuse**: `Name.flow.json` graph, nodes from Nexus's catalogue, runs on forge's RTX 4090 (`proton-diffuse`) | Flow format, server-defined nodes, encrypted gallery | **Two backends**: local Core ML on the Neural Engine and GPU, *or* Nexus on forge, chosen per flow. Workspace-source nodes (a depth pass from Model, a painting from Canvas) |
| **Video**: CMX3600 EDL + SRT, spliced, never reprinted; no monitor without ffmpeg (`proton-video`) | EDL and SRT import/export round-trip | A real NLE: AVFoundation and VideoToolbox decode, programme monitor, magnetic trackless timeline, GPU-cached thumbnails and waveforms, effect stacks that open as nodes |

**Decided (Q1, 27 Oct): link the Rust cores.** Proton's engines are Rust: `proton-raster`, `proton-game`, `proton-diffuse` and `proton-video`. The brief said "strictly Swift", and there were two options:

- **(a) Rewrite in Swift.** One language, but the raster and simulation determinism has to be re-proven.
- **(b) Link the Rust cores through a C ABI** (UniFFI-generated Swift bindings). This is still native with no web view. It keeps the byte-identical raster engine and fixed-point simulation that Proton already tests, and the two apps keep sharing formats.

**Chosen: (b) for the document cores** (formats, ops, simulation, raster). UI, rendering and media stay Swift and Metal. Revisit after M2 if the FFI boundary costs more than it saves.

---

## 3. UX architecture

### Window anatomy (every workspace)

```
┌──┬───────────────────────────────────────────────────────────────┐
│● │ ┌Navigator ⌘0┐                                ┌Inspector ⌘\┐ │
│● │ │ layers /   │        full-bleed viewport     │ only what  │ │
│● │ │ outliner / │        (Metal / canvas)        │ applies to │ │
│L │ │ entities…  │                                │ selection  │ │
│D │ │            │     [contextual action bar]    │            │ │
│M │ │            │                                │            │ │
│G │ │            │        ┌ tool dock ┐           │            │ │
│C │ └────────────┘        └───────────┘           └────────────┘ │
│D │                                                               │
│V │                     ⌘K omnibar floats centre-top              │
│▶ │                                                               │
│⌕ │                                                               │
└──┴───────────────────────────────────────────────────────────────┘
 32 px rail: traffic lights · project · six workspaces · Run · Search · panel toggles
```

- **Rail (32 px, left).** The traffic lights are stacked vertically. Labels are text only, set vertically so they read upward like a book spine. There are no icons. The navigator toggle is named for what it holds in that workspace: Layers, Outliner, Entities, Canvases, Nodes or Media.
- **Run.** One slot, one shortcut (`⌘↩`) and one verb per workspace: Preview, Render, Play/Stop, Export, Generating (shows progress), Play. This is the only bright control in the chrome.
- **Panels float** over the viewport as glass (`.ultraThinMaterial`), so the work runs edge to edge underneath. When a panel opens or closes, the viewport content and the tool dock re-centre in the free space on the same spring.
- **Contextual action bar.** Three or four likely verbs appear next to the selection: Extrude, Inset, Bevel; Union, Subtract, Intersect. This replaces gizmos and toolbar walls.
- **Omnibar (`⌘K`).** Tools, actions, assets and Go-to in one list. The selection-aware group comes first, and `⇥` cycles the scope.

### Inspector rules
1. The header names the selection and its type ("Cap · Mesh · 1 face of 18").
2. A section appears only when it applies to that selection.
3. Tokens come before raw values.
4. Every number scrubs (⇧ coarse, ⌥ fine).
5. Anything that comes from another workspace shows its provenance and a live dot.
6. A section holds at most six rows; the omnibar holds the rest.

### Per workspace (each is a board on the canvas)
- **Design**: desktop and mobile artboards side by side. The selected component shows its auto-layout parent. The inspector covers Variant, Layout, Style tokens, synced code and Used in.
- **Model**: Edit mode, a face selected, the contextual face bar, view-cube orbit and the Simple material stack in a bottom drawer.
- **Game**: a parallax room fed live by Canvas, with collision, light and camera overlays and a behaviour graph drawer. **Play** hides the overlays and shows the HUD in the same viewport.
- **Canvas**: navigator hidden by default for focus. Two ellipses become a crescent through a non-destructive Subtract. The layers map to Game planes 1–5.
- **Diffuse**: an 11-node flow whose sources are a Model depth pass and a Canvas painting. The sampler is mid-run, and the output is the live source for Design and Video.
- **Video**: programme monitor, magnetic storyline with connected title and audio, and a clip inspector with a push-in move and an effect stack ("Open as nodes").

---

## 4. System architecture

```
                    ┌──────────────────────────────────────────────┐
  SwiftUI views ──▶ │  ProjectGraph  (@Observable, @MainActor)     │ ◀── omnibar / commands
  (6 workspaces)    │   nodes · properties · live links · undo log │
                    └───────┬───────────────────────┬──────────────┘
                 Transaction│(Sendable ops)          │ AssetID + version
                            ▼                        ▼
                ┌─────────────────────┐   ┌──────────────────────────┐
                │ Document cores      │   │ AssetPool (actor)        │
                │ raster · game sim · │   │ MTLHeap / IOSurface,     │
                │ flow · EDL (Rust via│   │ shared storage on UMA,   │
                │ UniFFI, or Swift)   │   │ version stream per asset │
                └─────────────────────┘   └────────┬─────────────────┘
                                                   │ zero-copy handles
         ┌───────────────────┬─────────────────────┼─────────────────────┐
         ▼                   ▼                     ▼                     ▼
   RenderService        InferenceService      MediaService          PersistService
   (Metal: viewports,   (Core ML / MPS on     (AVFoundation,        (Lumen.aether package:
   brush engine, node   ANE + GPU; or Nexus   VideoToolbox,         diffable JSON + blobs,
   previews)            remote backend)       CVMetalTextureCache)  autosave, crash-safe)
```

- **One graph, many views.** Every workspace reads the same `ProjectGraph` and changes it only through `Transaction`s: value-type, `Sendable` lists of ops, applied whole or not at all, as in Proton's Game. That one rule gives undo across workspaces and a log the agent can read.
- **Live links.** An asset reference is `(AssetID, version?)`. A pinned version is frozen; an unpinned one follows the newest. When Diffuse writes key-art v7, the `AssetPool` bumps the version, and subscribers (the Design image layer, the Video clip) receive it on an `AsyncStream` and redraw from the *same* GPU texture, with no copy.
- **Isolation (Swift 6 strict concurrency).**
  - The graph and the UI are `@MainActor`.
  - `AssetPool`, `InferenceService` and `MediaService` are actors.
  - Rendering runs on its own serial executor.
  - GPU objects never cross isolation boundaries; only `AssetID`s and versions do.
- **Package format.** `Lumen.aether/` is a folder: `project.json` plus a file per document, in Proton's formats wherever one exists (`*.canvas/`, `*.flow.json`, `game.json`, `*.edl`, `*.srt`), and `blobs/` holding content-addressed binaries. It stays git-friendly and diffable, as Proton's are.
- **Extensibility.** Plugins are Wasm modules run by Wasmtime (Q4), which can register tools, nodes and inspector sections. They run on a capability-scoped host API with no file system or network unless granted, the model Proton's `STACK.md` already argues for.

---

## 5. Design system (Velvet Obsidian)

The full spec is the **"Velvet Obsidian — design system"** board on the canvas. Key tokens:

| Token | Value | Use |
|---|---|---|
| `obsidian.0` | `#0B0C0E` | viewport ground |
| `obsidian.1` | `#121316` | rail and panel fill (80% on glass) |
| `raise.1` / `raise.2` | `#16171B` / `#1E1F24` | fields / active tab, segment, node |
| `line` / `line.2` | `#1F2128` / `#23252D` | hairlines / field edges |
| `ink.hi` / `ink` / `ink.2` | `#EDEEF0` / `#B9BCC4` / `#8B9099` | 15.8 : 1 / 9.6 : 1 / 5.8 : 1 on `obsidian.1` |
| `run` | `#E8EAEE` | Run button, active tool: the only bright chrome |
| `signal.select` | `#9DB4FF` (ice) | selection, focus, image wires |
| `signal.generate` | `#B9A8FF` (lavender) | generative work, conditioning wires |
| `signal.live` | `#7DD3B0` (mint) | live links, playing, synced |

- **Type:** SF Pro Text at 11, 12 and 13 pt, plus SF Mono for every number. The canvas uses Inter and JetBrains Mono as stand-ins.
- **Radii:** 4, 6, 8, 10, 12, 14.
- **Motion:** panels use `spring(response: 0.32, dampingFraction: 0.8)`. Direct manipulation is never animated.
- **App icon:** a six-faceted prism on an obsidian squircle, one facet per workspace, plus a monochrome template glyph for the menu bar. See the **"App icon"** board.

---

## 6. Scaffolding blueprints (for the Lab Engineer to build out)

### 6.1 App entry and window

```swift
import SwiftUI

@main
struct AetherApp: App {
    @State private var project = ProjectGraph.openLastOrNew()
    @State private var ui = WorkspaceUI()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(project)
                .environment(ui)
                .frame(minWidth: 1180, minHeight: 820)
                .background(WindowChromeConfigurator())   // AppKit: stack traffic lights
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AetherCommands(ui: ui) }               // ⌘1–6, ⌘K, ⌘0, ⌘\, ⌘↩
    }
}

enum Workspace: String, CaseIterable, Sendable {
    case design, model, game, canvas, diffuse, video
    var title: String { rawValue.capitalized }
    var navigatorLabel: String {
        switch self {
        case .design: "Layers"; case .model: "Outliner"; case .game: "Entities"
        case .canvas: "Canvases"; case .diffuse: "Nodes"; case .video: "Media"
        }
    }
    var runVerb: String {
        switch self {
        case .design: "Preview"; case .model: "Render"; case .game: "Play"
        case .canvas: "Export"; case .diffuse: "Generate"; case .video: "Play"
        }
    }
}

@Observable @MainActor
final class WorkspaceUI {
    var active: Workspace = .design
    var navigatorOpen: [Workspace: Bool] = [.canvas: false, .diffuse: false]
    var inspectorOpen = true
    var omnibarOpen = false
}
```

### 6.2 Root layout: rail, full-bleed viewport, floating panels

```swift
struct RootView: View {
    @Environment(WorkspaceUI.self) private var ui

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceRail()
                .frame(width: 32)
            ZStack {
                ViewportHost(workspace: ui.active)          // Metal or canvas, edge to edge
                FloatingPanels()                            // navigator, inspector, dock, drawers
                if ui.omnibarOpen { Omnibar().transition(.scale(0.98).combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: ui.inspectorOpen)
        }
        .background(Color.obsidian0)
        .ignoresSafeArea()
    }
}

/// Lays a rotated child out at its rotated size, so vertical rail labels take
/// their real height in the stack (rotationEffect alone does not change layout).
struct Rotated90: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: s.height, height: s.width)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}

struct RailLabel: View {
    let text: String
    var body: some View {
        Rotated90 {
            Text(text).font(.system(size: 11.5, weight: .medium)).fixedSize()
                .rotationEffect(.degrees(-90))              // reads upward, like a spine
        }
        .padding(.vertical, 9)
        .frame(width: 24)
    }
}
```

### 6.3 Metal viewport inside SwiftUI

```swift
import MetalKit

struct MetalViewport: NSViewRepresentable {
    let renderer: ViewportRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgr10a2Unorm                // wide colour; switch to an EDR format with HDR content
        view.preferredFramesPerSecond = 120                  // ProMotion
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1) // obsidian.0
        view.delegate = renderer
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {}
}

@MainActor
final class ViewportRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: 3)      // triple buffering

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        inFlight.wait()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { inFlight.signal(); return }
        // encode scene passes from the render graph here
        cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        cmd.present(drawable)
        cmd.commit()
    }
}
```

M0 spike: compare `MTKView` with `CAMetalLayer` + `CAMetalDisplayLink` (macOS 14+) for frame pacing, and keep whichever holds 120 Hz with SwiftUI panels animating on top.

### 6.4 Project graph, transactions and live links

```swift
struct AssetID: Hashable, Sendable, Codable { let raw: UUID }
struct NodeID: Hashable, Sendable, Codable { let raw: UUID }

enum Op: Sendable, Codable {
    case set(NodeID, property: String, value: PropertyValue)
    case insert(Node, parent: NodeID, index: Int)
    case remove(NodeID)
    case publish(AssetID)                                   // bumps the asset's version
}

struct Transaction: Sendable, Codable {
    var ops: [Op]
    var origin: Workspace
}

@Observable @MainActor
final class ProjectGraph {
    private(set) var nodes: [NodeID: Node] = [:]
    private(set) var revision: UInt64 = 0
    let assets: AssetPool
    private var undo = UndoLog()

    func apply(_ tx: Transaction) throws {                  // all or nothing
        let inverse = try validateAndInvert(tx)
        for op in tx.ops { mutate(op) }
        undo.push(inverse, origin: tx.origin)
        revision &+= 1
    }
}

actor AssetPool {
    private var versions: [AssetID: Int] = [:]
    private var subscribers: [AssetID: [AsyncStream<Int>.Continuation]] = [:]

    func updates(for id: AssetID) -> AsyncStream<Int> {
        AsyncStream { continuation in subscribers[id, default: []].append(continuation) }
    }
    func publish(_ id: AssetID) {
        let v = (versions[id] ?? 0) + 1
        versions[id] = v
        subscribers[id]?.forEach { $0.yield(v) }
    }
}
```

### 6.4a Transaction rules (settled 2026-10-28, built in `AetherGraph`)

These rules were the LE's open task; Claude wrote them with M1 and the code follows them.

1. **Only transactions change the graph.** A transaction is a value: a list of ops, the workspace it came from, a label for the Undo menu, and the document it belongs to. It is `Sendable` and `Codable`, and `ProjectGraph.log` keeps the last 200, for the agent to read.
2. **Whole or not at all.** Every op is checked against a copy of the graph before anything is kept. When one is refused, the graph is as it was, and the error names the op and the reason. The checks are:
   - a link needs an asset that exists, and can keep only a version that exists;
   - an asset can't be removed while anything links to it;
   - versions are numbered one after another;
   - only the newest version can be taken off, and only when nothing keeps it.
3. **Every op has an inverse,** worked out as it's applied: insert and remove, set and set-back, publish and retract. An undo step is that inverse, applied as a transaction.
4. **The graph holds what crosses workspaces.** That means assets, their versions, and the links that use them. A document's own edits (a stroke, a moved node) stay in its core and its core's undo, as Proton's formats and determinism need.
5. **One history, walked document by document.** Every step of every document goes on the project's history in order, and the project's own steps go among them. ⌘Z undoes the newest step of the document on screen, whichever kind it is.
   - A project change made with a document step, like the link made when a picture comes in as a layer, is attached to that step, so one ⌘Z takes both back.
   - A new step drops what could be redone in that document only. That includes a project step: once you've unlinked, the canvas's core still holds its old redo, but Redo won't reach it, so the two histories never part.
   - A closed document's steps leave the history, as its core's did.
6. **Publishing isn't an undo step,** just as saving isn't. Versions only grow. A link either follows the newest version or keeps one. Undo never takes a version away from under a link.
7. **Consumers hear on the main actor, in the same turn.** `onPublish` listeners run as the transaction lands. Bytes are read from the `AssetPool` actor, off the main actor, and each version is decoded once and shared by every view.
8. **Paths name documents:**
   - inside the project, a path relative to its folder; outside it, the whole path;
   - Save As moves a document's links, assets and steps with it.

The package is the project folder: `project.json` holds the nodes, sorted with keys in order so it diffs cleanly, and `blobs/<sha256>.png` holds each version's bytes, once. A blob is cloned on APFS when it comes from a file. The default project is `~/Documents/Aether`, which already holds `Canvases/` and `Flows/`, so nothing moved.

### 6.5 Traffic lights stacked vertically (AppKit)

`.hiddenTitleBar` keeps the system buttons, but their container is about 28 pt tall, so moving them down a 32 pt rail means either:

- enlarging and re-laying out the titlebar container on every resize, full-screen change and appearance change; or
- hiding the standard buttons and drawing our own, which call `performClose`, `miniaturize` and `zoom` (this loses the system hover glyphs and the full-screen menu unless reimplemented).

**This is an M0 spike with a fallback:** if neither option is robust, keep the lights horizontal in a 32 pt-tall top-left corner above the rail. Q5 settled on stacked; the fallback is used only if the spike fails on resize or full screen.

---

## 7. Performance strategy (Apple Silicon)

Frame budget at 120 Hz is **8.33 ms**. Working split, which the LE should validate:

- main thread: SwiftUI chrome under 2 ms;
- GPU: viewport under 5 ms;
- the remainder is headroom for compositing and panel glass.

**Cold start under 100 ms to first frame**
- Defer everything that is not the first workspace's first frame.
- Load Core ML models only when Diffuse opens.
- Ship a precompiled `.metallib` plus `MTLBinaryArchive` for pipeline states, and compile the rest asynchronously (`makeRenderPipelineState(descriptor:) async`) behind a shader-warming task.
- Restore window state from a small snapshot rather than opening the whole package.
- Measure with `os_signpost` from process start to first presented drawable, and in CI with `XCTApplicationLaunchMetric`.

**Unified memory, zero copy**
- Make GPU resources `.storageModeShared` wherever the CPU must touch them; there is no blit on UMA.
- Use one `MTLHeap` per asset class (textures, meshes, latents), with aliasing for transient render targets.
- Bridge decoded video frames from `CVPixelBuffer` to `MTLTexture` through `CVMetalTextureCache`.
- Back Core ML inputs and outputs with `IOSurface` / `MLMultiArray(pixelBuffer:)`, so Diffuse reads Canvas and Model textures and writes key art without copies.

**Rendering**
- Use argument buffers and indirect command buffers for the scene.
- Use a tile-based raster engine (Proton's 64 px tiles) with sparse textures for large canvases; only dirty tiles re-upload.
- Generate timeline thumbnails and waveforms once on the GPU and cache them by asset version.
- Node previews render at reduced resolution and update only when an upstream value changes.

**Metal 4 (macOS 26+)**
- Evaluate MTL4 command queues and residency sets for the heap strategy.
- Evaluate tensor and ML-in-shader support for fused Diffuse post-processing.
- macOS 26 is the floor (Q2), so Metal 4 is always present. Adopt it where it pays (residency sets, MTL4 queues) and keep Metal 3 APIs everywhere else.

**SwiftUI hygiene**
- Fine-grained `@Observable` models, so a scrub in the inspector invalidates one row rather than the panel.
- No `AnyView` in hot paths.
- Keep the Metal draw loop entirely outside SwiftUI's update cycle.

### 7a. The budget's rules, and what M1 measured (2026-10-28)

The LE was to validate the split above. There's no Metal viewport yet (Canvas draws with CALayers, and the Metal work is M2's), so the GPU half waits for M2. Until then these rules hold, and what M1 added was measured against them:

- **No file work on the main actor while someone draws.** Asset bytes are read and written by the `AssetPool` actor, and a linked Load Image's file is written off the main actor. A canvas's PNG is still made on the main actor when it's saved or published, as saving already did.
- **Transactions are cheap enough to apply during a frame.** In release, a 1,000-op transaction applies in about 0.9 ms. A single op on a graph of 1,000 nodes takes 0.08 to 0.21 ms, most of it the copy that makes rule 2 of §6.4a whole-or-nothing. A test fails if those pass 50 ms and 5 ms. Applying is wrapped in an `os_signpost` interval, under `dev.razeen.aether` / `graph`, for Instruments.
- **Listeners do their pixel work on the next turn.** A linked layer's update reads its bytes off the main actor, then applies one core op.
- **Nothing the chrome draws reads the disk.** The omnibar's flows list and the Load Image's canvas list are read off the main actor. Before that, an `open()` there froze the app behind a macOS privacy prompt (§10a).
- **The omnibar filters on every keystroke, from a snapshot.** It used to rebuild its list on every keystroke, reading the flows folder each time. Filtering 2,000 items took 2.7 ms in release, over the chrome's 2 ms.
  - Now it takes its items once as it opens and prepares each title's letters then. A keystroke only scores, and the last result is kept.
  - 2,000 items now take 1.3 ms in release.
  - Real lists are about 80 items: the built-in catalogue has 16 nodes, and forge's may have more.
  - A test fails past 20 ms, since test builds are slower. It hasn't been timed in the app.

---

## 8. Milestones

| | Scope | Exit criteria |
|---|---|---|
| **M0 · Shell** (2 wk) | Window, 32 pt rail, floating panels, omnibar, empty Metal viewport; spikes for traffic lights and display link | 120 Hz with panels animating; cold start under 100 ms measured; stacked traffic lights proven, or the corner fallback taken |
| **M1 · Graph** (3 wk) | `ProjectGraph`, transactions, undo, `AssetPool` with live links, package read/write | An asset published in one stub workspace updates in another with no copy (verified with Metal capture) |
| **M2 · Canvas + Model** | Brush engine, layers, vector booleans; Metal viewport, Edit mode, modifier stack, material layers | Parity with Proton's Canvas determinism tests; a Model depth pass is available as an asset |
| **M3 · Diffuse** | Flow format, Core ML backend, Nexus backend, workspace-source nodes | key-art flow runs locally and on forge; the output is live in two other workspaces |
| **M4 · Game** | Simulation core, room editor, behaviour graph, Play in the viewport | Play starts with no load step; replay check matches Proton's |
| **M5 · Video + Design** | NLE, programme monitor, EDL/SRT round-trip; Design artboards with code sync | A Lumen trailer cut built from live assets of all five other workspaces |

---

## 9. Decisions (settled 2026-10-27)

The user took the PI's recommendation on all five.

| | Question | Decision | What it changes |
|---|---|---|---|
| **Q1** | Rust cores or a Swift rewrite? | **Link Proton's Rust cores through UniFFI** for formats, ops, the fixed-point simulation and the raster engine. UI, rendering and media stay Swift and Metal. On 27 Oct, when Proton gave its creative modes away, the cores moved into Aether's `cores/` (§10a). | M0 adds a Rust workspace and generated Swift bindings. Determinism tests carry over from Proton unchanged. Revisit after M2. |
| **Q2** | Minimum macOS? | **macOS 26 and later.** | Panels are built on Liquid Glass (`glassEffect`), with the materials in §5 as the visual spec. Metal 4 is always available. |
| **Q3** | Diffuse's default backend? | **Local Core ML by default; Nexus on forge per flow.** | Flows run offline and privately unless a flow picks forge. The Run button names the backend in use. |
| **Q4** | Plugin runtime? | **Wasmtime.** | It follows Q1: Rust is in the build anyway, and Wasmtime is the mature runtime. |
| **Q5** | Stacked traffic lights? | **Stacked, as designed.** | The M0 spike must hold through resize, full screen and appearance changes. Only if it fails do the lights go horizontal in the top-left corner. |

---

## 9a. Backlog

Ideas the user has asked to keep, not yet scheduled. Each needs the user's go-ahead before it's built.

### B1 · World mode: a picture to a 3D model to an interactive world (proposed 2026-10-28)

**The idea (the user's):** a seventh mode for world simulation models, fed by a pipeline across workspaces:

```
Diffuse (a picture of a scene or character) ──▶ Model (a 3D mesh) ──▶ World (an interactive world from it)
```

**How it fits:** each step is an asset with versions, and the next step links to it, using M1's live links (§6.4a) unchanged.
- A link that follows the newest version rebuilds downstream when the picture is regenerated upstream.
- A link that keeps a version holds the world steady while the upstream step is reworked.

**The steps:**
1. **Diffuse → Model.** An image-to-3D node (Hunyuan3D or TRELLIS class) runs on forge's RTX 4090 and outputs a mesh asset. A first Model workspace only needs to show and inspect a mesh, far less than M2's editor. This step is useful on its own and gives Model its first real input.
2. **Model → World.** A world model generates an interactive scene from the mesh, the picture or both, streaming frames in reply to input. This is the risky step: the strong world models are mostly research demos or closed APIs, open ones need large GPUs, and Claude's knowledge stops in mid-2026.

**Against Game (M4):** Game is authored and deterministic (rooms, behaviour, replay checks). World is generated and not deterministic, so Game's guarantees can't cover it. Options:
- a separate seventh workspace, which needs a rail slot and changes the six-workspace layout;
- a source inside Game: a generated world to walk, then turned into authored rooms.

The PI leans to a separate mode, decided after the spike.

**Open questions:**
- Which world model can run on forge, or through an API, and at what latency per frame?
- What does it take as input: a picture, a mesh, or both? If only a picture, the Model step becomes optional.
- How does a generated world come back as an asset others can use (a recording, a scene, frames)?

**First step, a spike (no mode yet):** survey runnable world models, measure one on forge, and write the result here. Build the Diffuse image-to-3D node either way.

**Depends on:** M1 (live links), forge, and a mesh viewer in Model.

---

## 10a. Implementation log

**2026-10-27 · Diffuse first (user's call: M3 moved ahead of M0–M2).** Built the first working slice of the app around Diffuse:

- `cores/aether-diffuse`: a UniFFI bridge over Proton's `proton-diffuse`, used by path (Q1). Structured values cross as JSON in the crate's own serde shapes, so Aether decodes what Proton's window decodes. Exposes `FlowDocument` (open, create, apply op batches, undo, redo, save, problems, graph), `NodeCatalogue`, `Gateway` (health, catalogue, models, upload, run, cancel, image, events) and `RunEvents`. Two Rust tests.
- `scripts/build-cores.sh`: static library → `AetherDiffuseFFI.xcframework`, Swift bindings → `DiffuseBridge`. Learned on the way:
  - Never export `MACOSX_DEPLOYMENT_TARGET` to cargo on macOS 27: rustc's proc-macro dylibs come out with a LINKEDIT that dyld refuses. Use `CFLAGS_aarch64_apple_darwin` for C dependencies instead.
  - UniFFI's generator must run inside `cores/`.
- `Packages/AetherKit`, with five modules:
  - `DiffuseCore`: model, op encoding, `FlowEditor`, `NodeLibrary` with offline fallback, the Nexus backend, `RunQueue`, `Gallery`. Swift Testing tests on Proton's fixtures.
  - `DiffuseUI`: canvas with pan and zoom, wires, node cards, ports, the inspector's field editors, the node library, status bar, run HUD and tool dock.
  - `AetherDesign`: Velvet Obsidian tokens, glass, the rail controls.
  - `AetherShell`: window, rail, menu commands, and the Q5 spike for stacked traffic lights.
- `project.yml` (XcodeGen) builds `Aether.app` for macOS 26, with the icon rendered from `design/aether-icon.svg`.
- `scripts/fake-gateway.py`: a stand-in for the `/img/v1` contract that plays runs over the graph sent, for work away from atlas (atlas did not resolve from this Mac today).

**2026-10-27 · Diffuse Gallery (user's ask: "like in Proton").** Matches Proton's DIFFUSE.md gallery:

- Graph | Gallery switch on the stage (`⇧⌘G`).
- Outputs newest first, filtered by flow.
- The chosen picture's seed, settings and prompts, read by the core's `png_head` (new UniFFI export over `proton_diffuse::png`), which reads only the PNG's head and never the pixels.
- Actions: Open its graph (`flow_from_graph`, laid out by the core), open its flow, Show in Finder, Copy its path, Move to Trash (asked first, multi-pick with ⌘-click).
- A Touch ID / password lock (LocalAuthentication) asked each time it is shown, shut when left.
- Outputs are now named Proton's way, `<prefix>_<nnnn>.png`; Preview Image goes to a cache outside the gallery.
- The stand-in gateway stamps each PNG with a `proton-flow` chunk.
- Six more tests (17 in all).
- Found on the way: SwiftUI's `onKeyPress` never fired, because the focused view wasn't the window's first responder. That broke ⌫ on the canvas too. Stage keys (⌫ ⌦ esc ⇥) now go through one `NSEvent` key monitor, which skips text fields and sheets.
- Verified in the app against the stand-in: run → stamped PNG → gallery tile with seed → inspector values → Open its graph → ⌫ and ⌘⌫ → Trash.
- Not verified live: the lock's system prompt. Use as input, Send to Canvas and Send to Game are present but disabled.

**2026-10-27 · Proton's sealed flows and outputs.** Aether opens what Proton's Diffuse seals: AES-256-GCM files named `<name>.sealed`, keyed by 32 bytes in the login keychain (service "Proton Diffuse", account "seal key").

- The bridge exposes `SealKey`, `FlowDocument.open(path, key)`, `is_sealed` and `seal_with`, plus `read_file` / `write_file` and `png_head(path, key)`, all over `proton_diffuse::seal`. Four Rust tests cover sealed round trips, a wrong key, plain flows staying plain, and a sealed PNG's head.
- `SealVault` reads the key after LocalAuthentication, as `proton-shell/src/vault.rs` does. The keychain asks the person once per build to let Aether read Proton's item; that's theirs to allow.
- **Decision, Aether's own: keep each file as it was found.** Proton seals everything once unlocked. Aether only keeps sealed what was sealed:
  - A sealed flow saves sealed, and Save As keeps it sealed.
  - A sealed flow's outputs and previews are written sealed.
  - A flow opened from a sealed picture's graph is sealed.
  - Plain flows stay plain, even with the key in hand, and nothing plain gets sealed.
- Nothing sealed is shown or asked for until the person asks.
  - A sealed last flow waits behind a locked card at launch.
  - The Gallery lists `.png.sealed` files and shows them locked until unlocked. Decrypted thumbnails and heads stay in memory only.
  - The Gallery's own Touch ID check also unlocks sealed pictures, without asking twice.
  - Flow ▸ Lock Sealed Files lets the key go. It saves and shuts a sealed flow and locks its pictures again. Quitting does the same.
- Node cards are now 220 pt wide, Proton's `NODE_W`, so flows laid out in Proton don't overlap in Aether.
- Debug builds only: `AETHER_SEAL_KEY_FILE` points at a 32-byte test key file instead of the keychain and skips the Touch ID check. `cargo run --example seal -- <key-file> <file>…` seals fixtures in Proton's format.
- Eight more Swift tests (25 in all). One drives the run queue with a fake backend to prove a sealed flow's output lands sealed.
- Verified in the app against a throwaway key and fixtures, not the person's files:
  - The locked card at launch, then unlock and open.
  - The lock glyph in the status bar.
  - Gallery tiles decrypted, with what made them, and Open its flow.
  - A run writing `lighthouse_0002.png.sealed`.
  - Lock Sealed Files, then unlock again from the Gallery header.
- Not verified live: the real keychain prompt and Touch ID. Both need the person.

**2026-10-27 · Image inputs.** Load Image takes a picture, as Proton's D5 does:

- **Choosing a picture:** choose a file, drop one on the field, drop one on a Load Image card, or take one from the Gallery (From the Gallery waits in the Gallery, then "Use as Load Image's picture" or a double-click gives it).
- **Keeping it:** a picture is kept as a PNG under the flow folder's `inputs/`.
  - Converted by ImageIO if it isn't a PNG, and turned the way the camera says.
  - The same picture again is the same file; a different picture with the same name gets `-2`.
  - It's sealed when the flow or the source is sealed.
  - The bridge's `keep_picture` does this, mirroring Proton's `put`.
- **Use as input:** gives the waiting Load Image, the selected one or the first its picture, or adds a Load Image with it.
  - A Gallery picture inside the flow's folder is named where it is (`outputs/…/x.png`), as Proton names it.
  - One from elsewhere is kept in `inputs/` first.
- **Drops on the graph:** a PNG with a graph in it opens that graph, as Proton does. Any other picture adds a Load Image where it was dropped.
- **On a run:** each picture is sent to `POST /uploads` before the graph. A painted mask (`<flow>.<node>.mask.png`, beside the flow) goes into the picture's alpha via `proton-raster`, as Proton's `upload_bytes` does. Then `graph_with_uploads` names each upload in the graph.
- **Problems:** a picture missing from the folder is a problem on its node, and a run with one fails before anything is sent.
- **Display:** the Load Image card shows its picture.
- **Tests:** three more Rust tests and seven more Swift tests, including a run through a recording backend that checks the bytes sent and the upload named in the graph, and a mask in the alpha.
- **Verified in the app against the stand-in gateway**, which now takes uploads and fails a run whose Load Image names no upload:
  - From the Gallery, then Use as Load Image's picture.
  - A run uploading 142 KB before the graph and finishing.
  - Choose… with a JPEG, kept as a 512 × 292 PNG.
  - Use as input on a flow with no Load Image, adding one with its picture on the card.
- **Not verified live:** drag and drop (it needs Finder), and a painted mask on a real flow (Aether can't paint masks yet; Proton's masks are used as found).

**2026-10-27 · Proton's crates moved into Aether.** Proton's commits `9111812` and `1e1aeb7` took Design, Model, Game, Canvas, Diffuse and Video out of its window and shell ("they live in another app now"). At the user's call, `proton-diffuse` and `proton-raster` now live in `cores/`, so Aether builds without `../Proton`.

- Copied from Proton's commit `1e1aeb7` (both last changed there in `dca833c`), not its working tree. Proton itself is untouched: its own core still uses its copies.
- Changes on the way in:
  - Removed `ts-rs` and its attributes. They only wrote TypeScript bindings for Proton's web window, and in Aether they'd have written into the repo.
  - Package fields are written out instead of inherited from Proton's workspace.
  - Nothing else changed.
- `docs/DIFFUSE.md` came too. It's Diffuse's design and the `/img/v1` contract the crate cites, and its tests read the flows in it.
- `scripts/render-icon.mjs` now uses its own Playwright instead of Proton's `node_modules`.
- Checks:
  - `cargo metadata` resolves no package under Proton.
  - All 147 Rust tests pass in Aether's workspace (8 in the bridge, 54 in `proton-diffuse`, 85 in `proton-raster`).
  - The Swift bindings regenerate unchanged, all 32 Swift tests pass, and the app builds and reaches the gateway.
- History wasn't brought over. It's still in Proton's repo (`git log -- crates/proton-diffuse crates/proton-raster`).

**2026-10-27 · Box selection and Run to here.** Proton had neither; both follow its design, and ComfyUI's habits where the design is silent.

- **Box selection:** ⌘-drag on the ground draws a box, and ⇧-drag adds to the selection. A plain drag still pans, as in Proton, so a mouse can still pan. The keys held at the press decide, read from a mouse-down monitor beside the canvas's scroll monitor.
- **Run to here:** the inspector's Run section, a right-click on any node, or Flow ▸ Run to Selected Node (⇧⌘↩).
  - The bridge's `graph_to` sends only what the node needs.
  - Every other output is bypassed for that run, not removed, so a node added for the run never takes a flow node's id.
  - A latent gets a VAE Decode (fed by the nearest VAE upstream) and a Preview Image. An image gets a Preview Image. An output is itself. A node with neither is refused.
  - The picture shows on the node run to, and under "Latest run to here" in its inspector. It's written to the previews (sealed for a sealed flow), not the Gallery.
  - Seeds move only for nodes a run sent, for every run now.
- **Smaller fixes:**
  - The selected node draws over its neighbours, so a taller card's picture shows whole.
  - The inspector's seed control no longer pushes the panel past its edge.
  - The run queue's previews folder can be set, so tests write to a scratch folder.
- **Tests:** two more Rust tests (fresh ids, wiring, refusals) and three more Swift (35 in all).
- **Verified in the app:**
  - A real ⌘-drag, posted as Core Graphics events with ⌘ held, chose both Text Encodes. The computer-use tool can't hold a key through a drag.
  - ⇧⌘↩ on the KSampler ran only its ancestors and showed the decoded picture on it.
  - Run to Here from VAE Decode's right-click menu did the same.

**2026-10-27 · Mask painting.** Proton's mask sheet, rebuilt from `ui/diffuse-mask.js` (recovered from Proton's history).

- **Opening it:** Paint the mask, under a Load Image's picture in the inspector. The field shows how much the mask covers, or "No mask: all of it is redrawn".
- **The sheet:** the picture fitted, with the mask over it in Proton's pink at half strength, and the brush's outline under the pointer.
  - Brush and eraser (b, e, x swaps), invert (i), clear, and undo a stroke (⌘Z, 30 deep).
  - Brush size 2–400 px (`[` `]`) and soft edge 0–100%, with "N% of the picture is masked".
  - Esc cancels and Return is Done. The keys go through the same window key monitor as the stage's, ahead of the menus.
- **The pixels:** `MaskDocument` in DiffuseCore, as Proton paints:
  - Each pixel holds how painted it is, at the picture's own size.
  - Dabs are a solid core fading linearly to the brush's edge, an eighth of the brush apart. The brush paints "over" and the eraser "out".
  - Shown as a grey coverage image that SwiftUI turns into the tint on the GPU (`luminanceToAlpha`).
- **Saved:** as `<flow>.<node>.mask.png`, white where painted on black.
  - Read and written through `proton-raster` in the bridge (`mask_from_png`, `mask_to_png`) with the upload's own formula, so no colour management touches it.
  - Sealed when the flow, the picture or a mask already there is sealed.
  - A kept mask of another size is ignored, as Proton does.
- **Tests:** one more Rust test (a round trip, and a browser canvas's mask read) and six more Swift tests (dabs and their fade, eraser, undo, lines without gaps, invert, clear, share, PNG round trip, sealed and plain files). 41 Swift, 150 Rust in all.
- **Verified in the app** on the Inpaint starter:
  - A stroke painted; `]]]` grew the brush to 97 px; `i` inverted to 99% and ⌘Z undid it; `x` erased the stroke's end.
  - Return kept the mask: 1344 × 768, "1% masked".
  - The run uploaded the picture re-encoded with the mask in its alpha (793 KB against 142 KB).
  - After a relaunch, the kept mask came back in the sheet, and Esc left it unchanged.

**2026-10-27 · The local Core ML backend (Q3's default).** Flows run on this Mac with Apple's Core ML Stable Diffusion, the user having approved the downloads after seeing them.

- **This Mac is an M2 Pro with 16 GB** (the plan had assumed an M4 Max; §7's budgets need checking against this).
- **Downloaded, with the user's OK:**
  - Apple's `ml-stable-diffusion` 1.1.1 (with `swift-argument-parser` 1.8.2), as a package in a new `DiffuseLocal` target, so DiffuseCore and its tests don't depend on it.
  - The 4.5-bit palettized SDXL base from `apple/coreml-stable-diffusion-mixed-bit-palettization`, compiled files only: 3,356,763,306 bytes, each file checked against its published size. It's in `~/Library/Application Support/Aether/Models/SDXL base (4.5-bit)`, with an `aether-model.json` saying it stands in for `sd_xl_base_1.0.safetensors`.
  - `scripts/download-sdxl.sh` does the same from a shell.
- **What runs here:**
  - Text to image and image to image, with SDXL base, at 1024 × 1024, the only size Apple compiled the models for.
  - `LocalPlan` refuses LoRAs, masks, upscaling, a second sampler and other sizes, in words. It notes where this Mac differs from forge: other samplers become DPM++ 2M, seeds are 32 bits, and a starting picture is scaled to cover the square and cropped to its middle.
- **`CoreMLPipeline`:**
  - Loads once on the GPU (`.cpuAndGPU`, Apple's choice for SDXL on a Mac) and keeps the model loaded. It lets the model go only on *critical* memory pressure: on 16 GB the warnings come often, and loading again costs about 20 s.
  - Sets SDXL's VAE scale to 0.13025, as Apple's sample does. DPM++ 2M runs with Karras spacing when the flow asks for it.
  - Logs its load and stage times under `dev.razeen.aether` / `local`.
- **`LocalBackend`:**
  - The Load Checkpoint card shows the model loading, and the KSampler shows each step.
  - Runs are one at a time and stop between steps.
  - Its PNGs carry their graph, as forge's do, so the Gallery reads them.
- **Where runs go:** each flow has **Runs on: Automatic / This Mac / forge**, kept in Aether's settings by flow path. Automatic runs here when `LocalPlan` takes the graph and a model stands in for its checkpoint, and on forge otherwise, saying why. The status bar shows "This Mac" or forge's state, and each run keeps the backend it went to, for Cancel.
- **The in-app download:** with no model installed, Runs on offers "Download SDXL base (4.5-bit), 3.36 GB", with progress and Stop.
  - Each file is size-checked into a `.partial` folder and renamed when complete.
  - Started again, it keeps what came.
  - Tested against a stubbed server; the real files came through the script.
- **Measured on this Mac** (lighthouse flow, 1024 × 1024, DPM++ 2M Karras):
  - The first-ever load took about 110 s, while Core ML specialised the model for the GPU, once. Later loads take 20–22 s, on the first local run after launch.
  - Per picture: prompt encoding about 16 s, about 4.3 s a step, about 9 s to decode. 30 steps take about 2.5–3 minutes (177 s warm), and 10 steps about 70 s.
  - The same seed makes the same picture.
  - The picture is a clean SDXL lighthouse.
- **Fixed on the way:**
  - The KSampler inspector's "Seed after a run" control is on its own row, so the panel no longer runs past its edge.
  - The memory-pressure unload no longer fires on mere warnings.
- **Tests:** 15 more Swift tests (the plan, discovery, the backend against a stand-in pipeline, stopping, the queue keeping a local picture, the download, routing). 56 Swift and 150 Rust in all.
- **Follow-ups for speed, not done:**
  - ~~Prompt encoding is the largest fixed cost~~. Measured: it isn't. See "Local speed" below; the text encoders and a prompt cache are done.
  - Compare the 16-bit model's speed per step (7.04 GB, tight on 16 GB).
  - Decode a preview every few steps.

**2026-10-27 · forge is awake: Automatic prefers it.** The user asked for Automatic to "run on forge when it's serving, and on this Mac only when forge can't be reached".

- **forge from this Mac:**
  - The gateway answers at `192.168.68.61:7420` (Aether's saved home address) and at `.62` (Proton's). The two addresses are likely two interfaces on atlas.
  - The key from the login shell is accepted.
  - forge reports an RTX 4090 with 24.1 GB, and lists FLUX.2-klein-4B, ideogram-4-nf4-diffusers, Illustrious-XL-v2.0 and sd_xl_base_1.0.
  - `atlas` doesn't resolve by name, and there's no Tailscale on this Mac, so away from home forge needs Tailscale and an Away address.
- **The rule:** `RunRoute.decide` now takes forge's health.
  - Automatic runs on forge while it's serving, and while Aether is still looking. A 4090 takes seconds where this Mac takes about 3 minutes.
  - When forge is unreachable, offline, failing, or its key is missing or refused, Automatic runs on this Mac if `LocalPlan` takes the flow and a model stands in for its checkpoint. If not, it runs on forge and says why neither works.
  - This Mac and forge, set by hand, are unchanged.
  - This reverses Q3's "local by default", now that forge is reachable and much quicker.
- **Watching forge:** Aether checks it every 30 s, as Proton does. The check is quiet (`RunQueue.check()` changes the health only when the answer comes, with no "looking" in between) and takes the live catalogue when forge comes back. So Automatic falls back to this Mac when forge goes, and back to forge when it returns.
- **Tests:** the routing tests cover serving, looking, each kind of unreachable, and the reasons when neither can run.
- **Fixed: Proton's gateway address was never read.** Proton nests it as `{"diffuse": {"gateway": …}}`, and `GatewaySettings.current()` looked for a flat `"diffuse.gateway"`. The app only worked because an address had been saved in Aether's own settings. It now reads the nested form, with flat still accepted, and a test covers it.
- **The first live run on forge through Aether's own backend:** the lighthouse flow, 30 steps at 1024 × 1024, in **14.4 s** against about 177 s on this Mac. The PNG carries its graph. `LiveForgeTests` runs it again only with `AETHER_LIVE_FORGE=1`, so normal test runs never touch the network.
- **Not checked live in the app:** the screen was locked while I verified this, so the app check was a screenshot. It showed "forge · NVIDIA GeForce RTX 4090" serving with its live 16-node catalogue.

**2026-10-27 · Local speed: text encoders and a prompt cache, measured.** The user asked to "try the text encoders on the Neural Engine and caching prompt embeddings when only the seed changes, and measure".

- **How:**
  - `CoreMLPipeline` now builds Apple's SDXL pipeline from its parts (its public initialiser), as Apple's loader does. The U-Net and VAE run on the GPU; the VAE can't use the Neural Engine, which has no float32. The text encoders run where `textEncoders` says.
  - Each encoder is wrapped in `KeptTextEncoder` (Apple's public `TextEncoderXLModel` protocol), so its outputs for a prompt are kept in `PromptCache` (32 entries) while the model is loaded. A run that changes only the seed encodes nothing.
  - `lastRun` and the log give each stage: load, encode (and how many of the 4 encodings were kept), first step, the remaining steps, and decode.
  - `aether-local-bench` (a new executable target) times the encoders alone and whole runs: `swift run -c release aether-local-bench encoders|runs --on gpu|ane|cpu [--no-cache]`.
- **The encoders alone**, loaded, then prompt and negative encoded three times:

  | encoders on | load (encoder 1 + 2) | first prompt + negative | warm |
  | --- | --- | --- | --- |
  | GPU | 1.3 + 8.5 s | 1.0 + 0.8 s | 0.01 + 0.08 s |
  | Neural Engine | 2.5 + 4.8 s | 0.02 + 0.18 s | 0.01 + 0.12 s |
  | CPU | 0.3 + 1.9 s | 0.04 + 0.18 s | 0.02 + 0.11 s |

- **Whole runs**, 10 steps at 1024², through Aether's pipeline in the bench, three runs each. "Warm" means runs 2–3.

  | encoders | cache | encode, new prompt | encode, repeat | first step (warm) | 9 more steps | decode (warm) | total (warm) |
  | --- | --- | --- | --- | --- | --- | --- | --- |
  | GPU | off | 1.5–2.3 s | 1.5–1.8 s | 12.5–13.4 s | 33 s | 18–22 s | 66–70 s |
  | GPU | on | 2.1 s | 0 s | 13.5–19.9 s | 34 s | 23–35 s | 70–88 s |
  | CPU | on | 5.1 s | 0 s | 12–17 s | 34 s | 23–40 s | 69–91 s |
  | CPU, encoders released after encoding | on | 4.7 s | 0 s | 11–13 s | 35 s | 23–28 s | 69–74 s |
  | Neural Engine | on | 6.4 s | 0 s | 10–11 s | 33 s | 25–26 s | 68–69 s |

  - The cache gives pixel-identical pictures, on or off. The encoders' placement changes the picture slightly (their arithmetic differs), but each placement repeats exactly.
- **What it showed:**
  - **Encoding was never the big fixed cost.** On the GPU a new prompt takes about 2 s, and on the CPU or the Neural Engine 4.5–6.4 s. The earlier "about 16 s for the prompt" was really the first U-Net step.
  - **The real fixed cost is memory paging.** A step runs at about 3.7 s. But after the first run, each run's first step takes 10–20 s and its decode 18–40 s (6 s when nothing pages), as the U-Net and the VAE push each other out. Each set of three runs swapped in 14–18 GB, with 14–15 GB of the 16 GB swap in use (many other apps were open). No encoder placement changed that, and releasing the encoders after encoding didn't either, so that option was taken back out.
- **Kept:** encoders on the GPU (the quickest for a new prompt) with the cache on, the default `CoreMLPipeline()` the app uses.
- **Verified in the app**, 30 steps, set to This Mac: run 2 logged "encoding 0.0 s (4 of 4 kept)", against 2.9 s on run 1.
  - Run 1's first step took 206.8 s: the first U-Net prediction after a fresh build of the app, under that swap. Run 2's was 22.2 s, its 29 steps 118.6 s (4.1 s each), and its decode 37.5 s.
- **Tests:** 3 for `PromptCache` (kept prompts, cache off, the oldest let go), in a new `DiffuseLocalTests` target. 62 Swift and 150 Rust tests pass.
- **What would actually be quicker, not done:**
  - Fewer other apps open while running locally, as memory is the limit on 16 GB.
  - The U-Net on the Neural Engine: Apple's ANE-shaped SDXL builds hold palettized weights compressed. It's a different download, and the first compile is slow.
  - Apple's reduced-memory mode, unloading each part after its stage, against the cost of reloading.
  - forge, which Automatic now prefers whenever it's serving.

**2026-10-27 · The Canvas workspace, and Send to Canvas.** The user asked to "port Proton's Canvas onto the proton-raster engine already in cores/, and make Diffuse's Send to Canvas work".

- **One copy of the canvas, not two.** Proton kept the core's copy, which it saved, and the window's copy in `proton-raster` built as WebAssembly (`proton-raster-runtime`), which painted as the pen moved. The two were checked against each other by hash. Aether keeps one: `CanvasEditor` in `cores/aether-diffuse/src/canvas.rs` holds the canvas, its undo history and what was last saved, and paints and composites live as Proton's runtime did. Its runtime is ported from a C ABI over thread-local state to an object:
  - A stroke is painted on the canvas as the pen moves, each tile from what was under it when the stroke began. When it ends, those tiles are put back and the stroke is applied through the history. The engine is whole numbers only, so it makes the same pixels, and the stroke is one undo step. A cancelled stroke puts the tiles back.
  - Only what changed is composited again: whole tiles for a pencil, and for a brush only the parts its dabs fell in. While a stroke is drawn, the layers under it are composited once per tile and kept (at most 256 tiles).
  - A shape being dragged is a preview, applied and then taken back.
- **The Swift side:**
  - `CanvasCore` holds `CanvasDocument` (an observable wrapper: ops, undo, strokes, previews, save, open, import, PNG) and `CanvasPixels`, the composite kept as 64 × 64 tile images. Only the tiles that change are made again.
  - `CanvasUI` holds the workspace:
    - The stage is an `NSView` of tile layers under one layer that zooms and pans, over a checkerboard. Pixels stay square on a Pixel canvas, and on a Paint canvas from 300%.
    - Input: two fingers pan, pinch or ⌘-scroll zooms, space-drag pans. A pen's pressure and its eraser end are read. ⌥-click picks a colour.
    - Proton's tools and keys: brush and pencil (`b`/`n`, which is which depends on the preset), eraser `e`, fill `g`, pick `i`, line, rectangle and ellipse `l r o` (⇧ makes a square, a circle or a 45° line), `[ ]` size, `p` pixel-perfect, `f` fit, `1` 100%, Esc cancels a stroke.
    - The layers panel: add above, remove, move up and down, show or hide, lock, lock what's clear, rename by double-click, opacity (one undo step per drag), blend.
    - Proton's home page: canvas cards and the new-canvas form (name, Pixel or Paint, Proton's sizes). Dropping a picture there makes a canvas of it.
    - Proton's leave prompt (Stay, Leave without saving, Save and leave) before switching away from a canvas with changes.
  - Canvases are Proton's `.canvas` folders and live in `~/Documents/Aether/Canvases`. File ▸ New, Open, Make a Canvas of a Picture (PNG, PSD or Aseprite, layers kept), Save, Save As, Export a PNG (`⌘E`, and the rail's Export).
- **Send to Canvas**, in the Gallery's inspector and its context menu: Aether switches to Canvas and imports the picture as a new canvas named after it, as Proton does (Pixel up to 256 px a side, Paint above).
  - A plain picture's canvas is written into Canvases at once.
  - A sealed picture is unlocked first, and its canvas isn't written until the person saves it, with a notice that canvases are saved plain. Proton sends it plain; here nothing is written plain without the person choosing to.
  - It's a file import, as in Proton, not a live link: live links wait on M1's project graph.
- **Tests:** the bridge's canvas tests (a stroke paints live and is one undo step, a cancelled stroke leaves nothing, layers and previews, save, reopen and import). Plus 11 Swift tests: tiles across a tile edge, strokes, previews, layers, refusals, files, new-canvas naming, Send to Canvas plain and sealed, the leave prompt, keys and layers. 154 Rust and 73 Swift tests pass.
- **Checked in the app:** the home page; a new 64 × 64 Pixel canvas fitted at 1200%; a pixel-perfect pencil stroke drawn live; Send to Canvas on a 1024² output (it opened as a Paint canvas, the right way up, and was written to Canvases); a brush stroke across tile edges with no seams at 79%; Edit ▸ Undo taking the whole stroke back.
  - Fixed after looking: names kept a newline, numbers showed "1,200%", and the colour well was an empty pill (it's now a swatch that opens the colour panel).
- **Not checked:** a pen's pressure (no tablet was used), shapes and fill in the app (covered by tests), and very large Paint canvases (4096², 4096 tile layers) for speed.
- **Not ported yet:** selections (rect, ellipse, lasso, wand), move and transform, copy and paste, the palette editor, animation (frames, onion skin, tags), the pixel grid (`⇧G`), mirror (`m`), and dropping a picture on an open canvas as a layer.

**2026-10-28 · Canvas: selections, move and transform, copy and paste.** The user asked to "continue Canvas: selections, move and transform, and copy and paste". The port follows Proton's commit `102b454` (canvas P4) and its window code as it stood before `9111812` (`raster.js`, `raster-transform.js`), read from git history: the user's Proton checkout is on another branch and was left alone.

- **The engine already had it all:** `Select` (rect, ellipse, lasso, wand; replace, add, subtract, intersect; feather; soft by a pixel on a Paint canvas), `Clear`, `Copy` and `Paste`, `Transform` (an inverse in 1/65536, sampled nearest on Pixel and bilinear on Paint, the selection carried with it), `Orient`, `Crop`, and `bring_in` for pictures as layers. Every edit already keeps to the selection.
- **The bridge (`CanvasEditor`) gained:**
  - `selection_version` and `outline`, which gives the edges as segments for the marching ants.
  - `selected`, the bounds, for crop.
  - `lift`, which cuts out what is selected of a layer (all of it with nothing selected), premultiplied, for drawing while it moves.
  - `clip_png`, which gives what was copied, cut to its bounds, for the system clipboard.
  - `bring_in`, which takes a PNG, PSD or Aseprite file as layers over the current one, one undo step. A lone picture smaller than the canvas goes in its middle, as in Proton.
- **Swift:**
  - `CanvasOp` gained `select`, `copy`, `paste`, `transform`, `orient` and `crop`, and there are `CanvasArea` and `CanvasSelectMode`.
  - `CanvasTransform` is Proton's transform arithmetic, ported: drag a handle, the opposite corner stays, in proportion unless ⇧; sides scale one way; turns snap to 15° with ⇧. Each transform becomes one op, made once in the window.
  - The model gained the select tool (`s`, again for the next shape), the wand (`w`) and move (`v`), plus ⌘T, ↩ to keep and ⎋ to leave. Undo while moving leaves the move, and any other edit, tool change, save or leave keeps it first, as in Proton.
  - ⌫ clears what is selected. ⌘A, ⌘D and ⇧⌘I select all, nothing and the rest.
  - On the stage, the ants march by animating the dash phase in stage points, so they stay one point wide at any zoom. A selection being dragged shows its shape. What is being moved is drawn as one layer with the transform's affine matrix over the cleared layer (a preview), with a box and, with ⌘T, eight handles and system resize cursors.
  - The inspector gained the select and wand settings (shape, joins, feather, tolerance, contiguous, diagonal) and a Transform section (Keep it, Leave it, mirror across or down).
  - The Edit menu's Cut, Copy, Paste, Delete and Select All go to the canvas when it's on screen and no text field has the keys, and to the focused field otherwise. Select All also reaches Diffuse's graph now: `DiffuseWorkspaceModel.selectAll()` existed but had no menu.
  - The Canvas menu gained Free Transform, Crop to the Selection, and Turn and Mirror.
- **The clipboard, as Proton does it:** ⌘C or ⌘X writes a PNG of what was copied. ⌘V pastes the canvas's own copy as a layer where it was when the clipboard still holds it (by change count). Otherwise it brings in another app's picture as a new layer: a PNG, a TIFF, or an image file copied in the Finder. Dropping a picture on an open canvas does the same. JPEG, TIFF, HEIC and other formats are turned into PNG first, which also fixes Make a Canvas of a Picture for JPEGs: the engine reads only PNG, PSD and Aseprite.
- **Tests:** the bridge has 2 more: outline, lift and move with the selection carried and undone; a copy as a PNG cut to its bounds, and a picture brought in, centred, one undo step. Swift has 7 more:
  - 4 for the transform arithmetic: a whole move's inverse, a corner scale in proportion and free, a snapped quarter turn swapping the sides, finding handles.
  - 3 for the model, on a private pasteboard: select, move, leave and ⌘T as one step each; copy, paste where it was, another app's picture brought in, and cut; crop, turn and the keys.
  - 156 Rust and 80 Swift tests pass.
- **Checked in the app,** on `image_0007` (Paint, 1024²), closed without saving:
  - A rectangle dragged with the select tool, with its ants; Select All's ants round the canvas.
  - The move tool dragging the lighthouse, leaving its place clear, the selection with it.
  - ⌘T's handles, a corner dragged to scale it up and a drag outside to turn it, then Keep it. What was kept matched what was shown, and the selection turned with it.
  - The automation's drag sent an extra click at its end, which selected nothing (a click selects nothing, as in Proton). Undo showed the rectangle had been made.
- **Not checked in the app:** copy and paste, so as not to overwrite the user's clipboard (the tests use a private one). Also not checked: the lasso, the wand, dropping a picture on an open canvas, crop and turn (all covered by tests), and moving on a 4096² canvas.
- **Not ported yet:** the palette editor, animation (frames, onion skin, tags), the pixel grid (`⇧G`), mirror drawing (`m`), resizing the canvas, and Proton's Make panel (generators and filters).

**2026-10-28 · Canvas: the palette, the pixel grid, mirror drawing, and resize.** The user asked to "continue Canvas: the palette editor, the pixel grid and mirror drawing, and resize". Ported from Proton's window as it stood before `9111812` (`raster.js`'s palette panel, `toggleGrid`, the tip's mirror and the Canvas panel's resize), with the engine's ops as they are.

- **Fixed on the way:** Proton's core gave a new Pixel canvas its sixteen colours (`PALETTE16`), and a small picture imported as a Pixel canvas a palette of its own colours (32 at most). Aether's bridge did neither, so new pixel canvases had no palette (missed in the first Canvas port). Both are done now.
- **The bridge** gained `canvas_ramp`, the engine's OKLab ramp. Everything else was already an op: `SetPalette`, `ReplaceColor` (a swatch and every pixel of its colour on layers not locked, one undo step, regardless of the selection), `Resize` (nearest on Pixel, weighed on Paint), and the tip's `mirror`, given as twice the line's place.
- **The palette section** sits under Colour on both presets.
  - A click on a swatch draws with it and chooses it. Add puts in the colour drawn with. Ramp adds five steps of it that aren't there already (steps 5, shift 25°, spread 24000, as Proton's). Remove takes it out.
  - A double-click opens the colour panel on the swatch's colour. Once the colour drawn with differs from the chosen swatch, a Recolour button changes the swatch and its pixels.
  - Proton opened a colour input on double-click and recoloured on its change. A button keeps it to one edit however long the colour panel is dragged.
- **The colour's hex** can be typed (`#rgb`, `#rrggbb`, `#rrggbbaa`). A bad code puts the old one back.
- **The pixel grid** (`⇧G`, the dock's grid button, Canvas ▸ Show the Pixel Grid) is Proton's: a mid-grey hairline at 35% on every pixel edge, one device pixel wide, once a pixel is 6 points or more. It's drawn only over the part of the canvas on screen.
- **Mirror drawing** (`m` across, `⇧M` down, the pencil's settings, the Canvas menu): the pencil, the eraser on a Pixel canvas, and shapes are mirrored through the tip, as Proton's. The middle lines are dashed white at 35%. The brush doesn't mirror, in Proton or here: the engine mirrors tips, not dabs.
- **Resize…** (the Canvas menu) opens a sheet: width, height, Keep its shape, and the preset's limit (1024 on Pixel, 4096 on Paint). One undo step, then the canvas is fitted again. The fields update as typed, so a click on Resize uses what's in them.
- **Tests:** the bridge has 1 more (a ramp darkest first; a swatch recoloured with its pixels in one step; resize by the nearest pixel), and the import test now checks the palettes. Swift has 5 more: recolour and its undo; add, ramp and remove; hex codes; mirrored strokes and shapes and the `m`, `⇧M`, `⇧G` and `g` keys; resize and its limit. 157 Rust and 85 Swift tests pass.
- **Checked in the app,** on a 64 × 64 Pixel canvas made for the check and deleted after:
  - The palette's sixteen swatches; the mirror line; a pencil stroke on the left drawn on the right too.
  - The grid at 1200%, too fine to see in a downscaled capture. Reading pixels showed a lighter line every 24 device pixels.
  - Choose swatch 0, take red from Lately, Recolour: the swatch and every pixel of the old stroke turned red.
  - Resize to 32 × 32 with the shape kept (Height followed Width), refitted at 2500%.
  - On `image_0007`, the Paint inspector (an empty palette, the brush's rows) fits without clipping, after raising the top part's height.
  - Typing into the hex field couldn't be driven in the background (the automation's keys went to the canvas), so the hex field is checked by tests only.
- **Not ported yet:** animation (frames, onion skin, tags), Proton's Make panel (generators and filters), Scale2x and Scale3x upscaling, exporting at ×2 to ×8 and as a sheet, PSD export, and vector booleans.

**2026-10-28 · Canvas: animation — frames, onion skin and tags.** The user asked to "continue Canvas: animation — frames, onion skin and tags, as in Proton". Ported from Proton's window before `9111812` (`raster-frames.js`, and `raster.js`'s timeline, playing, onion skin and animation fields) and from `proton-raster-runtime`'s shown frame, onion skin and thumbnails.

- **The engine already had** cels (a layer in a frame, id = layer + frame × 65536), `AddFrame` (clear or a copy, which joins a tag ending on the copied frame), `RemoveFrame`, `MoveFrame`, `SetDuration`, `SetTags`, and `blend::fold` laying a frame with onion skin under each layer.
- **The bridge (`CanvasEditor`)** now holds a shown frame and onion skin, as the runtime did.
  - `show_frame` cancels a stroke or a preview, then lays the frame again.
  - `onion` sets the reach (up to 5 each way), the nearest frame's strength and the tint (red before, blue after). The furthest frame is faintest.
  - `thumb` samples each pixel at its middle and returns it premultiplied.
  - Only cels in the shown frame or its onion skin are laid again when they change. The per-tile cost counts each onion frame.
  - Strokes, pick, pasting a picture in, and the PNG export use the shown frame. `view` gives `tags` and `shown`.
- **Swift:**
  - `CanvasTag`, `CanvasDirection` and `CanvasCel`, the frame ops, and `paste` into a frame.
  - `CanvasRun` is Proton's play order: on and round, back, or to the end and back with each end once, over every frame or a tag.
  - Every drawing op names the layer's cel in the shown frame. Layer ops still name the layer.
  - `CanvasDocument` tracks which frames' pictures each change touched, for the thumbnails.
- **The model:**
  - Frame actions: show, step round from the ends, add, copy (`⇧N`), remove, move, and this frame's time or every frame's.
  - Tags: add over the shown frame, edit them (kept in order and within the frame count), remove them.
  - Playing: each frame waits its own time against a clock, starting over from now if it falls more than 250 ms behind (Proton's rule). Onion skin is off while playing. An edit, drawing, or showing a frame stops it, as do ↩ and ⎋.
  - Onion settings (on, 0–3 before and after, tint) are kept between launches. Proton kept them in `localStorage`; here it's `UserDefaults`, which tests swap for their own.
- **The timeline** sits above the dock:
  - A bar with step back, play or stop, step forward, "3 / 8", this frame's milliseconds, a "what plays" picker once there are tags, onion skin, and add, copy and remove.
  - A strip of thumbnails with the tags as coloured bars above them. Click a bar to play its tag, drag a frame to move it, click one to show it.
  - Thumbnails are redrawn 120 ms after frames change, only for the frames that changed. They're drawn at 80 device pixels, so a 40-point cell on Retina shows every pixel of a sprite up to 80 wide. At Proton's 40, a one-pixel line in a 64-pixel frame was missed (seen in the app).
  - Fitting the canvas leaves room for the timeline.
- **The inspector's Animation section:** "Frame 3 of 8, shown 100 ms", Every frame N ms, onion skin with its reach and tint, and the tags (name, first and last frame, how they play, remove, ＋ A tag here). The Canvas menu has a Frames submenu.
- **Tests:** the bridge has 1 more (one frame shown at a time; onion skin faint and red under the frame shown and not picked; thumbnails; held to the frame count; removing the shown frame shows the one before). Swift has 7 more:
  - the play order
  - drawing in each frame alone, copy, move, durations, remove and undo
  - onion skin in the composite and not in pick
  - tags
  - the keys, and real playback (waited for, not timed, since other suites share the main actor) stopped by ⎋ and by an edit
  - thumbnails only for the frames changed
  - a paste into the shown frame only
  - 158 Rust and 92 Swift tests pass, and the full Swift suite passed three runs in a row.
- **Checked in the app,** on a 64 × 64 canvas made for the check and deleted after:
  - the timeline bar and the Animation section
  - three frames of a line moving right, drawn with New Frame from the menu
  - onion skin showing frame 2 faintly in red under frame 3
  - the strip's thumbnails
  - This first look found the strip covering the canvas once it appeared, and the missed one-pixel line; both are fixed.
  - The screen then locked, so the rebuilt timeline (the strip always shown, the canvas fitted above it), the tag bars, playback and dragging frames are covered by tests but not seen in the app.
- **Not ported yet:** Proton's Make panel (generators and filters), Scale2x and Scale3x upscaling, exporting at ×2 to ×8, as a sprite sheet with its JSON and as PSD, and vector booleans.

Not yet:
- ~~Dropping a PNG on the graph to open its graph (the Gallery takes drops).~~ Done.
- ~~Marquee selection.~~ Done.
- ~~The rest of the shell's omnibar.~~ Done with M1, below.

**2026-10-28 · M1: the project graph, live links and the omnibar.** The user asked to "start M1: the transaction rules, the project graph with live links, and the omnibar".

- **The rules** are §6.4a, written first and followed by the code: transactions only, whole or not at all, an inverse for every op, one history walked document by document, publishing not an undo step, consumers told on the main actor. The frame budget's rules and what M1 measured are §7a.
- **`AetherGraph`,** a new module with no dependencies:
  - `ProjectGraph` holds nodes (assets and links), applies transactions against a copy, keeps the last 200 in `log`, and writes `project.json` 300 ms after the last change (and on quit).
  - `History` keeps every document's steps and the project's in one order. A project change made with a document step is attached to it.
  - `AssetPool`, an actor, keeps each version's bytes once in `blobs/<sha256>.png` (cloned on APFS when they come from a file) and decodes each picture once for every view.
  - `Workspace` moved here from the shell. `Link` became `AssetLink`, and SwiftUI files say `AetherGraph.Transaction`, since SwiftUI has both names.
- **The project** is `~/Documents/Aether`, which already held `Canvases/` and `Flows/`, so nothing moved. A `project.json` that can't be read is never written over: the session keeps links in memory and says so.
- **Every step goes on the project's history.** `CanvasDocument` and `FlowEditor` tell the project of each new step (`onStep`), and their `undo`/`redo` now answer whether there was a step. ⌘Z in Canvas or Diffuse goes through the project, and the Edit menu names the step ("Undo Update Key art to v2"). Closing or switching a document drops its steps; Save As moves them.
- **Diffuse → Canvas, live.**
  - Send to Canvas makes the flow an asset, publishes the picture as its newest version, and the new canvas's layer follows it. Linking is part of making the canvas, so it isn't an undo step.
  - From then on each finished run publishes its first picture kept for the Gallery, and the layer takes it as one canvas step ("Update Key art to v3").
  - A layer can keep a version instead: the picture and the pin are one step. Unlink is a step of its own. A canvas that was shut catches up when it opens.
  - Sealed pictures and sealed flows are sent as copies, as before, since versions are kept plain.
  - A layer that follows an asset can't be painted on, cleared, cut or moved; the notice says to unlink it.
  - The core gained `put_picture`: one undo step that makes a cel a picture's, centred when smaller and cut when bigger. Locked or not, since the link owns the layer.
- **Canvas → Diffuse, live.**
  - A Load Image's inspector has From a Canvas, listing the project's canvases. The canvas is published as it is now, its picture written to the flow's `inputs/`, and the node takes it with its link as one step.
  - Each save of that canvas publishes again. Every following Load Image has its file written again, whether its flow is open or not, and its card and thumbnail redraw.
  - Keep a version, Follow the newest, Unlink and Show sit in the Load Image's inspector, with a live dot. Undo puts a kept version back, and its file follows.
  - A sealed flow can't take a live picture, since its inputs would be written plain.
- **Canvas → Canvas.** Publish as an Asset (from the omnibar) makes the canvas open an asset. Another canvas can place it as a layer that follows it. A canvas can't follow itself.
- **The inspectors** show where a linked layer or picture comes from, with a mint live dot or a grey kept one (inspector rule 5). They also show the version, the version picker, Unlink and Show the Source, and, for a canvas others use, Used elsewhere. The Layers list has the dot as well.
- **The omnibar (⌘K, or the rail's Search):**
  - One list in four groups: Here (Canvas's tools, frames, grid, transform and export; Diffuse's Generate, Gallery and Fit), Actions, Assets and Go to (workspaces, every canvas and flow, the Gallery).
  - Every node in the catalogue is there to add once something is typed.
  - An asset does what fits the workspace on screen: Place as a layer in a canvas, Use in a Load Image in a flow, otherwise Open.
  - Letters in order match, scored up at the start and at word starts. ↑↓ choose, ↩ runs, ⇥ narrows to one group and on, esc or a click outside closes.
  - It takes its items once as it opens, so typing never reads a folder. The flows folder (for Go to) and the project's canvases (for From a Canvas) are read in the background, so opening never waits on the disk either (§7a).
- **Tests:**
  - The bridge has 1 more: a linked layer takes a picture as one step, centred and undone whole.
  - Swift has 15 more:
    - The graph (6): whole or nothing, versions and listeners, undo walking one document's steps, the package and its blobs, Save As, and a 1,000-op transaction inside a frame.
    - The canvas's links (4): placing, following, keeping, undoing (which takes back the version shown), taking the newest again, unlinking, redo not reaching past a project step; Send to Canvas and catching up after reopening; a canvas published on save; every step in the project's history.
    - The flow editor (2): its steps, and the picture target.
    - The omnibar (3): groups and scopes, matching, and a keystroke over 2,000 items.
  - 159 Rust and 107 Swift tests pass.
- **The first look in the app,** once the screen was unlocked:
  - ⌘K opened the omnibar over Diffuse, its groups and shortcuts as designed.
  - Two faults were found and fixed:
    - Typing redrew the list's first row stale, showing Generate for "load im". Each row carried an extra `.id(index)` for scrolling, which fought the list's own identity; scrolling now goes by the item's id.
    - Opening the omnibar listed the flows folder on the main thread. With this rebuild's new ad-hoc signature, macOS asked again whether Aether may read Documents, and the app froze behind the dialog. That list, and the Load Image's canvas list, are now read in the background.
- **Checked in the app** once the user had answered the dialog. Two canvases were made for the check and moved to the Trash after, with the `project.json` and `blobs/` they made, so `~/Documents/Aether` is as it was.
  - **The omnibar:**
    - "load im" finds Add Load Image, and "canvas" lists Canvas (Go to) above New Canvas….
    - ↓ moves the choice, and running New Canvas… switches to Canvas with the form open.
    - "publish" finds Publish as an Asset. "link check a" finds the asset ("Place as a layer · Canvas v1", with its live dot) and the canvas under Go to.
  - **Canvas → canvas, live:**
    - A (red) published as an asset wrote `project.json` (one asset, version 1) and one blob.
    - Placed in B, it became a layer named after A, with a live dot in Layers. The Linked section read "Live: shows v1 of 1" with the version picker, Unlink and Show the Source.
    - A showed Used elsewhere: Link check B.
    - Painting on the linked layer was refused with the notice to unlink it.
  - **Undo:**
    - The Edit menu read "Undo Bring in Link check A". Undo took away the layer and its link together (`project.json` had no link left), and Redo brought both back.
  - **Following:**
    - A turned blue and saved published v2 (two blobs).
    - B, shut meanwhile, caught up when it opened: blue, "v2 of 2", "Undo Update Link check A to v2".
    - The same again with green made v3.
    - Unlink took the link away, and "Undo Unlink" was offered.
  - **Three more faults found, all fixed and seen fixed:**
    - Omnibar rows answered only a mouse tap, so accessibility's Press, and VoiceOver, couldn't run them. They're buttons now.
    - After undoing an update, the Linked section still said "shows v2" while the layer showed v1. Which version a layer shows is now part of the update step. The section reads "Live, but shows v2 of 3: undo put it back" with a Take v3 button, which put v3 back.
    - After Unlink, the Edit menu still offered the canvas core's stale redo. Redo now reaches only what the project's history undid.
  - **Not checked in the app:**
    - Send to Canvas and From a Canvas: the Gallery asks for Touch ID, and the check didn't touch the user's flows.
    - Keeping a version from the picker, which the automation can't open; tests cover it.
- **Not done:** opening another project (New Project/Open Project), and a Metal capture for the "no copy" exit criterion. Today each version is decoded once and shared, but the raster core holds its own tiles, as Proton's determinism needs, and there's no Metal viewport until M2. Diffuse's link code is covered only by the canvas side's tests and the flow editor's, because `DiffuseWorkspaceModel` reaches the gateway when made.

## 10. Status and handoff

- Done (PI): Proton survey, UX architecture, Velvet Obsidian system, app icon, a 12-board click-through prototype, this plan, and the five decisions recorded in §9.
- Built (at the user's direction, ahead of the LE): the Diffuse workspace end to end, including its Gallery (§10a), and the Canvas workspace on `proton-raster` with selections, move and transform, copy and paste, the palette, the pixel grid, mirror drawing, resize, animation, and Send to Canvas (§10a). M1's project graph is built too: transactions, one history, live links between Diffuse and Canvas, and the omnibar (§6.4a, §10a). The other four workspaces are placeholders.
- Not done: no `VERDICT.md` or `SANDBOX_LOG.md` exists for Aether yet.

**Roles from 2026-10-27:** the user has no Codex subscription for now, so Claude does the Lab Engineer's implementation as well as the PI's work. The LE's open tasks, the §7 frame budget and the §6.4 transaction rules, moved to Claude, and were done with M1 (§7a, §6.4a).

**Next: Claude.** Diffuse parity, in this order (proposed 2026-10-27):
1. ~~Sealed flows and outputs~~: done, see §10a.
2. ~~**Inputs.**~~ Done, see §10a. Load Image's picture: choose one, drop one, or take one from the Gallery, then upload it through `Client::upload`. This turns on the Gallery's Use as input, and img2img and inpaint flows.
3. ~~**Smaller pieces:** marquee selection, dropping a PNG on the graph, and Run to here~~: done, see §10a.
4. ~~**Mask painting**~~: done, see §10a. With it, Diffuse matches Proton's window, apart from Send to Canvas and Send to Game, which wait on those workspaces.

Then ~~the local Core ML backend (Q3's default)~~: done, see §10a. ~~The Canvas workspace and Send to Canvas~~: done, see §10a, as a file import. ~~Canvas selections, move and transform, copy and paste~~: done, see §10a. ~~The palette, the pixel grid, mirror drawing and resize~~: done, see §10a. ~~Animation: frames, onion skin and tags~~: done, see §10a.

~~M1: the transaction rules, the project graph with live links, and the omnibar~~: done, see §10a. Checked in the app with two canvases. Send to Canvas and From a Canvas are covered by tests only.

**Next, proposed:** finish M1: New Project and Open Project (other `.aether` folders), and the Metal capture for the exit criterion once M2's viewport exists. After that, the rest of Canvas (the Make panel's generators and filters, and export: ×2 to ×8, the sprite sheet and PSD).
