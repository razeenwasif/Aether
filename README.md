# Aether

A native macOS creative studio: Proton's Design, Model, Game, Canvas, Diffuse and Video modes as one app, in Swift, SwiftUI and Metal. The plan is [RESEARCH_PLAN.md](RESEARCH_PLAN.md); the design is the [canvas](https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv) and the [Status & Plan](https://claude.ai/artifact/TwC8opexFRczYqjag3V8P7) page.

**Diffuse and Canvas are built.** The other four are designed and show a placeholder until their milestones.

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
| `cores/aether-diffuse` | UniFFI bridge over `proton-diffuse` and `proton-raster`: flows, edits and undo, checks, sealed files, pictures, the Nexus client, and `CanvasEditor` (a canvas painted and composited live) |
| `cores/proton-diffuse`, `cores/proton-raster` | Proton's Diffuse core and raster engine, brought from Proton at `1e1aeb7`, without their TypeScript bindings. The file formats stay Proton's |
| `docs/DIFFUSE.md` | Proton's Diffuse design and the `/img/v1` contract, which `proton-diffuse` cites and tests against |
| `Packages/AetherKit` | Everything Swift: `DiffuseCore` (model, backends, run queue), `DiffuseUI` (canvas, nodes, inspector, library), `CanvasCore` (a canvas open for editing, its tiles), `CanvasUI` (the Canvas workspace), `AetherDesign` (Velvet Obsidian), `AetherShell` (window, rail, commands) |
| `App/` | The app's entry point and icon |
| `scripts/` | Build scripts, the icon renderer, and a stand-in image gateway |

## Diffuse

Flows are Proton's `.flow.json`, opened and saved as Proton does. Every edit goes to the Rust core as a batch of ops, applied whole or refused whole, one undo step each. New flows go to `~/Documents/Aether/Flows`.

Runs go to Nexus's image server on forge through atlas's gateway: the address comes from Aether's settings, else Proton's `~/.config/proton/settings.json`, else `http://atlas:7420/img/v1`, and the key from `NEXUS_KEY` (Aether's environment, then the login shell's). Save Image outputs land in `outputs/<flow name>/` beside the flow as `<prefix>_<nnnn>.png`, as Proton names them; Preview Image outputs go to a cache the gallery doesn't show. Away from atlas, flows still open and edit against the last catalogue the server served.

**The Gallery** (Graph | Gallery at the top left, or `⇧⌘G`) shows the outputs under the flows folder and the open flow's folder, newest first, filtered by flow. Choosing a picture shows what made it (seed, steps, CFG, sampler, model, prompts), read from the graph forge writes into each PNG as a `proton-flow` text chunk. From there: Open its graph (a new flow named after the picture; double-click or drop a PNG does the same), open the flow it came from, Show in Finder, Copy its path, Move to Trash (`⌫` or `⌘⌫`, asked first; `⌘`-click chooses more). Use as input gives it to the flow's Load Image. Send to Canvas makes a new canvas of it in the Canvas workspace. Send to Game is shown but off until that workspace exists. Like Proton's, it asks for Touch ID or the Mac's password each time it's shown and shuts when left; the switch is in its inspector (`defaults write dev.razeen.aether diffuse.galleryLock -bool NO` turns it off).

**Sealed files.** Proton seals Diffuse's flows and pictures once you unlock it there (`testing.flow.json.sealed`, `image_0001.png.sealed`). Aether opens them with Proton's key from your keychain after Touch ID or your password. The first time, macOS asks you to let Aether read the "Proton Diffuse" keychain item, and a debug build asks again after each rebuild. Each file stays the way it was: sealed flows save sealed and their outputs are written sealed, while plain flows stay plain. A sealed last flow waits behind a locked card at launch. Flow ▸ Lock Sealed Files (or quitting) locks them again. To test without your key, debug builds read a throwaway 32-byte key from `AETHER_SEAL_KEY_FILE`, and `cargo run --example seal -- <key-file> <file>…` (in `cores/`) seals fixtures in Proton's format.

**On this Mac.** Each flow's inspector has **Runs on: Automatic / This Mac / forge**. Automatic runs on forge while it's serving, since it's far quicker, and checks forge every 30 seconds. When forge can't be reached, Automatic runs on this Mac if it can, saying why, using Apple's Core ML Stable Diffusion with SDXL base at 1024 × 1024 (text to image, or image to image). LoRAs, inpainting, upscaling, Hires fix, other sizes and other checkpoints always need forge. The model is Apple's 4.5-bit SDXL, 3.36 GB. Download it from the inspector, or run `scripts/download-sdxl.sh`, into `~/Library/Application Support/Aether/Models`. On an M2 Pro the very first run prepares the model for the GPU (about 2 minutes, once; the first run after a rebuild of the app can take that long again). After that, a 30-step picture takes about 2½–3 minutes and a 10-step one about 70 s. Most of that is the steps (about 3.7 s each) and memory paging on a 16 GB Mac with other apps open. A run that changes only the seed skips encoding the prompt. `swift run -c release aether-local-bench` (in `Packages/AetherKit`) times it all.

**Masks.** Paint the mask, under a Load Image's picture, opens Proton's mask sheet. Brush `b`, eraser `e` (`x` swaps), invert `i`, clear, undo a stroke `⌘Z`, brush size `[` `]`, soft edge, then Return to keep it or Esc to cancel. The mask is kept beside the flow as `<flow>.<node>.mask.png`, white where painted, and each run sends it in the picture's alpha.

**Pictures for Load Image.** You can choose a file, drop one on the field or the card, or take one from the Gallery (From the Gallery, or Use as input on a picture). Pictures are kept as PNGs in the flow folder's `inputs/`; a Gallery picture already in the folder is used where it is. Runs upload each picture first, with a mask Proton painted (`<flow>.<node>.mask.png`) in its alpha. Dropping a PNG with a graph in it on the graph opens that graph; any other picture adds a Load Image.

To try runs without forge, start the stand-in gateway and point Aether at it. It writes the graph into each PNG it returns, as forge does, so the Gallery has something to read:

```bash
python3 scripts/fake-gateway.py --image build/fake/output.png --preview build/fake/preview.jpg
AETHER_GATEWAY=http://127.0.0.1:7421/img/v1 NEXUS_KEY=dev build/DerivedData/Build/Products/Debug/Aether.app/Contents/MacOS/Aether
```

Keys: `⌘↩` generate · `⇧⌘↩` run to the selected node · `⇧⌘G` graph / gallery · `⌘`-drag to box-select (`⇧`-drag adds) · `⇥` add a node · `⌫` delete · `⌘D` duplicate · `⌘B` bypass · `⌘Z` / `⇧⌘Z` undo, redo · `⌘S` save · `⇧1` fit · `⌘0` / `⌘\` panels · pinch or `⌘`-scroll to zoom, two fingers to pan.

## Canvas

Canvases are Proton's `.canvas` folders (`canvas.json` and a PNG per layer), edited through `proton-raster`, whose maths is whole numbers only, so the same edit always makes the same pixels. They live in `~/Documents/Aether/Canvases`. With none open, the home page shows them as cards beside the new-canvas form: a name, **Pixel** (a small grid, a palette, a pencil; 16–256 px) or **Paint** (a large canvas and soft brushes; 1024–4096 px), and a size. Dropping a PNG, a Photoshop or an Aseprite file there makes a canvas of it, its layers kept. File ▸ Make a Canvas of a Picture (`⇧⌘O`) does the same.

A stroke is painted as the pen moves and kept as one undo step. Only the 64 × 64 tiles it touches are composited again. On the right are the colour (the swatch opens the colour panel; the palette and recent colours are below), the tool's settings and the layers: add, remove, reorder, show or hide, lock, lock what's clear, rename (double-click), opacity and blend. A pen's pressure sets the brush's size, and its eraser end erases.

**Selections**, as in Proton: the select tool drags out a rectangle, an ellipse or a lasso (`s` again steps through them), and the magic wand takes the pixels like the one clicked. `⇧` adds to what is selected, `⌥` takes away, and both keep only where the two overlap. A feather softens the edge. Marching ants go round it, and every edit keeps to it. The move tool (`v`) drags what is selected, or the whole layer when nothing is. `⌘T` adds handles to scale it, and dragging outside them turns it (`⇧` scales freely and snaps the turn to 15°); `↩` keeps it and `⎋` leaves it. Each move or transform is one undo step: whole pixels on a Pixel canvas, smoothed on a Paint one. The selection moves with it. `⌘C` and `⌘X` put what is selected on the clipboard as a PNG. `⌘V` pastes it back as a new layer where it was, or brings in a picture copied from another app as a new layer. Dropping a picture on an open canvas does the same. Canvas ▸ Crop to the Selection, Turn and Mirror, and Resize… change the whole canvas. Resizing a Pixel canvas uses the nearest pixel, so no new colours appear; a Paint canvas is smoothed.

**The palette**, as in Proton: a new Pixel canvas starts with Proton's sixteen colours, and a small picture imported as one gets its own colours. Click a swatch to draw with it. Add puts the colour you're drawing with into the palette, Ramp adds five shades of it (the hue shifting as a painter's shading does), and Remove takes it out. Double-click a swatch to open the colour panel. Pick a new colour, and Recolour changes the swatch and every pixel of that colour in one undo step. The colour's hex code can be typed. `⇧G` shows the pixel grid once a pixel is 6 points wide or more. `m` and `⇧M` mirror the pencil and shapes across and down the canvas's middle, with the middle line shown dashed.

**Send to Canvas** in Diffuse's Gallery (the inspector or the context menu) opens the picture as a new canvas named after it. A plain picture's canvas is written into Canvases at once. A sealed picture is unlocked first, and its canvas isn't written until you save it, since canvases are saved plain.

Keys: `b` brush (pencil on a Pixel canvas) · `n` the other · `e` eraser · `g` fill · `i` pick (or `⌥`-click) · `l` `r` `o` line, rectangle, ellipse (`⇧` squares them) · `s` select · `w` magic wand · `v` move · `⌘T` scale and turn · `⌘A` `⌘D` `⇧⌘I` select all, nothing, the rest · `⌫` clear what is selected · `⌘C` `⌘X` `⌘V` copy, cut, paste · `[` `]` size · `p` pixel-perfect · `m` `⇧M` mirror across, down · `⇧G` the pixel grid · `f` fit · `1` 100% · space-drag, or two fingers, to pan · pinch or `⌘`-scroll to zoom · Esc cancels a stroke · `⌘S` save · `⌘E` export a PNG · `⇧⌘N` add a layer · `⇧⌘W` back to all canvases.
