# Aether

A native macOS creative studio: Proton's Design, Model, Game, Canvas, Diffuse and Video modes as one app, in Swift, SwiftUI and Metal. The plan is [RESEARCH_PLAN.md](RESEARCH_PLAN.md); the design is the [canvas](https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv) and the [Status & Plan](https://claude.ai/artifact/TwC8opexFRczYqjag3V8P7) page.

**Diffuse is the first workspace built.** The other five are designed and show a placeholder until their milestones.

## Building

Needs Xcode 26 or later, Rust (stable) and XcodeGen. The Rust cores Aether takes from Proton, `proton-diffuse` and `proton-raster`, live in `cores/` (RESEARCH_PLAN.md Q1), so Proton isn't needed to build.

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
| `cores/aether-diffuse` | UniFFI bridge over `proton-diffuse`: flows, edits and undo, checks, sealed files, pictures, the Nexus client |
| `cores/proton-diffuse`, `cores/proton-raster` | Proton's Diffuse core and raster engine, brought from Proton at `1e1aeb7`, without their TypeScript bindings. The file formats stay Proton's |
| `docs/DIFFUSE.md` | Proton's Diffuse design and the `/img/v1` contract, which `proton-diffuse` cites and tests against |
| `Packages/AetherKit` | Everything Swift: `DiffuseCore` (model, backends, run queue), `DiffuseUI` (canvas, nodes, inspector, library), `AetherDesign` (Velvet Obsidian), `AetherShell` (window, rail, commands) |
| `App/` | The app's entry point and icon |
| `scripts/` | Build scripts, the icon renderer, and a stand-in image gateway |

## Diffuse

Flows are Proton's `.flow.json`, opened and saved as Proton does. Every edit goes to the Rust core as a batch of ops, applied whole or refused whole, one undo step each. New flows go to `~/Documents/Aether/Flows`.

Runs go to Nexus's image server on forge through atlas's gateway: the address comes from Aether's settings, else Proton's `~/.config/proton/settings.json`, else `http://atlas:7420/img/v1`, and the key from `NEXUS_KEY` (Aether's environment, then the login shell's). Save Image outputs land in `outputs/<flow name>/` beside the flow as `<prefix>_<nnnn>.png`, as Proton names them; Preview Image outputs go to a cache the gallery doesn't show. Away from atlas, flows still open and edit against the last catalogue the server served.

**The Gallery** (Graph | Gallery at the top left, or `⇧⌘G`) shows the outputs under the flows folder and the open flow's folder, newest first, filtered by flow. Choosing a picture shows what made it (seed, steps, CFG, sampler, model, prompts), read from the graph forge writes into each PNG as a `proton-flow` text chunk. From there: Open its graph (a new flow named after the picture; double-click or drop a PNG does the same), open the flow it came from, Show in Finder, Copy its path, Move to Trash (`⌫` or `⌘⌫`, asked first; `⌘`-click chooses more). Use as input, Send to Canvas and Send to Game are shown but off until uploads and those workspaces exist. Like Proton's, it asks for Touch ID or the Mac's password each time it's shown and shuts when left; the switch is in its inspector (`defaults write dev.razeen.aether diffuse.galleryLock -bool NO` turns it off).

**Sealed files.** Proton seals Diffuse's flows and pictures once you unlock it there (`testing.flow.json.sealed`, `image_0001.png.sealed`). Aether opens them with Proton's key from your keychain after Touch ID or your password. The first time, macOS asks you to let Aether read the "Proton Diffuse" keychain item, and a debug build asks again after each rebuild. Each file stays the way it was: sealed flows save sealed and their outputs are written sealed, while plain flows stay plain. A sealed last flow waits behind a locked card at launch. Flow ▸ Lock Sealed Files (or quitting) locks them again. To test without your key, debug builds read a throwaway 32-byte key from `AETHER_SEAL_KEY_FILE`, and `cargo run --example seal -- <key-file> <file>…` (in `cores/`) seals fixtures in Proton's format.

**On this Mac.** Each flow's inspector has **Runs on: Automatic / This Mac / forge**. Automatic runs on this Mac when it can, using Apple's Core ML Stable Diffusion with SDXL base at 1024 × 1024 (text to image, or image to image), and otherwise on forge, saying why: LoRAs, inpainting, upscaling, Hires fix, other sizes and other checkpoints all need forge. The model is Apple's 4.5-bit SDXL, 3.36 GB. Download it from the inspector, or run `scripts/download-sdxl.sh`, into `~/Library/Application Support/Aether/Models`. On an M2 Pro the very first run prepares the model for the GPU (about 2 minutes, once). After that, a 30-step picture takes about 3 minutes and a 10-step one about 70 s.

**Masks.** Paint the mask, under a Load Image's picture, opens Proton's mask sheet. Brush `b`, eraser `e` (`x` swaps), invert `i`, clear, undo a stroke `⌘Z`, brush size `[` `]`, soft edge, then Return to keep it or Esc to cancel. The mask is kept beside the flow as `<flow>.<node>.mask.png`, white where painted, and each run sends it in the picture's alpha.

**Pictures for Load Image.** You can choose a file, drop one on the field or the card, or take one from the Gallery (From the Gallery, or Use as input on a picture). Pictures are kept as PNGs in the flow folder's `inputs/`; a Gallery picture already in the folder is used where it is. Runs upload each picture first, with a mask Proton painted (`<flow>.<node>.mask.png`) in its alpha. Dropping a PNG with a graph in it on the graph opens that graph; any other picture adds a Load Image.

To try runs without forge, start the stand-in gateway and point Aether at it. It writes the graph into each PNG it returns, as forge does, so the Gallery has something to read:

```bash
python3 scripts/fake-gateway.py --image build/fake/output.png --preview build/fake/preview.jpg
AETHER_GATEWAY=http://127.0.0.1:7421/img/v1 NEXUS_KEY=dev build/DerivedData/Build/Products/Debug/Aether.app/Contents/MacOS/Aether
```

Keys: `⌘↩` generate · `⇧⌘↩` run to the selected node · `⇧⌘G` graph / gallery · `⌘`-drag to box-select (`⇧`-drag adds) · `⇥` add a node · `⌫` delete · `⌘D` duplicate · `⌘B` bypass · `⌘Z` / `⇧⌘Z` undo, redo · `⌘S` save · `⇧1` fit · `⌘0` / `⌘\` panels · pinch or `⌘`-scroll to zoom, two fingers to pan.
