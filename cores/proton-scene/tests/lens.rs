//! Added in Aether: cameras' fields of view and lights' settings.

use proton_scene::{Light, Scene, FOV};

fn scene() -> Scene {
    Scene::parse(r#"{"format": "proton.scene", "objects": [
        {"id": "cam-1", "name": "Camera", "kind": "camera"},
        {"id": "lamp-1", "name": "Lamp", "kind": "light"},
        {"id": "sun-1", "name": "Sun", "kind": "light", "light": {"kind": "sun", "strength": 3}},
        {"id": "cube-1", "name": "Cube", "kind": "mesh"}]}"#).unwrap()
}

#[test]
fn a_scene_from_proton_reads_with_a_plain_camera_and_white_lights() {
    let objects = scene().objects();
    assert_eq!(objects[0].fov, FOV);
    assert_eq!(objects[1].light, Some(Light::default()), "a light with no settings is a white point");
    assert_eq!(objects[2].light, Some(Light { kind: "sun".into(), color: [1.0, 1.0, 1.0], strength: 3.0 }), "what's missing filled in");
    assert_eq!(objects[3].light, None, "only lights have light");
}

#[test]
fn settings_are_written_on_the_object_and_kept_in_range() {
    let mut s = scene();
    assert!(s.set_fov("cam-1", 35.0).unwrap());
    assert!(!s.set_fov("cam-1", 35.0).unwrap(), "the same, no change");
    assert!(s.set_fov("cam-1", 400.0).unwrap());
    assert_eq!(s.objects()[0].fov, 150.0);
    assert!(s.set_fov("cube-1", 35.0).is_err() && s.set_fov("cam-1", f64::NAN).is_err());

    let warm = Light { kind: "point".into(), color: [1.0, 0.8, 2.0], strength: 40.0 };
    assert!(s.set_light("lamp-1", &warm).unwrap());
    assert_eq!(s.objects()[1].light.as_ref().map(|l| l.color), Some([1.0, 0.8, 1.0]), "colour clamped");
    assert!(s.set_light("lamp-1", &Light { kind: "spot".into(), ..warm.clone() }).is_err());
    assert!(s.set_light("cam-1", &warm).is_err());

    // Written as keys Proton carries, and read back the same.
    let text = s.to_text();
    assert!(text.contains("\"fov\": 150"), "{text}");
    let again = Scene::parse(&text).unwrap();
    assert_eq!(again.objects()[1].light, s.objects()[1].light);
    assert_eq!(again.to_text(), text, "a second save changes nothing");
}
