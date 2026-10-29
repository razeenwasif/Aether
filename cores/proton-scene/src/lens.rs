//! Added in Aether: a camera's field of view, and a light's kind, colour and
//! strength, for Model's Render.
//!
//! Proton's scenes placed cameras and lights as transforms and nothing more,
//! which was all its viewport drew them as. Render looks through a camera
//! and lights by the scene's lights, so each needs a few settings. They are
//! keys on the object (`"fov"` on a camera, a `"light"` block on a light),
//! so Proton, which carries keys it doesn't know, keeps them, and a scene
//! without them reads as it always did: a 50° camera, a white point light.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::write;

/// A camera's field of view when the file doesn't say: the viewport's.
pub const FOV: f64 = 50.0;

/// A light's settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Light {
    /// `point`, shining every way from where it is, fading with the square
    /// of the distance; or `sun`, shining down its own −Z from far away.
    pub kind: String,
    /// Linear RGB, 0 to 1.
    pub color: [f64; 3],
    /// A sun's brightness, or a point's at a metre.
    pub strength: f64,
}

impl Default for Light {
    fn default() -> Light {
        Light { kind: "point".into(), color: [1.0, 1.0, 1.0], strength: 20.0 }
    }
}

impl Light {
    pub const KINDS: &'static [&'static str] = &["point", "sun"];

    /// The light the object's block describes, its gaps filled in.
    pub(crate) fn read(one: &Map<String, Value>) -> Light {
        let mut light = Light::default();
        if let Some(block) = one.get("light").and_then(Value::as_object) {
            if let Some(kind) = block.get("kind").and_then(Value::as_str) {
                light.kind = kind.to_string();
            }
            if let Some(c) = block.get("color").and_then(Value::as_array).filter(|c| c.len() == 3) {
                light.color = [0, 1, 2].map(|i| c[i].as_f64().unwrap_or(1.0));
            }
            if let Some(s) = block.get("strength").and_then(Value::as_f64) {
                light.strength = s;
            }
        }
        light
    }
}

/// A camera's field of view, in degrees, top to bottom.
pub(crate) fn fov_of(one: &Map<String, Value>) -> f64 {
    one.get("fov").and_then(Value::as_f64).unwrap_or(FOV)
}

impl crate::Scene {
    /// A camera's field of view, in degrees top to bottom, 5 to 150.
    pub fn set_fov(&mut self, id: &str, degrees: f64) -> Result<bool, String> {
        if !degrees.is_finite() {
            return Err("a field of view is a number of degrees".into());
        }
        let one = self.find_mut(id)?;
        if one.get("kind").and_then(Value::as_str) != Some("camera") {
            return Err("only a camera has a field of view".into());
        }
        let now = json!(degrees.clamp(5.0, 150.0));
        if write::to_text(one.get("fov").unwrap_or(&Value::Null)) == write::to_text(&now) {
            return Ok(false);
        }
        one.insert("fov".into(), now);
        Ok(true)
    }

    /// A light's kind, colour and strength.
    pub fn set_light(&mut self, id: &str, light: &Light) -> Result<bool, String> {
        if !Light::KINDS.contains(&light.kind.as_str()) {
            return Err(format!("a light is a point or a sun, not {:?}", light.kind));
        }
        if !light.strength.is_finite() || light.color.iter().any(|c| !c.is_finite()) {
            return Err("a light's colour and strength are numbers".into());
        }
        let one = self.find_mut(id)?;
        if one.get("kind").and_then(Value::as_str) != Some("light") {
            return Err("only a light has light settings".into());
        }
        let now = json!({
            "kind": light.kind,
            "color": light.color.map(|c| c.clamp(0.0, 1.0)),
            "strength": light.strength.clamp(0.0, 100_000.0),
        });
        if write::to_text(one.get("light").unwrap_or(&Value::Null)) == write::to_text(&now) {
            return Ok(false);
        }
        one.insert("light".into(), now);
        Ok(true)
    }
}
