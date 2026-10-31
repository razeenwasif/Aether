//! A design's folder, edited: ops whole or not at all, one step each, undone
//! and redone; the theme spliced and its bytes put back; nothing written
//! until saved, and then only what changed.

use std::path::PathBuf;

use aether_design::format::{Kind, Page};
use aether_design::{html, page_rel, starter, Design, Target};
use proton_game::Op;
use serde_json::json;

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("aether-design-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn made(name: &str) -> (PathBuf, Design) {
    let dir = folder(name);
    starter::write(&dir, &starter::files("Lumen")).unwrap();
    let design = Design::open(&dir).unwrap();
    (dir, design)
}

fn ops(value: serde_json::Value) -> Vec<Op> {
    serde_json::from_value(value).unwrap()
}

fn home(design: &Design) -> &Page {
    design.page("home").unwrap().get()
}

fn home_target() -> Target {
    Target::Page("home".into())
}

#[test]
fn the_starter_opens_whole_and_reads_back_to_its_own_bytes() {
    let (dir, design) = made("starter");
    assert_eq!(design.design.get().name, "Lumen");
    assert!(design.unsaved_files().is_empty());
    assert!(design.problems().is_empty(), "{:?}", design.problems());
    let page = home(&design);
    assert_eq!(page.breakpoints.iter().map(|b| b.width).collect::<Vec<_>>(), [1280.0, 390.0]);
    assert_eq!(page.layer(&page.root).map(|l| l.kind), Some(Kind::Frame));
    // What the file says is what writing it again says.
    let text = std::fs::read_to_string(dir.join(page_rel("home"))).unwrap();
    assert_eq!(design.page("home").unwrap().text(), text);
}

#[test]
fn an_edit_is_one_step_and_one_line() {
    let (dir, mut design) = made("one-line");
    let before = design.page("home").unwrap().text();
    let changed = design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#title", "text"], "value": "Carry the light."}]))).unwrap();
    assert!(changed);
    assert_eq!(design.unsaved_files(), [page_rel("home")]);
    let after = design.page("home").unwrap().text();
    let differ: Vec<_> = before.lines().zip(after.lines()).filter(|(a, b)| a != b).collect();
    assert_eq!(differ.len(), 1, "{differ:?}");
    assert_eq!(before.lines().count(), after.lines().count());
    // Nothing on disk until it is saved.
    assert_eq!(std::fs::read_to_string(dir.join(page_rel("home"))).unwrap(), before);
}

#[test]
fn a_batch_that_would_lose_a_layer_changes_nothing() {
    let (_, mut design) = made("orphan");
    let before = home(&design).clone();
    // Taking the hero out of the page's frame leaves it, and all it holds,
    // drawn nowhere.
    let why = design.apply(&home_target(), &ops(json!([{"op": "remove", "path": ["layers", "#page", "children", "1"]}]))).unwrap_err();
    assert!(why.contains("hero is in no frame"), "{why}");
    assert_eq!(home(&design), &before);
    assert!(!design.page("home").unwrap().can_undo());
}

#[test]
fn a_layer_moved_between_frames_is_one_step_undone_whole() {
    let (_, mut design) = made("move");
    let moved = ops(json!([
        {"op": "remove", "path": ["layers", "#hero", "children", "0"]},
        {"op": "insert", "path": ["layers", "#features", "children"], "value": "eyebrow", "at": 0},
    ]));
    assert!(design.apply(&home_target(), &moved).unwrap());
    assert_eq!(home(&design).parent("eyebrow").map(|l| l.id.as_str()), Some("features"));
    assert!(design.undo(&home_target()).unwrap());
    assert_eq!(home(&design).parent("eyebrow").map(|l| l.id.as_str()), Some("hero"));
    assert!(design.redo(&home_target()).unwrap());
    assert_eq!(home(&design).parent("eyebrow").map(|l| l.id.as_str()), Some("features"));
}

#[test]
fn a_layer_in_two_frames_or_a_bad_value_is_refused() {
    let (_, mut design) = made("refused");
    let twice = ops(json!([{"op": "insert", "path": ["layers", "#features", "children"], "value": "title"}]));
    assert!(design.apply(&home_target(), &twice).unwrap_err().contains("title is in both"));
    let width = ops(json!([{"op": "set", "path": ["layers", "#title", "w"], "value": "wide"}]));
    assert!(design.apply(&home_target(), &width).unwrap_err().contains("hug, fill or a number"));
    // A style is written into CSS; one that could close the rule is not one.
    let sneaky = ops(json!([{"op": "set", "path": ["layers", "#title", "style", "color"], "value": "red; } body { display: none"}]));
    assert!(design.apply(&home_target(), &sneaky).is_err());
    let id = ops(json!([{"op": "set", "path": ["id"], "value": "elsewhere"}]));
    assert!(design.apply(&home_target(), &id).is_err());
    assert!(design.unsaved_files().is_empty());
}

#[test]
fn a_token_is_spliced_and_undone_to_the_same_bytes() {
    let (dir, mut design) = made("token");
    let before = design.theme.text().to_string();
    assert!(design.set_token("--color-lantern-500", ":root", "#ffcc66").unwrap());
    let after = design.theme.text().to_string();
    assert_eq!(after, before.replace("--color-lantern-500: #f2b84b", "--color-lantern-500: #ffcc66"));
    assert_eq!(design.unsaved_files(), ["theme.css"]);
    // The same value again is not a step.
    assert!(!design.set_token("--color-lantern-500", ":root", "#ffcc66").unwrap());
    assert!(design.undo(&Target::Theme).unwrap());
    assert_eq!(design.theme.text(), before);
    assert!(design.unsaved_files().is_empty());
    assert!(design.redo(&Target::Theme).unwrap());
    assert_eq!(design.save().unwrap(), ["theme.css"]);
    assert_eq!(std::fs::read_to_string(dir.join("theme.css")).unwrap(), after);
}

#[test]
fn a_token_value_that_would_break_the_stylesheet_is_refused() {
    let (_, mut design) = made("token-refused");
    for bad in ["red; --x: blue", "red }", "", "red /* why */"] {
        assert!(design.set_token("--color-ink", ":root", bad).is_err(), "{bad:?}");
    }
    assert!(design.set_token("--not-there", ":root", "red").is_err());
    assert!(!design.theme.can_undo());
}

#[test]
fn saving_writes_what_changed_and_the_folder_reopens_as_saved() {
    let (dir, mut design) = made("save");
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#logo", "text"], "value": "Lumen"}]))).unwrap();
    design.set_token("--space-8", ":root", "40px").unwrap();
    assert_eq!(design.save().unwrap(), ["theme.css".to_string(), page_rel("home")]);
    assert!(design.unsaved_files().is_empty());
    let again = Design::open(&dir).unwrap();
    assert_eq!(home(&again).layer("logo").unwrap().text, "Lumen");
    assert_eq!(again.theme.tokens().iter().find(|t| t.name == "--space-8").unwrap().value, "40px");
    // Undo survives the save, and undoing past it is unsaved again.
    design.undo(&home_target()).unwrap();
    assert_eq!(design.unsaved_files(), [page_rel("home")]);
}

#[test]
fn pages_are_reordered_in_design_json_but_not_added_there() {
    let (_, mut design) = made("pages");
    let add = ops(json!([{"op": "insert", "path": ["pages"], "value": "press"}]));
    assert!(design.apply(&Target::Design, &add).is_err());
    assert_eq!(design.design.get().pages, ["home"]);
    let rename = ops(json!([{"op": "set", "path": ["name"], "value": "Lumen site"}]));
    assert!(design.apply(&Target::Design, &rename).unwrap());
    assert_eq!(design.unsaved_files(), ["design.json"]);
}

#[test]
fn a_page_named_outside_the_folder_is_not_read() {
    let dir = folder("outside");
    std::fs::write(dir.join("design.json"), r#"{"format": 1, "name": "x", "pages": ["../../etc"]}"#).unwrap();
    assert!(Design::open(&dir).is_err());
}

#[test]
fn a_token_the_theme_lacks_is_said_not_refused() {
    let (_, mut design) = made("missing");
    let set = ops(json!([{"op": "set", "path": ["layers", "#title", "style", "color"], "value": "--color-moth"}]));
    assert!(design.apply(&home_target(), &set).unwrap());
    assert_eq!(design.problems(), ["Home uses --color-moth, which theme.css doesn't have"]);
}

#[test]
fn the_page_is_written_as_html_styled_by_the_theme() {
    let (_, mut design) = made("html");
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#logo", "text"], "value": "<Lumen> & co"}]))).unwrap();
    let page = home(&design);
    let doc = html::document(page, "theme.css", "");
    assert!(doc.starts_with("<!doctype html>"));
    assert!(doc.contains("<link rel=\"stylesheet\" href=\"theme.css\">"));
    assert!(doc.contains("<h1 class=\"title\">Carry the light through the Hollow Grove.</h1>"), "{doc}");
    assert!(doc.contains("&lt;Lumen&gt; &amp; co"));
    // Tokens are the theme's custom properties, not their values.
    assert!(doc.contains("background: var(--color-lantern-500);"));
    assert!(!doc.contains("#f2b84b"));
    // A fill in a row that wraps grows from its narrowest.
    let card = html::css(page, "lantern");
    assert!(card.contains("flex: 1 1 240px;"), "{card}");
    // The buttons hug their labels, down the hero's column.
    let actions = html::css(page, "actions");
    assert!(actions.contains(".actions {\n  display: flex;\n  flex-direction: row;"), "{actions}");
    assert!(html::markup(page, "actions", "").starts_with("<div class=\"actions\">\n  <a class=\"wishlist\">"));
}

#[test]
fn a_breakpoint_says_what_differs_and_the_narrower_ones_inherit_it() {
    let (_, mut design) = made("cascade");
    let page = home(&design).clone();
    assert_eq!(page.at("desktop").layer("title").unwrap().style.font.as_deref(), Some("--type-display"));
    assert_eq!(page.at("mobile").layer("title").unwrap().style.font.as_deref(), Some("--type-display-sm"));
    // A third, between: what it says holds for Mobile too, unless Mobile
    // says otherwise.
    let tablet = ops(json!([
        {"op": "insert", "path": ["breakpoints"], "value": {"id": "tablet", "name": "Tablet", "width": 768}, "at": 1},
        {"op": "set", "path": ["layers", "#features", "at"], "value": {"tablet": {"layout": {"direction": "column"}}}},
        {"op": "set", "path": ["layers", "#logo", "at"], "value": {"tablet": {"hidden": true}, "mobile": {"hidden": false}}},
    ]));
    assert!(design.apply(&home_target(), &tablet).unwrap());
    let page = home(&design).clone();
    assert_eq!(page.at("mobile").layer("features").unwrap().layout.direction.as_deref(), Some("column"));
    assert_eq!(page.at("desktop").layer("features").unwrap().layout.direction.as_deref(), Some("row"));
    assert!(page.at("tablet").layer("logo").unwrap().hidden);
    assert!(!page.at("mobile").layer("logo").unwrap().hidden);
}

#[test]
fn what_a_breakpoint_says_is_checked_too() {
    let (_, mut design) = made("checked-at");
    for (value, why) in [
        (json!({"watch": {"w": "fill"}}), "isn't one of the page's breakpoints"),
        (json!({"desktop": {"w": "fill"}}), "the page's widest"),
        (json!({"mobile": {"w": "wide"}}), "at mobile, title's width"),
        (json!({"mobile": {"style": {"color": "red; }"}}}), "at mobile, title has a style"),
    ] {
        let why_now = design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#title", "at"], "value": value}]))).unwrap_err();
        assert!(why_now.contains(why), "{why_now}");
    }
    assert!(design.unsaved_files().is_empty());
}

#[test]
fn each_narrower_breakpoint_is_a_media_query_of_what_changes() {
    let (_, mut design) = made("media");
    let css = html::css(home(&design), "page");
    let media = css.split("@media (max-width: 1279px) {").nth(1).expect("a query below Desktop");
    assert!(media.contains(".title {\n    font: var(--type-display-sm);\n  }"), "{media}");
    assert!(media.contains(".hero {\n    padding: var(--space-12) var(--space-8);\n  }"), "{media}");
    assert!(!media.contains(".logo"), "only what changes");
    // A row become a column: its cards stop growing along it, and what they
    // no longer say is put back.
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#features", "at"], "value": {"mobile": {"layout": {"direction": "column"}, "hidden": false}}}]))).unwrap();
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#availability", "at"], "value": {"mobile": {"hidden": true}}}]))).unwrap();
    let css = html::css(home(&design), "page");
    let media = css.split("@media (max-width: 1279px) {").nth(1).unwrap();
    assert!(media.contains(".lantern {\n    flex: 0 0 auto;\n    align-self: stretch;\n    max-width: 100%;\n    min-width: revert;\n  }"), "{media}");
    assert!(media.contains(".availability {\n    display: none;\n  }"), "{media}");
}

#[test]
fn an_image_is_a_file_in_images_and_is_written_as_img() {
    let (_, mut design) = made("image");
    let add = |src: &str| ops(json!([
        {"op": "insert", "path": ["layers"], "value": {"id": "key-art", "kind": "image", "src": src, "text": "Wren and her lantern", "h": 320, "style": {"fit": "cover", "radius": "--radius-md"}}},
        {"op": "insert", "path": ["layers", "#hero", "children"], "value": "key-art"},
    ]));
    for bad in ["../theme.css", "images/../x.png", "images/a.psd", "/etc/a.png", "images/\"x.png", ""] {
        assert!(design.apply(&home_target(), &add(bad)).is_err(), "{bad:?}");
    }
    assert!(design.apply(&home_target(), &add("images/Key art.png")).unwrap());
    let page = home(&design);
    let html = html::markup(page, "key-art", "../");
    assert_eq!(html, "<img class=\"key-art\" src=\"../images/Key art.png\" alt=\"Wren and her lantern\">\n");
    let css = html::css(page, "key-art");
    assert!(css.contains("display: block;") && css.contains("object-fit: cover;") && css.contains("height: 320px;"), "{css}");
    // A picture holds no layers.
    let inside = ops(json!([{"op": "insert", "path": ["layers", "#key-art", "children"], "value": "title"}]));
    assert!(design.apply(&home_target(), &inside).is_err());
}
