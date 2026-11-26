//! Game, for Swift: a game's folder open for editing (`proton-game`'s
//! `Project`: its documents changed by ops, each with its own undo, held
//! until saved), and a run of it (`proton-game`'s simulation, a tick at a
//! time, in whole numbers).
//!
//! Proton played a run as WebAssembly in its window, behind a C ABI
//! (`proton-game-runtime`). Photon runs the same simulation natively, so a
//! run is an object here, and its frame is the runtime's frame word for word
//! — the same header and records — so what Proton's window drew from, the
//! Game workspace draws from, and Proton's recorded replays check this build.

use std::path::Path;
use std::sync::{Arc, Mutex};

use proton_game::doc::Op;
use proton_game::project::{Project, Target};
use proton_game::sim::{Happened, Sim, World};

use crate::{failed, json, lock, DiffuseError};

/// The runtime's ABI version, kept in the frame's first word.
pub const ABI: i32 = 3;
/// Words in a frame's header, before its records.
pub const HEADER: usize = 16;
/// Words in a record.
pub const RECORD: usize = 9;

/// What a tick says happened, a bit each (`proton-game-runtime`'s).
pub mod happened {
    pub const JUMPED: u32 = 1;
    pub const LANDED: u32 = 2;
    pub const DASHED: u32 = 4;
    pub const HURT: u32 = 8;
    pub const ENTERED: u32 = 16;
    pub const GAINED: u32 = 32;
    pub const CUE: u32 = 64;
    pub const SWUNG: u32 = 128;
    pub const HIT: u32 = 256;
    pub const KILLED: u32 = 512;
    pub const DIED: u32 = 1024;
    pub const RESTED: u32 = 2048;
    pub const FLAG: u32 = 4096;
    pub const SHOT: u32 = 8192;
}

/// The games in `folder`: each folder in it (or it itself) holding a
/// `game.json`. JSON: a list of `{path, name, rooms}`, by name.
#[uniffi::export]
pub fn game_found(folder: String) -> String {
    let root = Path::new(&folder);
    let mut dirs = vec![root.to_path_buf()];
    if let Ok(entries) = std::fs::read_dir(root) {
        dirs.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()));
    }
    let mut found: Vec<serde_json::Value> = dirs
        .into_iter()
        .filter(|d| Project::is_game(d))
        .filter_map(|d| {
            let project = Project::open(&d).ok()?;
            Some(serde_json::json!({
                "path": d.to_string_lossy(),
                "name": project.game.get().name,
                "rooms": project.rooms.len(),
            }))
        })
        .collect();
    found.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    json(&found)
}

/// A new game called `name` in `dir`, from one of proton-game's templates:
/// `metroidvania` (two side-on rooms, a player, a crawler and their art) or
/// `isometric` (a courtyard on the ground, a pit, a pillar and a crawler),
/// drawn in code. Refused if `dir` already holds a game.
#[uniffi::export]
pub fn game_create(dir: String, name: String, kind: String) -> Result<(), DiffuseError> {
    let files = proton_game::template::files(&kind, &name).map_err(failed)?;
    proton_game::template::write(Path::new(&dir), &files).map_err(failed)
}

/// One game open for editing.
#[derive(uniffi::Object)]
pub struct GameEditor {
    pub(crate) held: Mutex<Project>,
}

fn target(text: &str) -> Result<Target, DiffuseError> {
    Target::parse(text).ok_or_else(|| failed(format!("{text} is not one of a game's documents")))
}

#[uniffi::export]
impl GameEditor {
    /// The game in the folder at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<GameEditor>, DiffuseError> {
        Ok(Arc::new(GameEditor { held: Mutex::new(Project::open(Path::new(&path)).map_err(failed)?) }))
    }

    /// Everything but the rooms, as JSON: the game, the world, the prefabs,
    /// a row a room, and what is unsaved.
    pub fn view(&self) -> String {
        let p = lock(&self.held);
        let rooms: Vec<serde_json::Value> = p
            .rooms
            .iter()
            .map(|r| serde_json::json!({ "id": r.get().id, "size": r.get().size, "dirty": r.is_dirty(), "canUndo": r.can_undo(), "canRedo": r.can_redo() }))
            .collect();
        let prefabs: Vec<_> = p.prefabs.iter().map(|d| d.get().clone()).collect();
        json(&serde_json::json!({
            "path": p.root().to_string_lossy(),
            "game": p.game.get(),
            "world": p.world.get(),
            "prefabs": prefabs,
            "rooms": rooms,
            "unsaved": p.unsaved_files(),
            "problems": p.problems(),
        }))
    }

    /// Room `id`, as JSON, as it is now.
    pub fn room(&self, id: String) -> Option<String> {
        lock(&self.held).room(&id).map(|r| json(r.get()))
    }

    /// A batch of ops (JSON, Proton's `GameOp`s) on one document — `game`,
    /// `world`, `room:<id>` or `prefab:<id>` — whole or not at all. Whether
    /// it changed anything.
    pub fn apply(&self, target_name: String, ops: String) -> Result<bool, DiffuseError> {
        let ops: Vec<Op> = serde_json::from_str(&ops).map_err(|e| failed(format!("not ops: {e}")))?;
        lock(&self.held).apply(&target(&target_name)?, &ops).map_err(failed)
    }

    pub fn undo(&self, target_name: String) -> Result<bool, DiffuseError> {
        lock(&self.held).undo(&target(&target_name)?).map_err(failed)
    }

    pub fn redo(&self, target_name: String) -> Result<bool, DiffuseError> {
        lock(&self.held).redo(&target(&target_name)?).map_err(failed)
    }

    /// Write every changed document; the files written.
    pub fn save(&self) -> Result<Vec<String>, DiffuseError> {
        lock(&self.held).save().map_err(failed)
    }

    /// The files changed and not saved.
    pub fn unsaved(&self) -> Vec<String> {
        lock(&self.held).unsaved_files()
    }

    /// A run of the game as it is now, unsaved edits and all: its world
    /// cooked, not started.
    pub fn run(&self) -> Result<Arc<GameRun>, DiffuseError> {
        let world = World::cook(&lock(&self.held)).map_err(failed)?;
        Ok(GameRun::of(world))
    }
}

/// A run: a cooked world, and the simulation stepping through it.
#[derive(uniffi::Object)]
pub struct GameRun {
    held: Mutex<Running>,
}

struct Running {
    world: World,
    sim: Option<Sim>,
    /// The cues the last tick said, by their place in the world's.
    cues: Vec<u32>,
}

impl GameRun {
    fn of(world: World) -> Arc<GameRun> {
        Arc::new(GameRun { held: Mutex::new(Running { world, sim: None, cues: Vec::new() }) })
    }
}

#[uniffi::export]
impl GameRun {
    /// A run of a world already cooked, as JSON: a replay's.
    #[uniffi::constructor]
    pub fn from_world(world: String) -> Result<Arc<GameRun>, DiffuseError> {
        let world: World = serde_json::from_str(&world).map_err(|e| failed(format!("not a world: {e}")))?;
        if world.rooms.is_empty() {
            return Err(failed("the world has no rooms"));
        }
        Ok(GameRun::of(world))
    }

    /// What the window needs of the world, as JSON: ticks a second, the
    /// camera's view, the rooms' ids, the images frames name, where a run
    /// starts, and the cues' names.
    pub fn info(&self) -> String {
        let r = lock(&self.held);
        let w = &r.world;
        json(&serde_json::json!({
            "tick": w.tick,
            "view": w.view,
            "rooms": w.rooms.iter().map(|room| room.id.clone()).collect::<Vec<_>>(),
            "sprites": w.sprites,
            "start": { "room": w.start.0, "at": w.start.1 },
            "cues": w.cues,
            "health": w.fight.health,
        }))
    }

    /// The world as cooked, as JSON: what a replay starts from.
    pub fn world(&self) -> String {
        serde_json::to_string(&lock(&self.held).world).unwrap_or_default()
    }

    /// Start (or start again) in room `room` at `x`, `y` (1/256 px), with
    /// `abilities` had.
    pub fn start(&self, room: u32, x: i32, y: i32, abilities: u32) -> Result<(), DiffuseError> {
        let mut r = lock(&self.held);
        if room as usize >= r.world.rooms.len() {
            return Err(failed(format!("there is no room {room}")));
        }
        let world = r.world.clone();
        r.sim = Some(Sim::at(world, room as u16, [x, y], abilities));
        r.cues.clear();
        Ok(())
    }

    /// Start where the game says a run starts.
    pub fn start_at_start(&self) -> Result<(), DiffuseError> {
        let (room, at) = lock(&self.held).world.start;
        self.start(room as u32, at[0], at[1], 0)
    }

    /// One tick with `input` held (a bit an action, `sim::input`). Bits of
    /// what happened.
    pub fn step(&self, input: u32) -> u32 {
        let mut r = lock(&self.held);
        let held = &mut *r;
        let Some(sim) = held.sim.as_mut() else { return 0 };
        sim.step(input);
        let said = sim.happened();
        held.cues = said.iter().filter_map(|w| if let Happened::Cue(c) = w { Some(*c as u32) } else { None }).collect();
        said.iter().fold(0, |bits, what| bits | bit(what))
    }

    /// The cues the last tick said, by their place in the world's.
    pub fn cues(&self) -> Vec<u32> {
        lock(&self.held).cues.clone()
    }

    /// The frame, as the runtime's: a header, then a record a drawn thing.
    ///
    /// Header: abi, tick, room, camera x, camera y (1/256 px), how far
    /// through a door (0 none, else 1–24), deaths, abilities, count, player
    /// x, player y (1/256 px), grounded, health, the most health, things
    /// beaten, ticks held still for a blow. Record: sprite (-1 a shot with no
    /// image), x, y (pixels), pivot x, pivot y, look bits (1 flip, 2 flash,
    /// 4 blink), the animation's frame and its clip (-1 for a still image),
    /// and who it is (0 the player, a thing one more than its place in the
    /// room, a shot `SHOT` and more).
    pub fn frame(&self) -> Vec<i32> {
        let r = lock(&self.held);
        let Some(sim) = r.sim.as_ref() else {
            let mut empty = vec![0; HEADER];
            empty[0] = ABI;
            return empty;
        };
        let s = &sim.state;
        let drawn = sim.frame();
        let mut out = vec![
            ABI,
            s.tick as i32,
            s.room as i32,
            s.cam[0],
            s.cam[1],
            s.door.map(|(_, _, t)| t as i32 + 1).unwrap_or(0),
            s.deaths as i32,
            s.abilities as i32,
            drawn.len() as i32,
            s.pos[0],
            s.pos[1],
            s.grounded as i32,
            s.health,
            sim.world.fight.health,
            s.kills as i32,
            s.stop as i32,
        ];
        for d in drawn {
            let look = (d.flip as i32) | (d.flash as i32) << 1 | (d.blink as i32) << 2;
            out.extend([
                d.sprite.map_or(-1, |s| s as i32),
                d.at[0],
                d.at[1],
                d.pivot[0],
                d.pivot[1],
                look,
                d.frame.map_or(-1, |f| f as i32),
                d.clip.map_or(-1, |c| c as i32),
                d.who as i32,
            ]);
        }
        out
    }

    /// The boxes the run tests now: count, then each as hit (1) or hurt (0)
    /// and its left, top, right, bottom in 1/256 px.
    pub fn boxes(&self) -> Vec<i32> {
        let r = lock(&self.held);
        let Some(sim) = r.sim.as_ref() else { return vec![0] };
        let found = sim.boxes();
        let mut out = vec![found.len() as i32];
        for b in found {
            out.extend([b.hit as i32, b.rect[0], b.rect[1], b.rect[2], b.rect[3]]);
        }
        out
    }

    /// The run's state as one number: two runs with the same one are the
    /// same run.
    pub fn hash(&self) -> u64 {
        lock(&self.held).sim.as_ref().map(Sim::hash).unwrap_or(0)
    }
}

fn bit(what: &Happened) -> u32 {
    match what {
        Happened::Jumped => happened::JUMPED,
        Happened::Landed => happened::LANDED,
        Happened::Dashed => happened::DASHED,
        Happened::Hurt => happened::HURT,
        Happened::Entered(_) => happened::ENTERED,
        Happened::Gained(_) => happened::GAINED,
        Happened::Cue(_) => happened::CUE,
        Happened::Swung => happened::SWUNG,
        Happened::Hit => happened::HIT,
        Happened::Killed(_) => happened::KILLED,
        Happened::Died => happened::DIED,
        Happened::Rested => happened::RESTED,
        Happened::Flag(_) => happened::FLAG,
        Happened::Shot => happened::SHOT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixtures() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../proton-game/tests/fixtures")
    }

    fn read(name: &str) -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(fixtures().join(name)).unwrap()).unwrap()
    }

    /// A replay's runs of input, as `[held, ticks]` pairs.
    fn runs(value: &serde_json::Value) -> Vec<(u32, u32)> {
        value.as_array().unwrap().iter().map(|r| (r[0].as_u64().unwrap() as u32, r[1].as_u64().unwrap() as u32)).collect()
    }

    fn started(world: &str, start: &serde_json::Value) -> Arc<GameRun> {
        let run = GameRun::from_world(world.to_string()).unwrap();
        let s: Vec<i32> = start.as_array().unwrap().iter().map(|v| v.as_i64().unwrap() as i32).collect();
        run.start(s[0] as u32, s[1], s[2], s[3] as u32).unwrap();
        run
    }

    /// The frame the player's record shows: the record whose `who` is 0.
    fn player_frame(frame: &[i32]) -> i32 {
        let count = frame[8] as usize;
        (0..count).map(|i| &frame[HEADER + i * RECORD..HEADER + (i + 1) * RECORD]).find(|r| r[8] == 0).map_or(-1, |r| r[6])
    }

    /// Proton's replays, recorded from its window's WebAssembly and its
    /// core's native runs: Photon's run of the same world and input ends in
    /// the same hash (M4's exit criterion: "replay check matches Proton's").
    #[test]
    fn protons_replay_ends_in_its_recorded_hash() {
        let world = std::fs::read_to_string(fixtures().join("game-world.json")).unwrap();
        let replay = read("game-replay.json");
        let run = started(&world, &replay["start"]);
        let mut ticks = 0;
        for (held, n) in runs(&replay["replay"]) {
            for _ in 0..n {
                run.step(held);
                ticks += 1;
            }
        }
        let frame = run.frame();
        assert_eq!((frame[1], frame[2]), (ticks, 1), "the tick, and the second room reached");
        assert_eq!(format!("{:016x}", run.hash()), replay["hash"].as_str().unwrap());
    }

    #[test]
    fn protons_animated_and_skeletal_runs_show_the_same_frames_and_cues() {
        for name in ["game-anim.json", "game-skel.json"] {
            let fixture = read(name);
            let run = started(fixture["world"].as_str().unwrap(), &fixture["start"]);
            let (mut frames, mut cues) = (Vec::new(), 0);
            for (held, n) in runs(&fixture["replay"]) {
                for _ in 0..n {
                    if run.step(held) & happened::CUE != 0 {
                        cues += run.cues().len() as u64;
                    }
                    frames.push(player_frame(&run.frame()));
                }
            }
            assert_eq!(format!("{:016x}", run.hash()), fixture["hash"].as_str().unwrap(), "{name}");
            assert_eq!(cues, fixture["cues"].as_u64().unwrap(), "{name}: cues");
            let every_tenth: Vec<i32> = frames.iter().step_by(10).copied().collect();
            assert_eq!(serde_json::json!(every_tenth), fixture["frames"], "{name}: frames");
        }
    }

    #[test]
    fn protons_fight_goes_the_same_way() {
        let fixture = read("game-fight.json");
        let run = started(fixture["world"].as_str().unwrap(), &fixture["start"]);
        let mut drawn = Vec::new();
        let mut tick = 0;
        for (held, n) in runs(&fixture["replay"]) {
            for _ in 0..n {
                run.step(held);
                if tick % 10 == 0 {
                    let f = run.frame();
                    drawn.push([f[8], f[12], f[14], f[15]]);
                }
                tick += 1;
            }
        }
        assert_eq!(format!("{:016x}", run.hash()), fixture["hash"].as_str().unwrap());
        assert_eq!(serde_json::json!(drawn), fixture["drawn"]);
        assert_eq!(serde_json::json!(run.frame()), fixture["frame"], "the last frame, word for word");
        assert_eq!(serde_json::json!(run.boxes()), fixture["boxes"]);
    }

    #[test]
    fn a_new_game_opens_edits_undoes_and_plays() {
        let dir = std::env::temp_dir().join(format!("photon-game-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        game_create(dir.to_string_lossy().into(), "Lumen".into(), "metroidvania".into()).unwrap();
        assert!(game_create(dir.to_string_lossy().into(), "Lumen".into(), "metroidvania".into()).is_err(), "not over an old one");
        let found: serde_json::Value = serde_json::from_str(&game_found(dir.parent().unwrap().to_string_lossy().into())).unwrap();
        assert!(found.as_array().unwrap().iter().any(|g| g["name"] == "Lumen"));

        let editor = GameEditor::open(dir.to_string_lossy().into()).unwrap();
        let view: serde_json::Value = serde_json::from_str(&editor.view()).unwrap();
        let room = view["rooms"][0]["id"].as_str().unwrap().to_string();
        let target = format!("room:{room}");
        let before: serde_json::Value = serde_json::from_str(&editor.room(room.clone()).unwrap()).unwrap();
        let entity = before["entities"][0]["id"].as_str().unwrap().to_string();
        let ops = serde_json::json!([{ "op": "set", "path": ["entities", format!("#{entity}"), "at"], "value": [100, 200] }]);
        assert!(editor.apply(target.clone(), ops.to_string()).unwrap());
        let after: serde_json::Value = serde_json::from_str(&editor.room(room.clone()).unwrap()).unwrap();
        assert_eq!(after["entities"][0]["at"], serde_json::json!([100, 200]));
        assert_eq!(editor.unsaved(), vec![format!("rooms/{room}.room.json")]);
        let bad = serde_json::json!([{ "op": "set", "path": ["size"], "value": "wide" }]);
        assert!(editor.apply(target.clone(), bad.to_string()).is_err(), "a room whose size is a word is refused");
        assert!(editor.undo(target.clone()).unwrap());
        assert_eq!(serde_json::from_str::<serde_json::Value>(&editor.room(room.clone()).unwrap()).unwrap(), before);

        // Played as it is, unsaved edits and all; a tick at a time.
        let run = editor.run().unwrap();
        run.start_at_start().unwrap();
        let info: serde_json::Value = serde_json::from_str(&run.info()).unwrap();
        assert_eq!(info["tick"], 60);
        let first = run.frame();
        for _ in 0..30 {
            run.step(proton_game::sim::input::RIGHT);
        }
        let later = run.frame();
        assert_eq!(later[1], 30);
        assert!(later[9] > first[9], "the player walked right: {} then {}", first[9], later[9]);
        assert!(later[8] >= 1, "something is drawn");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
