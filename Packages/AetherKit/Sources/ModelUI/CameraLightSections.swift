import AetherDesign
import ModelCore
import SwiftUI

/// A camera's settings: its field of view, taking the view's place, and
/// being what a render looks through.
struct CameraSection: View {
    @Bindable var model: ModelWorkspaceModel
    let node: SceneNode

    var body: some View {
        PanelSection("Camera") {
            HStack(spacing: 6) {
                Text("Field of view").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 84, alignment: .leading)
                DecimalField(value: node.fov) { model.setFov($0) }.frame(width: 64)
                Text("° top to bottom").font(.aeSmall).foregroundStyle(Color.ink2)
            }
            HStack(spacing: 8) {
                Button("Camera from the View", action: model.cameraFromView)
                    .controlSize(.small)
                    .help("Put the camera where the view is, looking where it looks: frame the view, then take it")
                Toggle("Render through it", isOn: Binding(get: { model.renderCamera == node.id }, set: { model.renderCamera = $0 ? node.id : nil }))
                    .toggleStyle(.checkbox)
                    .font(.aeSmall)
            }
            Text("It looks down its own −Z, as its outline in the view shows.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A light's settings: a point or a sun, its colour and its strength.
struct LightSection: View {
    let model: ModelWorkspaceModel
    let node: SceneNode
    let light: SceneLight

    var body: some View {
        PanelSection("Light") {
            Picker("Kind", selection: Binding(get: { light.kind }, set: { model.setLightKind($0) })) {
                Text("Point").tag("point")
                Text("Sun").tag("sun")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("A point shines every way and fades with distance; a sun shines down its own −Z, the same everywhere")
            HStack(spacing: 6) {
                Text("Colour").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
                ColorPicker("Colour", selection: Binding(get: { LinearColor.color(light.color) }, set: { picked in
                    let rgb = LinearColor.rgb(picked)
                    model.editLight("Light Colour") { $0.color = rgb }
                }), supportsOpacity: false)
                .labelsHidden()
                Text(LinearColor.hex(light.color)).font(.aeMono).foregroundStyle(Color.ink2)
            }
            HStack(spacing: 6) {
                Text("Strength").font(.aeSmall).foregroundStyle(Color.ink2).frame(width: 62, alignment: .leading)
                DecimalField(value: light.strength) { v in model.editLight("Light Strength") { $0.strength = max(0, v) } }.frame(width: 64)
                Text(light.kind == "sun" ? "everywhere" : "at a metre").font(.aeSmall).foregroundStyle(Color.ink2)
            }
            Text(light.kind == "sun" ? "A sun of 3 is about the view’s own light." : "A point of 20 lights a thing two metres off about as the view’s own light does.")
                .font(.aeSmall).foregroundStyle(Color.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
