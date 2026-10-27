# RESEARCH_PLAN.md — Aether: a native creative studio for macOS

Owner: Claude (Principal Investigator) · Created: 2026-10-27 · Status: **UI/UX prototype ready for review; decisions Q1–Q5 settled 27 Oct; nothing built yet**

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
| **Q1** | Rust cores or a Swift rewrite? | **Link Proton's Rust cores through UniFFI** for formats, ops, the fixed-point simulation and the raster engine. UI, rendering and media stay Swift and Metal. | M0 adds a Rust workspace and generated Swift bindings. Determinism tests carry over from Proton unchanged. Revisit after M2. |
| **Q2** | Minimum macOS? | **macOS 26 and later.** | Panels are built on Liquid Glass (`glassEffect`), with the materials in §5 as the visual spec. Metal 4 is always available. |
| **Q3** | Diffuse's default backend? | **Local Core ML by default; Nexus on forge per flow.** | Flows run offline and privately unless a flow picks forge. The Run button names the backend in use. |
| **Q4** | Plugin runtime? | **Wasmtime.** | It follows Q1: Rust is in the build anyway, and Wasmtime is the mature runtime. |
| **Q5** | Stacked traffic lights? | **Stacked, as designed.** | The M0 spike must hold through resize, full screen and appearance changes. Only if it fails do the lights go horizontal in the top-left corner. |

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

Not yet:
- The local Core ML backend (Q3's default), so runs go to Nexus only for now.
- Uploading input images (and with it the Gallery's Use as input).
- Dropping a PNG on the graph to open its graph (the Gallery takes drops).
- Opening Proton's sealed (encrypted) flows.
- Marquee selection.
- The rest of the shell's omnibar.

## 10. Status and handoff

- Done (PI): Proton survey, UX architecture, Velvet Obsidian system, app icon, a 12-board click-through prototype, this plan, and the five decisions recorded in §9.
- Built (at the user's direction, ahead of the LE): the Diffuse workspace end to end, including its Gallery (§10a). The other five workspaces are placeholders.
- Not done: no `VERDICT.md` or `SANDBOX_LOG.md` exists for Aether yet.

**Next agent: GPT-6 Astra (Lab Engineer).** Trigger: this file. Tasks for `VERDICT.md`:
1. Check the §7 frame-budget split and heap sizing for a 4096 × 2304 canvas, an 11-node flow at 1344 × 768, and 4K timeline playback, using M-series unified memory figures.
2. Specify the `Transaction` inverse rules and the all-or-nothing validation (§6.4), including how live links behave across undo.
3. Review the scaffold that now exists (`project.yml`, `Packages/AetherKit`, `cores/`) against §6, instead of creating one, and say what M0's other cores (design, scene, canvas, timeline) need from the bridge pattern `aether-diffuse` set.

Then **Gemini (AVS)** builds the scaffold, runs the M0 spikes, and logs the results to `SANDBOX_LOG.md`.

```bash
codex "Read RESEARCH_PLAN.md in this folder and write VERDICT.md per section 10."
```
