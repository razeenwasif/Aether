# Aether

A native macOS creative studio: Proton's Design, Model, Game, Canvas, Diffuse and Video modes as one app, in Swift, SwiftUI and Metal. The plan is [RESEARCH_PLAN.md](RESEARCH_PLAN.md); the design is the [canvas](https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv) and the [Status & Plan](https://claude.ai/artifact/TwC8opexFRczYqjag3V8P7) page.

**Diffuse is the first workspace built.** The other five are designed and show a placeholder until their milestones.

## Building

Needs Xcode 26 or later, Rust (stable), XcodeGen, and Proton checked out beside this folder (`../Proton`). Aether links Proton's `proton-diffuse` crate (RESEARCH_PLAN.md Q1).

```bash
./scripts/build-cores.sh   # Rust core → Packages/AetherKit/Frameworks + Swift bindings
xcodegen generate          # Aether.xcodeproj from project.yml
xcodebuild -project Aether.xcodeproj -scheme Aether -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Aether.app
```

Run `./scripts/build-cores.sh` again after any change under `cores/` or to `proton-diffuse`. Run `node scripts/render-icon.mjs` after changing `design/aether-icon.svg`.

Tests:

```bash
cargo test --manifest-path cores/Cargo.toml        # the bridge
swift test --package-path Packages/AetherKit       # flows, edits, undo, the wire format
```

## Layout

| | |
|---|---|
| `cores/aether-diffuse` | UniFFI bridge over `proton-diffuse`: flows, edits and undo, checks, the Nexus client |
| `Packages/AetherKit` | Everything Swift: `DiffuseCore` (model, backends, run queue), `DiffuseUI` (canvas, nodes, inspector, library), `AetherDesign` (Velvet Obsidian), `AetherShell` (window, rail, commands) |
| `App/` | The app's entry point and icon |
| `scripts/` | Build scripts, the icon renderer, and a stand-in image gateway |

## Diffuse

Flows are Proton's `.flow.json`, opened and saved as Proton does. Every edit goes to the Rust core as a batch of ops, applied whole or refused whole, one undo step each. New flows go to `~/Documents/Aether/Flows`.

Runs go to Nexus's image server on forge through atlas's gateway: the address comes from Aether's settings, else Proton's `~/.config/proton/settings.json`, else `http://atlas:7420/img/v1`, and the key from `NEXUS_KEY` (Aether's environment, then the login shell's). Save Image outputs land in `outputs/<flow name>/` beside the flow as `<prefix>_<nnnn>.png`, as Proton names them; Preview Image outputs go to a cache the gallery doesn't show. Away from atlas, flows still open and edit against the last catalogue the server served.

**The Gallery** (Graph | Gallery at the top left, or `⇧⌘G`) shows the outputs under the flows folder and the open flow's folder, newest first, filtered by flow. Choosing a picture shows what made it (seed, steps, CFG, sampler, model, prompts), read from the graph forge writes into each PNG as a `proton-flow` text chunk. From there: Open its graph (a new flow named after the picture; double-click or drop a PNG does the same), open the flow it came from, Show in Finder, Copy its path, Move to Trash (`⌫` or `⌘⌫`, asked first; `⌘`-click chooses more). Use as input, Send to Canvas and Send to Game are shown but off until uploads and those workspaces exist. Like Proton's, it asks for Touch ID or the Mac's password each time it's shown and shuts when left; the switch is in its inspector (`defaults write dev.razeen.aether diffuse.galleryLock -bool NO` turns it off).

To try runs without forge, start the stand-in gateway and point Aether at it. It writes the graph into each PNG it returns, as forge does, so the Gallery has something to read:

```bash
python3 scripts/fake-gateway.py --image build/fake/output.png --preview build/fake/preview.jpg
AETHER_GATEWAY=http://127.0.0.1:7421/img/v1 NEXUS_KEY=dev build/DerivedData/Build/Products/Debug/Aether.app/Contents/MacOS/Aether
```

Keys: `⌘↩` generate · `⇧⌘G` graph / gallery · `⇥` add a node · `⌫` delete · `⌘D` duplicate · `⌘B` bypass · `⌘Z` / `⇧⌘Z` undo, redo · `⌘S` save · `⇧1` fit · `⌘0` / `⌘\` panels · pinch or `⌘`-scroll to zoom, two fingers to pan.
