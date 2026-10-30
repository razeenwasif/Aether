# Aether

A native macOS creative studio: Proton's Design, Model, Game, Canvas, Diffuse and Video modes as one app, in Swift, SwiftUI and Metal. The plan is [RESEARCH_PLAN.md](RESEARCH_PLAN.md); the design is the [canvas](https://claude.ai/artifact/Ho2LB6Q7GrnBXMc8jwfaEv) and the [Status & Plan](https://claude.ai/artifact/TwC8opexFRczYqjag3V8P7) page.

**Diffuse and Canvas are built, and the project graph links them (M1). Model is built in part: Proton's scenes, the outliner and the modifier stack on a Metal viewport, and an Edit mode Proton never had.** The other three are designed and show a placeholder until their milestones.

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
swift test --package-path Packages/AetherKit       # the graph, flows, canvases, links, undo, the omnibar
```

## Layout

| | |
|---|---|
| `cores/aether-diffuse` | UniFFI bridge over `proton-diffuse` and `proton-raster`: flows, edits and undo, checks, sealed files, pictures, the Nexus client, `CanvasEditor` (a canvas painted and composited live), `SceneEditor` (a scene edited, and each object's triangles with its modifiers applied), and `MeshEditor` (a mesh in Edit mode) |
| `cores/aether-poly` | Aether's own: a mesh kept as polygons, read from and written to `.obj`, and Edit mode's extrude, inset, loop cut, bevel and delete |
| `cores/aether-layers` | Aether's own: material layers, a base surface and a short stack over it, written as an ordinary Proton material graph and read back from one |
| `cores/proton-diffuse`, `cores/proton-raster`, `cores/proton-scene`, `cores/proton-mesh` | Proton's Diffuse core, raster engine, scene format and mesh maths (`.obj`, mirror, array, subdivide), brought from Proton at `1e1aeb7`, without their TypeScript bindings. The file formats stay Proton's |
| `docs/DIFFUSE.md` | Proton's Diffuse design and the `/img/v1` contract, which `proton-diffuse` cites and tests against |
| `Packages/AetherKit` | Everything Swift: `AetherGraph` (the project: assets, links, transactions, one history, the package), `DiffuseCore` (model, backends, run queue), `DiffuseUI` (canvas, nodes, inspector, library), `CanvasCore` (a canvas open for editing, its tiles), `CanvasUI` (the Canvas workspace), `ModelCore` (a scene open for editing, a mesh in Edit mode, the camera and picking maths, the Metal shader source), `ModelUI` (the Model workspace and its Metal viewport), `AetherDesign` (Velvet Obsidian), `AetherShell` (window, rail, commands, the omnibar) |
| `App/` | The app's entry point and icon |
| `scripts/` | Build scripts, the icon renderer, and a stand-in image gateway |

## The project

Every workspace views one project. The default is `~/Documents/Aether`, which holds `Canvases/`, `Flows/` and `Models/`; any other is a `Name.aether` package, which the Finder shows as one document.
- **Making and opening:** File ▸ New Project… makes one, Open Project… (`⌥⌘O`) opens one, and so does double-clicking a `.aether`. The rail's top slot names the project open, and clicking it opens a menu of the same with the recent projects.
- **Switching** asks about unsaved changes first, and each project keeps its own last flow. The last project opens at the next launch.

A project's `project.json` keeps what crosses workspaces, and is written once something is linked:
- assets: something one workspace makes for others to use
- their versions, whose bytes are kept once each in `blobs/`
- links: the places that use an asset

The rules are RESEARCH_PLAN.md §6.4a.

**Live links.** A link follows its asset's newest version, or keeps one. Either way it shows a mint dot (live) or a grey one (kept), with a version picker, Unlink, and Show the Source. After undo puts an older version back, it says so and offers Take vN.
- Send to Canvas in Diffuse's Gallery makes a canvas whose layer follows the flow's newest picture. Each run of that flow replaces the layer, as one undo step. A layer that follows can't be painted on until it's unlinked.
- In Diffuse, a Load Image's From a Canvas takes a canvas live: each time that canvas is saved, the picture follows, even when the flow isn't open.
- In Canvas, Publish as an Asset (from the omnibar) lets another canvas place this one as a layer that follows it.
- Sealed pictures and flows are never linked, since versions are kept plain. They're copied, as before.

**One history.** `⌘Z` undoes the newest step of the document on screen, whether it's the document's own or a project step made in it (keeping a version, unlinking). A step and the link made with it, like a layer placed from an asset, undo together. A new step, of either kind, drops what could be redone. The Edit menu names the step. A link belongs to its document as saved: closing without saving takes back the links made since.

**The window** moves by the rail's empty space; a double-click there zooms it, or does what the Mac's title-bar double-click setting says.

**The omnibar** (`⌘K`, or Search in the rail) lists tools, actions, assets and places to go, the workspace's own first. Type a few letters in order ("cf" finds Copy the Frame). `↑` `↓` choose, `↩` runs (only once something is typed or chosen), `⇥` narrows to one group, and esc closes. In a flow it can add any node. An asset is placed as a layer in a canvas, or taken by a Load Image in a flow.

## Diffuse

Flows are Proton's `.flow.json`, opened and saved as Proton does. Every edit goes to the Rust core as a batch of ops, applied whole or refused whole, one undo step each. New flows go to `~/Documents/Aether/Flows`.

Runs go to Nexus's image server on forge through atlas's gateway: the address comes from Aether's settings, else Proton's `~/.config/proton/settings.json`, else `http://atlas:7420/img/v1`, and the key from `NEXUS_KEY` (Aether's environment, then the login shell's). Save Image outputs land in `outputs/<flow name>/` beside the flow as `<prefix>_<nnnn>.png`, as Proton names them; Preview Image outputs go to a cache the gallery doesn't show. Away from atlas, flows still open and edit against the last catalogue the server served.

**The Gallery** (Graph | Gallery at the top left, or `⇧⌘G`) shows the outputs under the flows folder and the open flow's folder, newest first, filtered by flow. Choosing a picture shows what made it (seed, steps, CFG, sampler, model, prompts), read from the graph forge writes into each PNG as a `proton-flow` text chunk. From there: Open its graph (a new flow named after the picture; double-click or drop a PNG does the same), open the flow it came from, Show in Finder, Copy its path, Move to Trash (`⌫` or `⌘⌫`, asked first; `⌘`-click chooses more). Use as input gives it to the flow's Load Image. Send to Canvas makes a new canvas of it in the Canvas workspace. Send to Game brings it into the game open in Game as a plane of the room on screen. Like Proton's, it asks for Touch ID or the Mac's password each time it's shown and shuts when left; the switch is in its inspector (`defaults write dev.razeen.aether diffuse.galleryLock -bool NO` turns it off).

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

## Model

Scenes are Proton's `scene.proton.json` format, edited through `proton-scene`, one edit an undo step in the project's one history. They live in `~/Documents/Aether/Models` as `Name.scene.json`, with their meshes beside them as `.obj` files. As in Proton, a scene is saved 300 ms after each edit, so there is no Save to forget. With none open, the home page shows them as cards beside the new-scene form; a new scene starts with a cube.

**The viewport** is Metal, drawn only when something changes: the grid, each mesh lit by one key light with Proton's metal and rough shading, and lines for what has no surface (a burst for a light, a frustum for a camera, a cross for an empty, a box for a mesh that can't be read). A material's graph is compiled by the core and drawn as a Metal shader, its constants in a buffer. Drag, or two fingers, to turn round; `⇧`-drag, a right or middle drag, or `⇧` with two fingers, to slide; pinch or the wheel to zoom. A click chooses what's under it, tinted and lit round its edge in ice. The status bar shows the objects, the triangles and what the GPU took for the last frame.

**The outliner** (`⌘0`) lists every object, parents above children. A click chooses one, a double-click renames it, and ＋ adds a cube, sphere, cylinder, cone, torus or plane (written into `meshes/`), a light, a camera or an empty. Something added while an empty is chosen goes under it. − removes the object and what's under it.

**The inspector** (`⌘\`) shows the chosen object's transform (metres, degrees, a multiplier; typed, kept on ↩ or when the field is left), its `.obj` (Choose… copies one from elsewhere into `meshes/`) and its triangles, and its modifiers: mirror (across x, y or z, welded or not), array (copies, how far apart) and subdivide (levels; each is four times the triangles). They run in order, can be turned off or moved, and are never written into the `.obj`. A modifier from a later Proton is kept and shown as not understood. A scene past 500,000 triangles is refused, with the reason.

**Edit mode** (`⇥`, Edit the Mesh in the inspector, or the dock's pencil) opens the chosen object's mesh: its faces as the file has them, quads kept as quads, drawn without its modifiers, with its edges over it. Choose corners, edges or faces (`1` `2` `3`) with a click, `⇧`-click to add or take away. Then:
- **Drag what's chosen** to slide it along its normal: the face is the handle, as the design has it. `⌥`-drag pulls the chosen faces out first. A drag anywhere else still turns the view.
- **Extrude** (`e`) pulls the chosen faces out together, walls round their rim. **Inset** (`i`) makes a smaller face inside each, its edges the amount in. **Loop Cut** (`⌘R`) cuts across the ring of quads the chosen edge belongs to, part of the way along each edge. **Bevel** (`b`) turns each chosen edge into a face of its own, the width across (in Faces, every edge of the faces chosen), one segment; a cube's corner where three bevels meet gets a triangle. **Delete** (`⌫`) takes out what's chosen. The amounts are in the inspector.
- Each is one undo step, and a drag is one step however long. Edit mode's steps are its own: they go when you leave it.

Edit mode writes the `.obj`, 300 ms after each edit and on leaving, but only a copy the object owns. A file another object draws, one of the primitives Add writes, or one with texture coordinates, normals, materials or groups (which Edit mode can't keep) is copied to `meshes/<name> mesh.obj` first, and the notice says so. So a file from Blender is never written over. Leaving (`⇥`, or Done) draws it with its modifiers again.

Keys: `f` frame the chosen object, or everything · `⇧A` frame everything · `⌫` remove · `⎋` choose nothing · `⇥` Edit mode · `⌘N` new scene · `⌘O` open · `⇧⌘W` back to all scenes. In Edit mode: `1` `2` `3` corners, edges, faces · `e` extrude · `i` inset · `b` bevel · `⌘R` loop cut · `a` everything · `⌫` delete · `f` frame what's chosen · `⎋` nothing, then back to the objects. Scene ▸ Add, and the omnibar, add objects and modifiers.

**Materials** are layer stacks, in the inspector's Material section: a base (colour, metal, roughness) and up to eight layers over it, top first. A layer is **Solid** (everywhere, by its amount), **Noise** (blots of its scale and detail, with how much of the surface they cover and how hard their edge is) or **Checker** (checks of its scale), and has a colour, metal and roughness of its own. Patterns are in the object's own space, so they stay put as it moves. Add ▸ adds a layer (making a material first, if there's none), the arrows move one up or down, and Change ▸ makes a new material, wears one another object wears, or none. Each change is one undo step; a colour dragged or a slider slid is one step however long. A stack is written into the scene as the ordinary node graph Proton reads, so Proton opens the file. A graph made by hand, which the stack can't show, is kept as it is, and Replace with Layers starts a stack from its surface settings. Scene ▸ New Material and Add a Layer, and the omnibar, do the same. Colours are read by the shader from a buffer, so changing one doesn't compile it again. A material's name is renamed where it's shown, and Change ▸ Remove Unworn Materials takes out every material nothing wears, as one step.

**The graph drawer** (Graph in the Material section, Scene ▸ Show the Material Graph, or the omnibar) opens under the view and draws the material as its node graph, each box where the file puts it, with its settings and wires, fitted to the drawer. It shows what the file holds and doesn't edit it: a stack is edited as layers, and a graph from Proton is kept as it is. A stack's graph is laid out left to right, a layer a column, so it reads in the drawer.

**Render** (`⌘↩`, the rail's Render, or Scene ▸ Render) draws the scene from the view's camera, offscreen: 1024 × 1024, 1536 × 1024, 1024 × 1536 or 2048 × 2048, drawn at twice that with 4× multisampling and scaled down on the GPU, without the grid, the stand-ins, Edit mode's cage or the chosen object's tint, on the dark ground or a clear one. It draws a depth pass too: near white, far black, across what the scene spans in front of the camera, as a diffusion model's depth control wants. Both are written into `renders/` beside the scene and published as the project's assets, "<Scene> Render" and "<Scene> Depth", a new version each render. A flow's Load Image takes either from its From a Render menu (or the omnibar), and a canvas places either as a layer from the omnibar; both follow each new render. The render drawer shows the last render and its depth, and the size, the camera, the floor, shadows and the background. A render runs in the background, as does encoding and writing it, so the window keeps moving while it's made and while a canvas takes it in.

**Cameras and lights.** A render looks through the view's camera or one of the scene's (the drawer's camera menu, or Render through it in a camera's inspector). A camera looks down its own −Z, as its outline shows, with a field of view (degrees, top to bottom; 50 to start). Camera from the View puts the chosen camera where the view is, looking where it looks, as one step, and a camera added starts there. A light is a **point** (shining every way, fading with the square of the distance; strength 20 to start, at a metre) or a **sun** (shining down its own −Z, the same everywhere; 3 to start), with a colour. Switching kind takes that kind's strength unless it was changed. A light added goes above what's there. The scene's lights shade the view and the render; with none, the view's key light stands in. In a render each light, up to four, casts a shadow from a 2048² map (a sun's square on to what casts, a point's looking at it from outside), onto a floor under everything unless the floor is turned off; the floor is in the depth pass too. These settings are keys on the object Proton doesn't know and keeps: `fov` on a camera, a `light` block on a light.

**Path traced.** Render with Path traced (the drawer's engine, or Scene ▸ Render With) follows light through the scene on Metal's ray tracing: 32 to 2048 samples a pixel, a few at a time, with the samples so far shown and Stop keeping what's there. It shades with the same materials, lights and tone curve as the view, and adds what a raster can't: light that bounces (and comes in from a dim, even room round everything), soft shadows from lights with a size (a point a ball a tenth of a metre across, a sun three degrees wide), and reflections. The depth pass is the quick render's. It needs a Mac whose GPU traces rays (every Apple silicon Mac).

**Denoise.** A path-traced render is denoised unless you turn it off (the drawer's Denoise, or Scene ▸ Denoise Path-Traced Renders). The tracer notes what each pixel first saw: the surface's colour, which way it faced and how far off it was. An edge-aware filter then smooths the light where those agree and the samples are unsure. Texture and edges stay sharp, and 16 to 32 samples come out about as smooth as 512 undenoised. The more samples a render has, the less the filter does.

Not yet: a bevel of more than one segment, editing a graph as a graph, a point light's shadow from inside what it lights in the quick render, and the path tracer's textures and glass.

## Game

Proton's own engine, made for a few kinds of game: hand-drawn Metroidvanias like Hollow Knight first, then pixel-art roguelites, isometric action and low-poly 3D (plan §9b). A game is a folder of JSON (`game.json`, `world.json`, a file a room and a prefab) and its art, in Proton's format, so either app opens it. Games live in the project's `Games/`.

- **New game** makes one from Proton's Metroidvania template: two rooms, a player, a crawler, a bench and a gate, their art drawn in code.
- **The stage** shows a room as the game's camera sees it, drawn on Metal: its planes moving by their depth, far ones hazed by the room's fog, lit planes shaded by the room's lights over its ambient (through an image's normal map where it has one), and each light's halo. `⇧P` shows the game's finish (bloom, grade, vignette) while editing, as Play does. Collision is drawn by kind (solid, one-way, hazard, no wall), with the things in the room, its lights and its spawns. Animated things show their resting frame. Drag on nothing or use two fingers to move over the room; pinch or ⌘-scroll to zoom; `f` shows it all.
- **The tools** (in the dock):
  - **Choose and move** (`v`): click anything to choose it and drag it to move it; `⌫` removes it.
  - **Draw collision** (`p`): a click a point, of the kind chosen; double-click or `↩` ends the line, `⎋` drops it. On a chosen line, drag its points, `⌥`-click adds one, and double-click takes one out.
  - **Place a light** (`l`): reach, brightness, halo, waver and colour are set in the inspector.
- **Bringing art in** (Import Art… above the rooms, or drop files on the room): a painter's `.psd` becomes planes of the room on screen, a group a plane at the depth its name gives in square brackets (`Far hills [800]`, `Leaves [-150]`); `[play]` joins the play plane and `[still]` doesn't move. Each layer is trimmed and written under `art/<file>/`, cut into pieces past 2048 px, with normal maps for lights if asked. A `.png` becomes one plane. An Aseprite file or a sprite sheet's JSON becomes an animation. A file from elsewhere is copied into the game first (`art/source/` for painted files, a folder of its own for an animation's). Importing a file again replaces what it made before, as one undo step. In the room inspector: the import's scale and normal maps, each plane's depth and whether it's lit, the room's air, and each prefab's look (a picture or an animation, standing on the middle of its bottom edge).
- **Send to Game** from Canvas (File ▸ Send to Game) brings a canvas into the game open: with frames as an animation, else as a layered file whose layers become planes. From Diffuse's Gallery it brings a picture in as a plane (not a sealed one: a game's art is kept plain).
- **Air**: particles a room hangs on a plane (motes, rain, snow, leaves, embers, dust), held still in the editor and drifting in Play. In Play, bursts fly from what happens: dust as the player jumps and lands, a streak behind a dash, sparks on a blow, a burst where a thing is beaten. Each is a function of the run's clock, so a replay shows the same particles.
- **Place** in the navigator lists the game's prefabs and the built-in kinds (bench, ability, door, gate, trigger): choose one, then click where it goes.
- **Edits** are made by the core whole or not at all, each an undo step (⌘Z undoes the newest wherever it was made), and held until ⌘S.
- **Play** (the rail's Play, or ⌘↩) runs the game as it is, unsaved edits and all, from its start, in the same stage, with no load step. Arrows or WASD move, Z or Space jumps, X swings, C or Shift dashes. Esc stops, and the run is replayed on a fresh copy of the world to check that it ends in the same state. The simulation is Proton's, in whole numbers: Proton's recorded replays end in the same hashes here.

Animations play by their frames in Play. Play is lit, and finished as `game.json`'s `post` says (bloom, a grade from a lookup table n² wide and n tall, vignette), in the game's view letterboxed on the stage. A game whose view `filter` is `nearest` is pixel art: in Play it's drawn at the game's own resolution, on its pixel grid, and scaled up by whole numbers, sharp. Not yet: sound, skeletons drawn, squash, stretch and shake, and the isometric and low-poly cameras.

## Canvas

Canvases are Proton's `.canvas` folders (`canvas.json` and a PNG per layer), edited through `proton-raster`, whose maths is whole numbers only, so the same edit always makes the same pixels. They live in `~/Documents/Aether/Canvases`. With none open, the home page shows them as cards beside the new-canvas form: a name, **Pixel** (a small grid, a palette, a pencil; 16–256 px) or **Paint** (a large canvas and soft brushes; 1024–4096 px), and a size. Dropping a PNG, a Photoshop or an Aseprite file there makes a canvas of it, its layers kept. File ▸ Make a Canvas of a Picture (`⇧⌘O`) does the same.

A stroke is painted as the pen moves and kept as one undo step. Only the 64 × 64 tiles it touches are composited again. On the right are the colour (the swatch opens the colour panel; the palette and recent colours are below), the tool's settings and the layers: add, remove, reorder, show or hide, lock, lock what's clear, rename (double-click), opacity and blend. A pen's pressure sets the brush's size, and its eraser end erases.

**Selections**, as in Proton: the select tool drags out a rectangle, an ellipse or a lasso (`s` again steps through them), and the magic wand takes the pixels like the one clicked. `⇧` adds to what is selected, `⌥` takes away, and both keep only where the two overlap. A feather softens the edge. Marching ants go round it, and every edit keeps to it. The move tool (`v`) drags what is selected, or the whole layer when nothing is. `⌘T` adds handles to scale it, and dragging outside them turns it (`⇧` scales freely and snaps the turn to 15°); `↩` keeps it and `⎋` leaves it. Each move or transform is one undo step: whole pixels on a Pixel canvas, smoothed on a Paint one. The selection moves with it. `⌘C` and `⌘X` put what is selected on the clipboard as a PNG. `⌘V` pastes it back as a new layer where it was, or brings in a picture copied from another app as a new layer. Dropping a picture on an open canvas does the same. Canvas ▸ Crop to the Selection, Turn and Mirror, and Resize… change the whole canvas. Resizing a Pixel canvas uses the nearest pixel, so no new colours appear; a Paint canvas is smoothed.

**The palette**, as in Proton: a new Pixel canvas starts with Proton's sixteen colours, and a small picture imported as one gets its own colours. Click a swatch to draw with it. Add puts the colour you're drawing with into the palette, Ramp adds five shades of it (the hue shifting as a painter's shading does), and Remove takes it out. Double-click a swatch to open the colour panel. Pick a new colour, and Recolour changes the swatch and every pixel of that colour in one undo step. The colour's hex code can be typed. `⇧G` shows the pixel grid once a pixel is 6 points wide or more. `m` and `⇧M` mirror the pencil and shapes across and down the canvas's middle, with the middle line shown dashed.

**Animation**, as in Proton: the timeline above the dock shows every frame small. Click one to show it and draw in it, and drag one to move it. The buttons step back and forward and play. There's a field for how long the frame shows in milliseconds, and buttons to add a clear frame, copy this one after it (`⇧N`) and take it out. Onion skin (`⇧O`) shows the frames either side faintly under each layer, before tinted red and after blue. The inspector sets how many either way and whether they're tinted. Tags name a run of frames ("idle", "walk"), set in the inspector to play on, back, or to the end and back. Click a tag over the frames (or choose it in the timeline) to play only that run. Every frame change is one undo step. Exporting a PNG exports the frame shown.

**The Make panel**, as Proton's: open Make in the inspector for a generator (a sprite, noise or caves, each from a seed) or a filter (outline, shadow, pixelate, fewer colours). Any change shows it on the layer, held to what is selected and not kept. Keep it makes it one edit; Leave it takes it away. Canvas ▸ Grow ×2 and ×3 enlarge the whole canvas by Scale2x and Scale3x, keeping a pixel picture's edges crisp.

**Export** (`⌘E`, or Export in the rail) writes the frame shown as a PNG, every frame on a sprite sheet with the JSON Aseprite writes beside it (as near a square as they make, or in a row), or the frame shown as a Photoshop file with its layers. A PNG or a sheet can be ×1, ×2, ×4 or ×8.

**Send to Canvas** in Diffuse's Gallery (the inspector or the context menu) opens the picture as a new canvas named after it, whose layer follows the flow's newest picture (see The project). A plain picture's canvas is written into Canvases at once. A sealed picture is unlocked first and sent as a copy, and its canvas isn't written until you save it, since canvases are saved plain.

Keys: `b` brush (pencil on a Pixel canvas) · `n` the other · `e` eraser · `g` fill · `i` pick (or `⌥`-click) · `l` `r` `o` line, rectangle, ellipse (`⇧` squares them) · `s` select · `w` magic wand · `v` move · `⌘T` scale and turn · `⌘A` `⌘D` `⇧⌘I` select all, nothing, the rest · `⌫` clear what is selected · `⌘C` `⌘X` `⌘V` copy, cut, paste · `[` `]` size · `p` pixel-perfect · `m` `⇧M` mirror across, down · `⇧G` the pixel grid · `,` `.` the frame before, after · `↩` play or stop · `⇧N` copy the frame · `⇧O` onion skin · `f` fit · `1` 100% · space-drag, or two fingers, to pan · pinch or `⌘`-scroll to zoom · Esc cancels a stroke · `⌘S` save · `⌘E` export · `⇧⌘N` add a layer · `⇧⌘W` back to all canvases.
