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
fn a_token_is_given_a_schemes_value_in_its_block_and_undone_to_the_same_bytes() {
    let (_, mut design) = made("schemes");
    let before = design.theme.text().to_string();
    let light = aether_design::theme::ThemeDoc::scheme_scope("light");
    // Into the light block, after its last token, as indented.
    assert!(design.add_token("--radius-md", "light", "6px").unwrap());
    let after = design.theme.text().to_string();
    assert!(after.contains("    --color-lantern-ink: #fffaf0;\n    --radius-md: 6px;\n  }"), "{after}");
    assert!(design.theme.tokens().iter().any(|t| t.name == "--radius-md" && t.scope == light));
    // Said again, it's a set.
    assert!(design.add_token("--radius-md", "light", "4px").unwrap());
    assert_eq!(design.theme.text().matches("--radius-md").count(), 2);
    // No dark block yet: one of its own, at the end.
    assert!(design.add_token("--color-ground", "dark", "#05070a").unwrap());
    assert!(design.theme.text().ends_with("@media (prefers-color-scheme: dark) {\n  :root {\n    --color-ground: #05070a;\n  }\n}\n"));
    for _ in 0..3 {
        assert!(design.undo(&Target::Theme).unwrap());
    }
    assert_eq!(design.theme.text(), before);
    for (name, scheme, value) in [("color", "dark", "red"), ("--x", "dusk", "red"), ("--x", "dark", "red; }")] {
        assert!(design.add_token(name, scheme, value).is_err(), "{name} {scheme} {value}");
    }
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
    let doc = html::document(page, &design.component_map(), "theme.css", "");
    assert!(doc.starts_with("<!doctype html>"));
    assert!(doc.contains("<link rel=\"stylesheet\" href=\"theme.css\">"));
    assert!(doc.contains("<h1 class=\"title\">Carry the light through the Hollow Grove.</h1>"), "{doc}");
    assert!(doc.contains("&lt;Lumen&gt; &amp; co"));
    // Tokens are the theme's custom properties, not their values.
    assert!(doc.contains("background: var(--color-lantern-500);"));
    assert!(!doc.contains("#f2b84b"));
    // A fill in a row that wraps grows from its narrowest.
    let card = html::css(page, &design.component_map(), "lantern");
    assert!(card.contains("flex: 1 1 240px;"), "{card}");
    // The buttons hug their labels, down the hero's column.
    let actions = html::css(page, &design.component_map(), "actions");
    assert!(actions.contains(".actions {\n  display: flex;\n  flex-direction: row;"), "{actions}");
    assert!(html::markup(page, &design.component_map(), "actions", "").starts_with("<div class=\"actions\">\n  <a class=\"wishlist button button--variant-primary\">"));
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
    let css = html::css(home(&design), &design.component_map(), "page");
    let media = css.split("@media (max-width: 1279px) {").nth(1).expect("a query below Desktop");
    assert!(media.contains(".title {\n    font: var(--type-display-sm);\n  }"), "{media}");
    assert!(media.contains(".hero {\n    padding: var(--space-12) var(--space-8);\n  }"), "{media}");
    assert!(!media.contains(".logo"), "only what changes");
    // A row become a column: its cards stop growing along it, and what they
    // no longer say is put back.
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#features", "at"], "value": {"mobile": {"layout": {"direction": "column"}, "hidden": false}}}]))).unwrap();
    design.apply(&home_target(), &ops(json!([{"op": "set", "path": ["layers", "#availability", "at"], "value": {"mobile": {"hidden": true}}}]))).unwrap();
    let css = html::css(home(&design), &design.component_map(), "page");
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
    let html = html::markup(page, &design.component_map(), "key-art", "../");
    assert_eq!(html, "<img class=\"key-art\" src=\"../images/Key art.png\" alt=\"Wren and her lantern\">\n");
    let css = html::css(page, &design.component_map(), "key-art");
    assert!(css.contains("display: block;") && css.contains("object-fit: cover;") && css.contains("height: 320px;"), "{css}");
    // A picture holds no layers.
    let inside = ops(json!([{"op": "insert", "path": ["layers", "#key-art", "children"], "value": "title"}]));
    assert!(design.apply(&home_target(), &inside).is_err());
}

fn component_target(id: &str) -> Target {
    Target::Component(id.into())
}

#[test]
fn an_instance_is_expanded_into_its_component_as_its_options_say() {
    let (_, design) = made("expand");
    assert_eq!(design.components.iter().map(|c| c.get().id.as_str()).collect::<Vec<_>>(), ["button"]);
    assert!(design.problems().is_empty(), "{:?}", design.problems());
    let page = design.expanded("home").unwrap();
    let wishlist = page.layer("wishlist").unwrap();
    assert_eq!(wishlist.kind, Kind::Frame);
    assert_eq!(wishlist.style.fill.as_deref(), Some("--color-lantern-500"));
    assert_eq!(wishlist.tag, "a", "the instance's tag");
    assert_eq!(wishlist.children, ["wishlist.label"]);
    assert_eq!(page.layer("wishlist.label").unwrap().text, "Wishlist now");
    let trailer = page.layer("trailer").unwrap();
    assert_eq!((trailer.style.fill.as_deref(), trailer.style.stroke.as_deref()), (Some("transparent"), Some("--color-line")));
    assert_eq!(page.layer("trailer.label").unwrap().style.color.as_deref(), Some("--color-ink"));
    assert_eq!(design.uses()["button"], [("home".to_string(), "wishlist".to_string()), ("home".to_string(), "trailer".to_string())]);
}

#[test]
fn a_component_is_written_once_and_its_instances_by_its_classes() {
    let (_, design) = made("component-css");
    let components = design.component_map();
    let page = home(&design);
    let markup = html::markup(page, &components, "actions", "");
    assert!(markup.contains("<a class=\"trailer button button--variant-secondary\">\n    <p class=\"button__label\">Watch the trailer</p>\n  </a>"), "{markup}");
    let css = html::css(page, &components, "page");
    assert_eq!(css.matches(".button {").count(), 1, "{css}");
    assert!(css.contains(".button--variant-secondary {\n  background: transparent;\n  border: 1px solid var(--color-line);\n}"), "{css}");
    assert!(css.contains(".button--variant-secondary .button__label {\n  color: var(--color-ink);\n}"), "{css}");
    // The instance's own class says only where it sits.
    assert!(css.contains(".wishlist {\n  flex: 0 0 auto;\n}"), "{css}");
    let own = html::component_css(&components["button"]);
    assert!(own.starts_with(".button {\n  display: flex;") && !own.contains("min-height"), "{own}");
}

#[test]
fn an_instance_picks_only_what_its_component_has() {
    let (_, mut design) = made("misfit");
    for (ops_, why) in [
        (json!([{"op": "set", "path": ["layers", "#trailer", "props"], "value": {"variant": "ghost"}}]), "variant=ghost"),
        (json!([{"op": "set", "path": ["layers", "#trailer", "props"], "value": {"size": "lg"}}]), "picks size"),
        (json!([{"op": "set", "path": ["layers", "#trailer", "texts"], "value": {"button": "hi"}}]), "isn't one of button's text layers"),
        (json!([{"op": "set", "path": ["layers", "#trailer", "component"], "value": "card"}]), "isn't one of the design's components"),
    ] {
        let said = design.apply(&home_target(), &ops(ops_)).unwrap_err();
        assert!(said.contains(why), "{said}");
    }
    // Nor can the component take away an option a page picks.
    let narrower = ops(json!([{"op": "set", "path": ["props", "0", "options"], "value": ["primary"]}]));
    let said = design.apply(&component_target("button"), &narrower).unwrap_err();
    assert!(said.contains("variant=secondary"), "{said}");
    assert!(design.unsaved_files().is_empty());
}

#[test]
fn a_change_to_a_component_reaches_every_instance_and_undoes() {
    let (dir, mut design) = made("reach");
    let bigger = ops(json!([{"op": "set", "path": ["layers", "#label", "style", "font"], "value": "--type-title"}]));
    assert!(design.apply(&component_target("button"), &bigger).unwrap());
    let page = design.expanded("home").unwrap();
    for id in ["wishlist.label", "trailer.label"] {
        assert_eq!(page.layer(id).unwrap().style.font.as_deref(), Some("--type-title"));
    }
    assert_eq!(design.unsaved_files(), [component_file("button")]);
    assert!(design.undo(&component_target("button")).unwrap());
    assert_eq!(design.expanded("home").unwrap().layer("trailer.label").unwrap().style.font.as_deref(), Some("--type-label-md"));
    design.redo(&component_target("button")).unwrap();
    design.save().unwrap();
    assert!(std::fs::read_to_string(dir.join("components/button.component.json")).unwrap().contains("--type-title"));
}

fn component_file(id: &str) -> String {
    aether_design::component_rel(id)
}

#[test]
fn a_frame_made_a_component_is_one_step_with_its_file() {
    let (dir, mut design) = made("make");
    design.make_component("home", "lantern", "card", "Card").unwrap();
    let page = home(&design);
    let instance = page.layer("lantern").unwrap();
    assert_eq!((instance.kind, instance.component.as_str(), instance.min_w), (Kind::Instance, "card", Some(240.0)));
    assert!(page.layer("lantern-title").is_none(), "its layers are the component's now");
    let card = design.component("card").unwrap().get();
    assert_eq!(card.root, "lantern");
    assert_eq!(card.layer("lantern").unwrap().min_w, None, "where it sits is the instance's");
    assert_eq!(design.expanded("home").unwrap().layer("lantern.lantern-title").unwrap().text, "A lantern that matters");
    assert_eq!(design.unsaved_files(), [page_rel("home"), component_file("card")]);
    // Nor can the page itself be one.
    assert!(design.make_component("home", "page", "everything", "All").is_err());
    assert!(design.make_component("home", "painted", "card", "Again").unwrap_err().contains("already"));

    let made_step = Target::parse("made:card/home").unwrap();
    assert!(design.undo(&made_step).unwrap());
    assert!(design.component("card").is_none() && home(&design).layer("lantern-title").is_some());
    assert!(design.unsaved_files().is_empty());
    assert!(design.redo(&made_step).unwrap());
    design.save().unwrap();
    let file = dir.join("components/card.component.json");
    assert!(file.exists());
    // Undone after it was saved, the next save takes the file away.
    design.undo(&made_step).unwrap();
    assert_eq!(design.unsaved_files(), [page_rel("home"), component_file("card")]);
    design.save().unwrap();
    assert!(!file.exists());
    assert!(Design::open(&dir).unwrap().component("card").is_none());
}

#[test]
fn a_components_states_are_the_browsers_and_disabled_the_pages() {
    let (_, mut design) = made("states");
    let components = design.component_map();
    let css = html::component_css(&components["button"]);
    assert!(css.contains(".button:hover:not(.button--state-disabled) {\n  opacity: 0.85;\n}"), "{css}");
    assert!(css.contains(".button:active:not(.button--state-disabled) {\n  opacity: 0.7;\n}"), "{css}");
    assert!(css.contains(".button--state-disabled {\n  opacity: 0.4;\n}"), "{css}");
    // States come after the options, so a state wins where both hold.
    assert!(css.find(".button--variant-secondary {").unwrap() < css.find(":hover").unwrap());

    // A page can make one disabled, and nothing else.
    let disable = ops(json!([{"op": "set", "path": ["layers", "#trailer", "props", "state"], "value": "disabled"}]));
    assert!(design.apply(&home_target(), &disable).unwrap());
    let page = design.expanded("home").unwrap();
    assert_eq!(page.layer("trailer").unwrap().style.opacity, Some(0.4));
    let markup = html::markup(home(&design), &design.component_map(), "trailer", "");
    assert!(markup.starts_with("<a class=\"trailer button button--state-disabled button--variant-secondary\" aria-disabled=\"true\">"), "{markup}");
    let hover = ops(json!([{"op": "set", "path": ["layers", "#wishlist", "props", "state"], "value": "hover"}]));
    assert!(design.apply(&home_target(), &hover).unwrap_err().contains("only disabled"));

    // A state the component doesn't list can't be said, nor a prop take its name.
    let focus = ops(json!([{"op": "set", "path": ["layers", "#label", "when", "state=focus"], "value": {"style": {"color": "red"}}}]));
    assert!(design.apply(&component_target("button"), &focus).unwrap_err().contains("state=focus"));
    let named = ops(json!([{"op": "insert", "path": ["props"], "value": {"name": "state", "options": ["a"]}}]));
    assert!(design.apply(&component_target("button"), &named).unwrap_err().contains("can't be called state"));
    // Nor can a state go while a page picks it.
    let fewer = ops(json!([{"op": "set", "path": ["states"], "value": ["hover"]}]));
    assert!(design.apply(&component_target("button"), &fewer).unwrap_err().contains("disabled"));
}

#[test]
fn an_instance_detached_is_its_components_layers_as_its_own() {
    let (_, mut design) = made("detach");
    design.detach("home", "trailer").unwrap();
    let page = home(&design);
    let trailer = page.layer("trailer").unwrap();
    assert_eq!((trailer.kind, trailer.component.as_str()), (Kind::Frame, ""));
    assert_eq!(trailer.children, ["trailer-label"]);
    assert_eq!((trailer.style.fill.as_deref(), trailer.style.stroke.as_deref()), (Some("transparent"), Some("--color-line")), "as its option made it");
    assert!(trailer.when.is_empty() && trailer.props.is_empty());
    assert_eq!(page.layer("trailer-label").unwrap().text, "Watch the trailer");
    assert_eq!(design.uses()["button"], [("home".to_string(), "wishlist".to_string())]);
    assert!(design.undo(&home_target()).unwrap());
    assert_eq!(home(&design).layer("trailer").unwrap().kind, Kind::Instance);
    assert!(design.detach("home", "hero").unwrap_err().contains("isn't an instance"));
}

/// A design kept in step with a folder beside it, written once.
fn synced(name: &str) -> (PathBuf, Design, PathBuf) {
    let (dir, mut design) = made(name);
    let folder = dir.join("src/components");
    assert!(design.apply(&Target::Design, &ops(json!([{"op": "set", "path": ["sync"], "value": "src/components"}]))).unwrap());
    design.save().unwrap();
    let written = design.sync_out().unwrap();
    assert!(written.contains(&"button.css".to_string()) && written.contains(&"pages/home.html".to_string()), "{written:?}");
    (dir, design, folder)
}

fn edit(folder: &PathBuf, rel: &str, from: &str, to: &str) -> String {
    let text = std::fs::read_to_string(folder.join(rel)).unwrap();
    assert!(text.contains(from), "{rel} has no {from:?}:\n{text}");
    text.replacen(from, to, 1)
}

#[test]
fn what_sync_writes_reads_back_as_no_change() {
    let (_, mut design, folder) = synced("sync-round");
    for rel in ["theme.css", "button.css", "button.html", "pages/home.css", "pages/home.html"] {
        assert!(folder.join(rel).exists(), "{rel}");
    }
    for rel in ["button.css", "button.html", "pages/home.css", "pages/home.html"] {
        let text = std::fs::read_to_string(folder.join(rel)).unwrap();
        let read = design.sync_in(rel, &text).unwrap();
        assert!(!read.changed && read.notes.is_empty(), "{rel}: {:?}", read.notes);
    }
    // The page links the files beside it.
    let page = std::fs::read_to_string(folder.join("pages/home.html")).unwrap();
    assert!(page.contains("href=\"../theme.css\"") && page.contains("href=\"../button.css\"") && page.contains("href=\"home.css\""));
    // Nothing changed, nothing written again.
    assert!(design.sync_out().unwrap().is_empty());
}

#[test]
fn a_components_css_edited_comes_back_as_one_step() {
    let (_, mut design, folder) = synced("sync-css");
    let text = edit(&folder, "button.css", ".button__label {\n", ".button__label {\n  text-align: center;\n");
    let text = text.replacen("border: 1px solid var(--color-line);", "border: 1px solid var(--color-ink);", 1);
    let read = design.sync_in("button.css", &text).unwrap();
    assert!(read.changed && read.target == "component:button", "{read:?}");
    let button = design.component("button").unwrap().get();
    assert_eq!(button.layer("label").unwrap().style.text_align.as_deref(), Some("center"));
    assert_eq!(button.layer("button").unwrap().when["variant=secondary"].style.stroke.as_deref(), Some("--color-ink"));
    assert!(design.undo(&component_target("button")).unwrap());
    assert_eq!(design.component("button").unwrap().get().layer("label").unwrap().style.text_align, None);
}

#[test]
fn a_pages_css_and_its_media_query_come_back() {
    let (_, mut design, folder) = synced("sync-page-css");
    let text = edit(&folder, "pages/home.css", "padding: var(--space-16) var(--space-8);", "padding: 40px var(--space-8);");
    let text = text.replacen("font: var(--type-display-sm);", "font: var(--type-title);", 1);
    let read = design.sync_in("pages/home.css", &text).unwrap();
    assert!(read.changed && read.notes.is_empty(), "{read:?}");
    let page = home(&design);
    assert_eq!(page.layer("hero").unwrap().layout.pad_v, Some(aether_design::format::Val::Num(40.0)));
    assert_eq!(page.layer("title").unwrap().at["mobile"].style.font.as_deref(), Some("--type-title"));
    // How a layer sits in its frame is the inspector's: an edit to it isn't read.
    assert!(text.contains("flex: 1 1 240px;"));
    let sizing = text.replacen("flex: 1 1 240px;", "flex: 1 1 300px;", 1);
    assert!(!design.sync_in("pages/home.css", &sizing).unwrap().changed);
    assert_eq!(home(&design).layer("lantern").unwrap().min_w, Some(240.0));
}

#[test]
fn words_edited_in_the_html_come_back_to_the_page_and_the_instance() {
    let (_, mut design, folder) = synced("sync-html");
    let text = edit(&folder, "pages/home.html", "Carry the light through the Hollow Grove.", "Carry the light &amp; find the way.");
    let text = text.replacen("<p class=\"button__label\">Watch the trailer</p>", "<p class=\"button__label\">See it move<br>now</p>", 1);
    let read = design.sync_in("pages/home.html", &text).unwrap();
    assert!(read.changed, "{read:?}");
    assert_eq!(home(&design).layer("title").unwrap().text, "Carry the light & find the way.");
    assert_eq!(home(&design).layer("trailer").unwrap().texts["label"], "See it move\nnow");
    // The component's own word, and the instance says none of its own.
    let own = text.replacen("See it move<br>now", "Button", 1);
    design.sync_in("pages/home.html", &own).unwrap();
    assert!(home(&design).layer("trailer").unwrap().texts.is_empty());
    let component = edit(&folder, "button.html", ">Button<", ">Go<");
    assert!(design.sync_in("button.html", &component).unwrap().changed);
    assert_eq!(design.component("button").unwrap().get().layer("label").unwrap().text, "Go");
}

#[test]
fn what_sync_cant_take_is_said_and_left() {
    let (_, mut design, folder) = synced("sync-notes");
    let text = edit(&folder, "button.css", ".button__label {\n", ".button__label {\n  box-shadow: 0 1px 2px black;\n");
    let text = format!("{text}\n.glow {{ color: red; }}\n");
    let read = design.sync_in("button.css", &text).unwrap();
    assert!(!read.changed);
    assert_eq!(read.notes.len(), 2, "{:?}", read.notes);
    assert!(read.notes[0].contains("box-shadow") && read.notes[1].contains(".glow"));
    let markup = edit(&folder, "pages/home.html", ">LUMEN<", "><b>LUMEN</b><");
    let read = design.sync_in("pages/home.html", &markup).unwrap();
    assert!(read.notes.iter().any(|n| n.contains("holds markup")), "{:?}", read.notes);
    assert!(design.sync_in("elsewhere/x.css", "").is_err());
}

#[test]
fn a_component_holds_another_and_both_are_drawn_and_written() {
    let (_, mut design) = made("nested");
    design.make_component("home", "hero", "header", "Header").unwrap();
    let header = design.component("header").unwrap().get();
    assert_eq!(header.layer("wishlist").unwrap().kind, Kind::Instance, "the buttons stay instances inside it");
    let page = design.expanded("home").unwrap();
    let wishlist = page.layer("hero.wishlist").unwrap();
    assert_eq!((wishlist.kind, wishlist.component.as_str()), (Kind::Frame, "button"));
    assert_eq!(page.layer("hero.wishlist.label").unwrap().text, "Wishlist now");
    assert_eq!(page.layer("hero.trailer").unwrap().style.stroke.as_deref(), Some("--color-line"), "its option, from inside");
    let components = design.component_map();
    let markup = html::markup(home(&design), &components, "hero", "");
    assert!(markup.contains("<a class=\"header__wishlist button button--variant-primary\">\n"), "{markup}");
    assert!(markup.contains("<p class=\"button__label\">Wishlist now</p>"), "{markup}");
    assert!(markup.contains("<h1 class=\"header__title\">"), "{markup}");
    let css = html::css(home(&design), &components, "page");
    assert_eq!(css.matches(".button {").count(), 1);
    assert!(css.contains(".header__wishlist {\n  flex: 0 0 auto;\n}"), "{css}");
    // The component's own artboards draw what it holds.
    assert!(design.expanded_component("header", Some("variant=x")).unwrap().layer("wishlist.label").is_some());
    assert!(html::component_markup(&components["header"], &components, "").contains("button__label"));
}

#[test]
fn a_component_never_ends_up_inside_itself() {
    let (_, mut design) = made("loop");
    design.make_component("home", "hero", "header", "Header").unwrap();
    let inside = |c: &str| ops(json!([
        {"op": "insert", "path": ["layers"], "value": {"id": "again", "kind": "instance", "component": c}},
        {"op": "insert", "path": ["layers", "#button", "children"], "value": "again"},
    ]));
    let said = design.apply(&component_target("button"), &inside("header")).unwrap_err();
    assert!(said.contains("would be inside itself") && said.contains("holds"), "{said}");
    assert!(design.apply(&component_target("button"), &inside("button")).unwrap_err().contains("inside itself"));
    // An instance inside a component picks only what its component has.
    let wrong = ops(json!([{"op": "set", "path": ["layers", "#wishlist", "props", "variant"], "value": "ghost"}]));
    assert!(design.apply(&component_target("header"), &wrong).unwrap_err().contains("variant=ghost"));
}

#[test]
fn detaching_keeps_the_instances_inside_as_instances() {
    let (_, mut design) = made("detach-nested");
    design.make_component("home", "hero", "header", "Header").unwrap();
    design.detach("home", "hero").unwrap();
    let page = home(&design);
    assert_eq!(page.layer("hero").unwrap().kind, Kind::Frame);
    let wishlist = page.layer("hero-wishlist").unwrap();
    assert_eq!((wishlist.kind, wishlist.component.as_str()), (Kind::Instance, "button"));
    assert_eq!(page.layer("hero-actions").unwrap().children, ["hero-wishlist", "hero-trailer"]);
    assert_eq!(design.expanded("home").unwrap().layer("hero-wishlist.label").unwrap().text, "Wishlist now");
}

#[test]
fn a_component_keeps_what_breakpoints_said_of_its_layers() {
    let (_, mut design) = made("nested-breakpoints");
    design.make_component("home", "hero", "header", "Header").unwrap();
    let header = design.component("header").unwrap().get();
    assert_eq!(header.layer("title").unwrap().at["mobile"].style.font.as_deref(), Some("--type-display-sm"));
    assert_eq!(header.layer("hero").unwrap().at["mobile"].layout.pad_v, Some(aether_design::format::Val::Text("--space-12".into())));
    let page = design.expanded("home").unwrap();
    assert_eq!(page.at("mobile").layer("hero.title").unwrap().style.font.as_deref(), Some("--type-display-sm"));
    assert_eq!(page.at("desktop").layer("hero.title").unwrap().style.font.as_deref(), Some("--type-display"));
    // Written once, on the component's classes, in the page's query.
    let css = html::css(home(&design), &design.component_map(), "page");
    let media = css.split("@media (max-width: 1279px) {").nth(1).unwrap();
    assert!(media.contains(".header__title {\n    font: var(--type-display-sm);\n  }"), "{media}");
    assert!(media.contains(".header {\n    padding: var(--space-12) var(--space-8);\n  }"), "{media}");
    // Uses inside a component count, by the component.
    assert!(design.uses()["button"].contains(&("component:header".to_string(), "wishlist".to_string())));
}

/// A design kept in step with a folder written as React.
fn synced_as_react(name: &str) -> (PathBuf, Design, PathBuf) {
    let (dir, mut design) = made(name);
    let folder = dir.join("src/components");
    let set = ops(json!([
        {"op": "set", "path": ["sync"], "value": "src/components"},
        {"op": "set", "path": ["syncAs"], "value": "react"},
    ]));
    assert!(design.apply(&Target::Design, &set).unwrap());
    design.save().unwrap();
    assert!(std::fs::read_to_string(dir.join("design.json")).unwrap().contains("\"syncAs\": \"react\""));
    let written = design.sync_out().unwrap();
    for rel in ["theme.css", "button.css", "Button.tsx", "pages/home.css", "pages/Home.tsx"] {
        assert!(written.contains(&rel.to_string()), "{rel} not in {written:?}");
    }
    assert!(!folder.join("button.html").exists() && !folder.join("pages/home.html").exists());
    (dir, design, folder)
}

#[test]
fn react_components_take_their_options_and_words_as_props() {
    let (_, mut design, folder) = synced_as_react("react-round");
    let button = std::fs::read_to_string(folder.join("Button.tsx")).unwrap();
    assert!(button.contains("import \"./button.css\";"), "{button}");
    assert!(button.contains("variant?: \"primary\" | \"secondary\";"), "{button}");
    assert!(button.contains("state?: \"hover\" | \"pressed\" | \"disabled\";"), "{button}");
    assert!(button.contains("export function Button({ className, as: Root = \"div\", variant = \"primary\", state, label = \"Button\" }: ButtonProps)"), "{button}");
    assert!(button.contains("<p className=\"button__label\">{label}</p>"), "{button}");
    assert!(button.contains("aria-disabled={state === \"disabled\" || undefined}"), "{button}");
    let page = std::fs::read_to_string(folder.join("pages/Home.tsx")).unwrap();
    assert!(page.contains("import \"../theme.css\";\nimport { Button } from \"../Button\";\nimport \"./home.css\";"), "{page}");
    assert!(page.contains("export default function HomePage()"), "{page}");
    assert!(page.contains("<h1 className=\"title\">Carry the light through the Hollow Grove.</h1>"), "{page}");
    assert!(page.contains("<Button className=\"wishlist\" as=\"a\" label=\"Wishlist now\" />"), "{page}");
    assert!(page.contains("<Button className=\"trailer\" as=\"a\" variant=\"secondary\" label=\"Watch the trailer\" />"), "{page}");
    // Every file reads back as no change, with nothing to say.
    for rel in ["button.css", "Button.tsx", "pages/home.css", "pages/Home.tsx"] {
        let text = std::fs::read_to_string(folder.join(rel)).unwrap();
        let read = design.sync_in(rel, &text).unwrap();
        assert!(!read.changed && read.notes.is_empty(), "{rel}: {:?}", read.notes);
    }
    assert!(design.sync_out().unwrap().is_empty());
    // An HTML file isn't the folder's now.
    assert!(design.sync_in("button.html", "").is_err());
}

#[test]
fn words_and_props_edited_in_react_come_back_as_one_step() {
    let (_, mut design, folder) = synced_as_react("react-edit");
    let text = edit(&folder, "pages/Home.tsx", ">Carry the light through the Hollow Grove.<", ">Carry the light {\"&\"} find the way.<");
    let text = text.replacen("variant=\"secondary\" label=\"Watch the trailer\"", "label={\"See it\\nmove\"}", 1);
    let text = text.replacen("<Button className=\"wishlist\" as=\"a\" label=\"Wishlist now\" />", "<Button className=\"wishlist\" as=\"a\" state=\"disabled\" />", 1);
    let read = design.sync_in("pages/Home.tsx", &text).unwrap();
    assert!(read.changed && read.notes.is_empty() && read.target == "page:home", "{read:?}");
    let page = home(&design);
    assert_eq!(page.layer("title").unwrap().text, "Carry the light & find the way.");
    let trailer = page.layer("trailer").unwrap();
    assert_eq!(trailer.texts["label"], "See it\nmove");
    assert!(trailer.props.is_empty(), "variant taken out: the first option again");
    let wishlist = page.layer("wishlist").unwrap();
    assert_eq!(wishlist.props["state"], "disabled");
    assert!(wishlist.texts.is_empty(), "its words taken out: the component's own");
    // One step, undone whole.
    assert!(design.undo(&home_target()).unwrap());
    assert_eq!(home(&design).layer("trailer").unwrap().props["variant"], "secondary");
    assert_eq!(home(&design).layer("wishlist").unwrap().texts["label"], "Wishlist now");
    // A component's words are its text props' defaults.
    let component = edit(&folder, "Button.tsx", "label = \"Button\"", "label = \"Go\"");
    let read = design.sync_in("Button.tsx", &component).unwrap();
    assert!(read.changed && read.target == "component:button", "{read:?}");
    assert_eq!(design.component("button").unwrap().get().layer("label").unwrap().text, "Go");
    // Written again as the design is now, the page reads back as no change.
    design.sync_out().unwrap();
    let page = std::fs::read_to_string(folder.join("pages/Home.tsx")).unwrap();
    assert!(!design.sync_in("pages/Home.tsx", &page).unwrap().changed);
}

#[test]
fn what_react_cant_take_is_said_and_left() {
    let (_, mut design, folder) = synced_as_react("react-notes");
    let text = edit(&folder, "pages/Home.tsx", "variant=\"secondary\"", "variant=\"ghost\"");
    let text = text.replacen(">LUMEN<", "><b>LUMEN</b><", 1);
    let text = text.replacen("<Button className=\"wishlist\" as=\"a\"", "<Button className=\"wishlist\" as=\"button\" size=\"big\"", 1);
    let read = design.sync_in("pages/Home.tsx", &text).unwrap();
    assert!(!read.changed, "{read:?}");
    let said = read.notes.join("\n");
    assert!(said.contains("variant can be primary, secondary, not ghost"), "{said}");
    assert!(said.contains("Logo holds markup"), "{said}");
    assert!(said.contains("element is the design's to say"), "{said}");
    assert!(said.contains("has no prop size"), "{said}");
    let component = edit(&folder, "Button.tsx", "label = \"Button\"", "label");
    let read = design.sync_in("Button.tsx", &component).unwrap();
    assert!(!read.changed && read.notes.iter().any(|n| n.contains("label has no default")), "{read:?}");
    assert!(design.sync_in("Nothing.tsx", "").is_err());
}

#[test]
fn a_component_inside_a_component_is_imported_and_its_props_read_back() {
    let (_, mut design, folder) = synced_as_react("react-nested");
    design.make_component("home", "hero", "header", "Header").unwrap();
    design.sync_out().unwrap();
    let header = std::fs::read_to_string(folder.join("Header.tsx")).unwrap();
    assert!(header.contains("import { Button } from \"./Button\";"), "{header}");
    assert!(header.contains("<Button className=\"header__trailer\" as=\"a\" variant=\"secondary\" label=\"Watch the trailer\" />"), "{header}");
    assert!(header.contains("title = \"Carry the light through the Hollow Grove.\""), "{header}");
    let page = std::fs::read_to_string(folder.join("pages/Home.tsx")).unwrap();
    assert!(page.contains("import { Header } from \"../Header\";") && page.contains("<Header className=\"hero\" as=\"header\" />"), "{page}");
    let read = design.sync_in("Header.tsx", &header).unwrap();
    assert!(!read.changed && read.notes.is_empty(), "{:?}", read.notes);
    let edited = header.replacen("label=\"Watch the trailer\"", "label=\"Watch it\"", 1);
    assert!(design.sync_in("Header.tsx", &edited).unwrap().changed);
    let trailer = design.component("header").unwrap().get().layer("trailer").unwrap().texts["label"].clone();
    assert_eq!(trailer, "Watch it");
}
