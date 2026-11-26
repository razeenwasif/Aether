import AppKit
import Foundation
import ModelCore
import simd

/// Edit mode (⇥): the chosen object's mesh, its corners, edges and faces
/// chosen and changed — new in Photon, as Proton's Modeling only placed
/// meshes. The `.obj` is written as it's edited, but only a copy the object
/// owns: one another object shares, one of the primitives Add writes, or one
/// with things Edit mode can't keep (texture coordinates, normals, groups) is
/// copied into `meshes/` first, so a file from Blender is never written over.
extension ModelWorkspaceModel {
    /// Whether the chosen object has a mesh to edit.
    public var canEdit: Bool {
        guard let node = selectedNode else { return false }
        return node.kind == "mesh" && !node.mesh.isEmpty
    }

    public func toggleEdit() {
        editing == nil ? enterEdit() : exitEdit()
    }

    /// The edited object's place in the world.
    var editWorld: simd_float4x4? {
        guard let edit = editing, let document else { return nil }
        return SceneMath.worlds(document.state.objects)[edit.nodeID]
    }

    public func enterEdit() {
        guard editing == nil, let document, let node = selectedNode else { return }
        guard node.kind == "mesh", !node.mesh.isEmpty else {
            return notice = "Only a mesh has corners and faces to edit: choose one, or add a cube."
        }
        saveNow()
        let file = document.folder.appending(path: node.mesh)
        do {
            let edit = try MeshEditSession(nodeID: node.id, url: file)
            let sharer = document.state.objects.first { $0.id != node.id && $0.mesh == node.mesh }
            let primitive = SceneAddition.allCases.first { "meshes/\($0.rawValue).obj" == node.mesh }
            let dropped = edit.dropped
            if sharer != nil || primitive != nil || !dropped.isEmpty {
                let copy = uniqueMesh(named: node.name, in: document)
                try edit.save(as: copy)
                let path = "meshes/\(copy.lastPathComponent)"
                guard document.apply(.setMesh(node.id, path: path), label: "Edit \(node.name)’s Mesh") != nil else {
                    return notice = document.refusal
                }
                notice = if let sharer {
                    "Editing a copy, \(path): \(sharer.name) draws \(node.mesh) too."
                } else if let primitive {
                    "Editing a copy, \(path), so the next \(primitive.rawValue) added is still a plain one."
                } else {
                    "Editing a copy, \(path): \(node.mesh) has \(ListFormatter.localizedString(byJoining: dropped)), which Edit mode can’t keep."
                }
            }
            edit.onStep = { [weak self, weak edit] label in
                guard let self, let edit else { return }
                if let project { try? project.documentStepped(project.path(of: edit.url), label: label) }
                scheduleSave()
            }
            editing = edit
        } catch {
            notice = "Couldn’t edit \(node.mesh): \(SceneDocument.describe(error))"
        }
    }

    /// Back to Object mode: the mesh written, and drawn with its modifiers.
    public func exitEdit() {
        guard let edit = editing else { return }
        saveEdit()
        if let project { project.forget(document: project.path(of: edit.url)) }
        editing = nil
        slideState = nil
        document?.reloadMeshes()
    }

    /// `meshes/<name> mesh.obj`, made unique: "mesh" so a cube's copy isn't
    /// taken for `cube.obj` on a disk that doesn't mind case.
    private func uniqueMesh(named name: String, in document: SceneDocument) -> URL {
        let folder = document.folder.appending(path: "meshes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appending(path: "\(base) mesh.obj")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) mesh \(n).obj")
            n += 1
        }
        return url
    }

    /// Write the mesh being edited, if it has changes.
    func saveEdit() {
        guard let edit = editing, edit.dirty else { return }
        do {
            try edit.save()
            if let project { project.documentSaved(project.path(of: edit.url)) }
        } catch {
            notice = "Couldn’t save \(edit.url.lastPathComponent): \(SceneDocument.describe(error))"
        }
    }

    func editUndo(_ edit: MeshEditSession, redo: Bool) {
        if let project {
            let path = project.path(of: edit.url)
            _ = redo ? project.redo(in: path) { edit.redo() } : project.undo(in: path) { edit.undo() }
        } else {
            _ = redo ? edit.redo() : edit.undo()
        }
        scheduleSave()
    }

    // MARK: Edits

    public func showPart(_ part: EditPart) {
        editing?.show(part)
    }

    public func extrudeChosen() {
        guard let edit = editing, !edit.extrude(by: extrudeDistance) else { return }
        notice = edit.refusal
    }

    public func insetChosen() {
        guard let edit = editing, !edit.inset(by: insetAmount) else { return }
        notice = edit.refusal
    }

    public func bevelChosen() {
        guard let edit = editing, !edit.bevel(by: bevelWidth) else { return }
        notice = edit.refusal
    }

    public func loopCutChosen() {
        guard let edit = editing, !edit.loopCut(at: cutAt) else { return }
        notice = edit.refusal
    }

    public func deleteChosen() {
        guard let edit = editing, !edit.delete() else { return }
        notice = edit.refusal
    }

    // MARK: The face is the handle

    /// A press at `point`: on what's chosen, a drag from it will slide it
    /// along its normal (with `extruding`, the chosen faces are pulled out
    /// first, once the pointer moves). Answers whether it's on what's chosen;
    /// if not, the drag turns the view as usual.
    public func pressToSlide(at point: CGPoint, in size: CGSize, extruding: Bool) -> Bool {
        guard let edit = editing, let world = editWorld else { return false }
        guard edit.isChosen(edit.hit(point, size: size, view: camera.view, world: world)) else { return false }
        let along = edit.chosenDirection
        // A metre along the slide, on screen, from the middle of what's chosen.
        let corners = edit.chosenVertices
        let middle = corners.reduce(SIMD3<Float>()) { $0 + edit.cage.position($1) } / Float(max(corners.count, 1))
        let tip = middle + SIMD3<Float>(Float(along.x), Float(along.y), Float(along.z))
        func world3(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = world * SIMD4(p, 1)
            return SIMD3(q.x, q.y, q.z)
        }
        var perMetre = CGVector(dx: 0, dy: -CGFloat(1 / max(camera.distance * 0.004, 1e-4)))
        if let a = SceneMath.project(world3(middle), view: camera.view, size: size), let b = SceneMath.project(world3(tip), view: camera.view, size: size) {
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            // Pointing nearly at the eye: slide by how far the pointer goes up.
            if hypot(v.dx, v.dy) > 4 { perMetre = v }
        }
        slideState = (point, perMetre, extruding, false)
        return true
    }

    public func dragSlide(to point: CGPoint) {
        guard let edit = editing, var s = slideState else { return }
        let moved = CGVector(dx: point.x - s.last.x, dy: point.y - s.last.y)
        if !s.started {
            guard hypot(moved.dx, moved.dy) > 3 else { return }
            guard edit.beginSlide(extruding: s.extruding) else {
                notice = edit.refusal
                slideState = nil
                return
            }
            s.started = true
        }
        let along = s.perMetre
        let metres = (moved.dx * along.dx + moved.dy * along.dy) / max(along.dx * along.dx + along.dy * along.dy, 1e-6)
        s.last = point
        slideState = s
        edit.slide(by: Double(metres))
    }

    public func endSlide() {
        editing?.endSlide()
        slideState = nil
    }

    // MARK: Keys

    /// Edit mode's keys: 1 2 3 corners, edges, faces · e extrude · i inset ·
    /// b bevel · a everything · ⌫ delete · f frame · ⎋ nothing, then Object
    /// mode.
    func handleEditKey(_ event: NSEvent) -> Bool {
        guard let edit = editing else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (_, "1"): showPart(.vertices)
        case (_, "2"): showPart(.edges)
        case (_, "3"): showPart(.faces)
        case (_, "e"): extrudeChosen()
        case (_, "i"): insetChosen()
        case (_, "b"): bevelChosen()
        case (_, "a"): edit.chooseAll()
        case (_, "f"): frameSelected()
        case (51, _), (117, _): deleteChosen()
        case (53, _): edit.isEmpty ? exitEdit() : edit.chooseNothing()
        default: return false
        }
        return true
    }
}
