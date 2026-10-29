import Foundation
import ModelCore

/// Materials as layer stacks: a base surface and a few layers over it, each
/// an undo step, written into the scene as the graph Proton reads.
extension ModelWorkspaceModel {
    /// The material the chosen object wears.
    public var selectedMaterial: SceneMaterial? {
        guard let node = selectedNode, !node.material.isEmpty else { return nil }
        return document?.state.materials.first { $0.id == node.material }
    }

    /// A material as a stack, or `nil` for a graph that isn't one.
    public func stack(of material: String) -> SceneStack? {
        document?.state.stacks[material] ?? nil
    }

    /// A new material for the chosen object: a plain grey base, no layers.
    public func newMaterial() {
        guard let node = selectedNode else { return }
        change(.newMaterial(node.id, name: "\(node.name) Material"), label: "New Material")
    }

    /// The chosen object made to wear `material`, or none.
    public func wear(_ material: String) {
        guard let node = selectedNode else { return }
        let name = document?.state.materials.first { $0.id == material }?.name
        change(.wear(node.id, material: material), label: name.map { "Wear \($0)" } ?? "No Material")
    }

    /// A graph the stack can't show, replaced by a stack from its base.
    public func layersFromGraph() {
        guard let material = selectedMaterial else { return }
        change(.setLayers(material: material.id, stack: nil), label: "Layers from the Graph")
    }

    /// Change the chosen object's stack, as one step named `label`; the same
    /// change again within a second joins it.
    public func editStack(_ label: String, _ edit: (inout SceneStack) -> Void) {
        guard let document, let material = selectedMaterial, var stack = stack(of: material.id) else { return }
        let before = stack
        edit(&stack)
        guard stack != before else { return }
        let key = "\(material.id)|\(label)"
        let now = Date()
        let joining = lastLayerEdit.map { $0.key == key && now.timeIntervalSince($0.at) < 1 } ?? false
        lastLayerEdit = (key, now)
        guard document.apply(.setLayers(material: material.id, stack: stack), label: label, joining: joining) != nil else {
            notice = document.refusal
            return
        }
        scheduleSave()
    }

    public func addLayer(_ pattern: LayerPattern) {
        guard let material = selectedMaterial else { return newMaterialThen { $0.addLayer(pattern) } }
        guard let stack = stack(of: material.id) else { return notice = "\(material.name) is a graph the layer stack can’t show: replace it with layers first." }
        guard stack.layers.count < SceneStack.most else { return notice = "A stack takes \(SceneStack.most) layers at most." }
        editStack("Add \(pattern.title) Layer") { $0.layers.append(.starting(pattern)) }
    }

    public func removeLayer(at index: Int) {
        editStack("Remove Layer") { if $0.layers.indices.contains(index) { $0.layers.remove(at: index) } }
    }

    /// Move a layer up the stack (`by` 1) or down (-1).
    public func moveLayer(at index: Int, by step: Int) {
        editStack("Move Layer") { stack in
            let to = index + step
            guard stack.layers.indices.contains(index), stack.layers.indices.contains(to) else { return }
            stack.layers.swapAt(index, to)
        }
    }

    /// With no material yet, make one, then `then`.
    private func newMaterialThen(_ then: (ModelWorkspaceModel) -> Void) {
        newMaterial()
        if selectedMaterial != nil { then(self) }
    }
}
