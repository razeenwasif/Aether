//! An isometric game, run: walking on the ground in eight directions, away
//! up the screen at the ground's depth, sliding along slanted walls, a dash
//! along the way last walked, a pit that sends the player back, a crawler
//! that comes for them — and the same input making the same run.

use proton_game::format::Niche;
use proton_game::project::Project;
use proton_game::sim::{input, Happened, Sim, World, PX};
use proton_game::template;

/// The isometric template's world, made once: its floor is a large picture.
fn courtyard(_tag: &str) -> World {
    static WORLD: std::sync::OnceLock<World> = std::sync::OnceLock::new();
    WORLD
        .get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("proton-ground-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            template::write(&dir, &template::files("isometric", "Ruin").unwrap()).unwrap();
            let project = Project::open(&dir).unwrap();
            assert_eq!(project.game.get().niche, Niche::Isometric);
            let world = World::cook(&project).unwrap();
            let _ = std::fs::remove_dir_all(&dir);
            world
        })
        .clone()
}

fn px(v: i32) -> i32 {
    v * PX
}

/// A run from `at` (in pixels) in the courtyard.
fn from(tag: &str, at: [i32; 2]) -> Sim {
    let world = courtyard(tag);
    Sim::at(world, 0, [px(at[0]), px(at[1])], 0)
}

fn hold(sim: &mut Sim, held: u32, ticks: u32) -> Vec<Happened> {
    let mut out = Vec::new();
    for _ in 0..ticks {
        sim.step(held);
        out.extend(sim.happened());
    }
    out
}

#[test]
fn the_isometric_template_is_the_same_bytes_every_time_and_cooks_to_the_ground() {
    let started = std::time::Instant::now();
    let a = template::files("isometric", "Ruin").unwrap();
    eprintln!("the isometric template took {:?}", started.elapsed());
    assert_eq!(a, template::files("isometric", "Ruin").unwrap());
    let size = |rel: &str| {
        let file = a.iter().find(|f| f.rel == rel).unwrap_or_else(|| panic!("no {rel}"));
        let reader = png::Decoder::new(file.bytes.as_slice()).read_info().unwrap();
        (reader.info().width, reader.info().height)
    };
    assert_eq!(size("art/floor.png"), (2048, 1024));
    assert_eq!(size("art/pillar.png"), (96, 256));
    for file in a.iter().filter(|f| f.rel.ends_with(".room.json")) {
        let text = String::from_utf8(file.bytes.clone()).unwrap();
        for image in text.split("\"image\": \"").skip(1).map(|rest| &rest[..rest.find('"').unwrap()]) {
            assert!(a.iter().any(|f| f.rel == image), "{} names {image}", file.rel);
        }
    }
    let game = String::from_utf8(a.iter().find(|f| f.rel == "game.json").unwrap().bytes.clone()).unwrap();
    assert!(game.contains("\"niche\": \"isometric\"") && !game.contains("\"ground\""), "the default ground is unsaid: {game}");
    let world = courtyard("cook");
    assert_eq!(world.ground, 128, "half as far up the screen as across");
    // A side-on game has no ground: it falls and jumps as it did.
    let dir = std::env::temp_dir().join(format!("proton-ground-side-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    template::write(&dir, &template::files("metroidvania", "Side").unwrap()).unwrap();
    assert_eq!(World::cook(&Project::open(&dir).unwrap()).unwrap().ground, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn walking_goes_eight_ways_away_at_half_speed_and_never_falls() {
    let mut sim = from("walk", [1000, 960]);
    let run = sim.world.moves.run;
    hold(&mut sim, 0, 5);
    assert_eq!(sim.state.pos, [px(1000), px(960)], "standing still on the ground, nothing pulls it down");
    hold(&mut sim, input::RIGHT, 60);
    assert_eq!(sim.state.vel, [run, 0]);
    assert_eq!(sim.state.pos[1], px(960));
    let mut up = from("walk-up", [1000, 960]);
    hold(&mut up, input::UP, 60);
    assert_eq!(up.state.vel, [0, -run / 2], "away up the screen at half speed");
    let mut both = from("walk-diagonal", [1000, 960]);
    hold(&mut both, input::UP | input::RIGHT, 60);
    assert_eq!(both.state.vel, [run * 181 / 256, -(run * 181 / 256) / 2], "a diagonal no faster than a straight line");
    // Jump does nothing on the ground.
    let mut jump = from("walk-jump", [1000, 960]);
    let happened = hold(&mut jump, input::JUMP, 30);
    assert!(!happened.contains(&Happened::Jumped) && jump.state.pos == [px(1000), px(960)]);
}

#[test]
fn walls_stop_every_way_and_a_slanted_one_is_slid_along() {
    let inside = |p: [i32; 2]| {
        let (dx, dy) = ((p[0] - px(1216)).abs() as f64, (p[1] - px(800)).abs() as f64);
        dx / (1000.0 * PX as f64) + dy / (500.0 * PX as f64) <= 1.0
    };
    // Straight up from the start: the courtyard's top edge stops it, and it
    // goes no further however long it's held.
    let mut sim = from("wall-up", [1100, 900]);
    for _ in 0..30 {
        hold(&mut sim, input::UP, 20);
        assert!(inside(sim.state.pos), "{:?}", [sim.state.pos[0] / PX, sim.state.pos[1] / PX]);
    }
    assert!(sim.state.pos[1] < px(400), "it reached the edge: {:?}", sim.state.pos[1] / PX);
    // Left from the start meets the lower-left edge at a slant, and slides
    // up along it.
    let mut slide = from("wall-slide", [1000, 960]);
    hold(&mut slide, input::LEFT, 400);
    let [x, y] = slide.state.pos;
    assert!(x < px(300) && y < px(860), "slid along the wall to {:?}", [x / PX, y / PX]);
    assert!(inside(slide.state.pos), "{:?}", [x / PX, y / PX]);
}

#[test]
fn a_dash_goes_the_way_last_walked() {
    let mut sim = from("dash", [1000, 960]);
    hold(&mut sim, input::UP | input::RIGHT, 2);
    let before = sim.state.pos;
    let happened = hold(&mut sim, input::UP | input::RIGHT | input::DASH, 1);
    assert!(happened.contains(&Happened::Dashed), "{happened:?}");
    let ticks = sim.world.moves.dash_ticks;
    hold(&mut sim, 0, ticks);
    let moved = [sim.state.pos[0] - before[0], sim.state.pos[1] - before[1]];
    assert!(moved[0] > 0 && moved[1] < 0 && moved[0] > -moved[1], "up and right, foreshortened: {moved:?}");
}

#[test]
fn a_pit_sends_the_player_back_and_costs_health() {
    let mut sim = from("pit", [1250, 860]);
    let health = sim.state.health;
    let mut hurt = false;
    for _ in 0..120 {
        sim.step(input::RIGHT);
        if sim.happened().contains(&Happened::Hurt) {
            hurt = true;
            break;
        }
    }
    assert!(hurt);
    assert_eq!(sim.state.health, health - 1);
    assert!(sim.state.pos[0] < px(1390), "sent back from the pit's edge: {:?}", sim.state.pos);
}

#[test]
fn the_crawler_comes_for_the_player_and_a_swing_lands() {
    let mut sim = from("crawler", [1450, 640]);
    let crawler = sim.state.foes.iter().position(|f| sim.world.actors[f.actor as usize].id == "crawler").unwrap();
    let start = sim.state.foes[crawler].pos;
    hold(&mut sim, 0, 20);
    let near = sim.state.foes[crawler].pos;
    assert!(near[0] < start[0], "it comes toward the player: {start:?} to {near:?}");
    let mut landed = false;
    for _ in 0..30 {
        let happened = hold(&mut sim, input::ATTACK, 1);
        landed |= happened.contains(&Happened::Hit);
        hold(&mut sim, 0, 20);
        if landed {
            break;
        }
    }
    assert!(landed, "a swing to the right meets it");
}

#[test]
fn the_same_input_is_the_same_run() {
    let script: Vec<u32> = (0..600u32)
        .map(|t| match t / 60 {
            0 => input::RIGHT,
            1 => input::UP | input::RIGHT,
            2 => input::UP | input::DASH,
            3 => input::LEFT | input::ATTACK,
            4 => input::DOWN,
            _ => input::DOWN | input::LEFT,
        })
        .collect();
    let run = |tag: &str| {
        let mut sim = from(tag, [1000, 960]);
        for held in &script {
            sim.step(*held);
        }
        sim.hash()
    };
    assert_eq!(run("same-a"), run("same-b"));
}
