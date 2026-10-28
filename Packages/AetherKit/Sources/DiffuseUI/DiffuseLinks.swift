import AetherGraph
import DiffuseCore
import Foundation

/// The flow in the project: its steps in the project's one history, its
/// pictures published as an asset, and Load Images whose picture follows
/// another workspace's asset (RESEARCH_PLAN.md §6.4a).
extension DiffuseWorkspaceModel {
    /// How the project names the flow open.
    public var flowPath: String? {
        guard let project, let editor else { return nil }
        return project.path(of: editor.url)
    }

    /// The link a Load Image's picture follows, if it follows one.
    public func link(node: String, field: String) -> AssetLink? {
        guard let project, let path = flowPath else { return nil }
        return project.link(in: path, slot: Slot.input(node: node, field: field))
    }

    /// Read the project's canvases again, off the main actor (§7a).
    public func refreshProjectCanvases() async {
        guard let folder = project?.folder?.appending(path: "Canvases", directoryHint: .isDirectory) else { return }
        projectCanvases = await Task.detached {
            let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return found.filter { $0.pathExtension == "canvas" }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
    }

    func editorChanged(from old: FlowEditor?) {
        guard old !== editor else { return }
        editedSinceOpen = false
        // Its history went with it, so its steps leave the project's; and
        // with changes not saved, the links made with them go too.
        if let old, let project {
            let path = project.path(of: old.url)
            if old.isDirty { project.discard(document: path) } else { project.forget(document: path) }
        }
        editor?.onStep = { [weak self, weak editor] label, added in self?.stepped(label, added, in: editor) }
    }

    func stepped(_ label: String, _ added: [String], in editor: FlowEditor?) {
        editedSinceOpen = true
        let tx = attaching?(added)
        attaching = nil
        guard let project, let editor else { return }
        do {
            try project.documentStepped(project.path(of: editor.url), label: label, with: tx)
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Undo

    /// Undo the flow's newest step, its own or a project step made in it.
    public func undo() {
        guard let editor else { return }
        if let project { project.undo(in: project.path(of: editor.url)) { editor.undo() } } else { editor.undo() }
        syncInputs()
    }

    public func redo() {
        guard let editor else { return }
        if let project { project.redo(in: project.path(of: editor.url)) { editor.redo() } } else { editor.redo() }
        syncInputs()
    }

    public var undoLabel: String? { project.flatMap { p in flowPath.flatMap { p.undoLabel(in: $0) } } }
    public var redoLabel: String? { project.flatMap { p in flowPath.flatMap { p.redoLabel(in: $0) } } }

    // MARK: Publishing

    func listen() {
        listening = project?.onPublish { [weak self] asset, version in self?.published(asset, version) }
    }

    /// A run finished: its first picture kept for the Gallery is the flow's
    /// newest version, when something uses the flow's pictures. A sealed
    /// flow's aren't, as the project keeps versions plain.
    func finished(_ item: RunItem) {
        guard let project, let flow = item.flow, let asset = project.asset(madeBy: project.path(of: flow)),
              let output = item.outputs.first(where: { $0.kept }), let file = output.file,
              !file.lastPathComponent.hasSuffix(SealedFiles.suffix) else { return }
        linking = Task { [weak self] in
            do {
                let blob = try await project.pool.store(output.data)
                try project.publish(asset.id, blob: blob, width: output.width, height: output.height, note: file.lastPathComponent)
            } catch {
                self?.notice = "Couldn’t publish \(asset.name): \(error.localizedDescription)"
            }
        }
    }

    /// Send to Canvas, live: the flow that made the picture becomes an asset
    /// and the picture its newest version, for the canvas's layer to follow.
    /// `nil` when it can't be: no project, or the flow isn't at hand.
    func publishForCanvas(_ picture: GalleryPicture, bytes: Data) async -> Asset? {
        guard let project, !picture.isSealed, let flow = flowFile(for: picture), !SealedFiles.isSealed(flow) else { return nil }
        do {
            let asset = try project.asset(madeBy: project.path(of: flow), named: picture.flow, in: .diffuse)
            let blob = try await project.pool.store(bytes)
            let size = AssetPool.size(of: bytes) ?? (0, 0)
            try project.publish(asset.id, blob: blob, width: size.width, height: size.height, note: picture.name)
            return project.asset(asset.id)
        } catch {
            notice = "Sent as a copy, not live: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Load Images that follow an asset

    /// A new version: every Load Image following it, open or not, has its
    /// picture written again.
    private func published(_ asset: Asset, _ version: AssetVersion) {
        guard let project else { return }
        for link in project.links(to: asset.id) where link.consumer == .diffuse && link.pinned == nil {
            write(version, of: asset, for: link)
        }
    }

    /// Pictures the history moved past (a version kept, undone) written as
    /// the links now say.
    func syncInputs() {
        guard let project, let path = flowPath else { return }
        for link in project.links(in: path) {
            guard let asset = project.asset(link.asset), let version = project.version(for: link), version.number != link.shown else { continue }
            write(version, of: asset, for: link)
        }
    }

    /// The picture file a Load Image following `asset` names, in its flow's
    /// folder.
    static func inputName(for asset: Asset) -> String {
        let clean = asset.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "inputs/\(clean.isEmpty ? "Linked" : clean).png"
    }

    private func write(_ version: AssetVersion, of asset: Asset, for link: AssetLink) {
        guard let project else { return }
        let file = FlowInputs.file(Self.inputName(for: asset), flow: project.url(of: link.document))
        let before = linking
        linking = Task { [weak self] in
            await before?.value
            do {
                let data = try await project.pool.data(version.blob)
                try await Task.detached {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                }.value
                Thumbnails.shared.forget(file)
                self?.pictureRevision += 1
                project.took(version.number, for: link)
            } catch {
                self?.notice = "Couldn’t write \(asset.name) v\(version.number) into the flow: \(error.localizedDescription)"
            }
        }
    }

    /// A canvas as a Load Image's picture, live: the canvas published as it
    /// is, and from then on each time it's saved.
    public func useCanvas(at url: URL, node: String? = nil, field: String? = nil) {
        guard let canvasAsset else { return }
        let target = node.map { PictureTarget(node: $0, field: field ?? "image") } ?? pickingInput
        pickingInput = nil
        linking = Task { [weak self] in
            do {
                let asset = try await canvasAsset(url)
                await self?.use(asset, node: target?.node, field: target?.field)
            } catch {
                self?.notice = "Couldn’t use \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// An asset as a Load Image's picture — the one given, the one selected,
    /// the first, or a new one — following its newest version: one step, the
    /// picture and its link together.
    public func use(_ asset: Asset, node: String? = nil, field: String? = nil) async {
        guard let project, let editor else {
            notice = "Open a flow to use \(asset.name) in it."
            return
        }
        guard !editor.isSealed else {
            notice = "A sealed flow can’t take a live picture: its inputs would be written plain."
            return
        }
        guard let version = asset.newest else {
            notice = "\(asset.name) has no version yet."
            return
        }
        let name = Self.inputName(for: asset)
        let file = FlowInputs.file(name, flow: editor.url)
        do {
            let data = try await project.pool.data(version.blob)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            Thumbnails.shared.forget(file)
            pictureRevision += 1
        } catch {
            notice = "Couldn’t write \(asset.name) into the flow: \(error.localizedDescription)"
            return
        }
        guard self.editor === editor else { return }
        let path = project.path(of: editor.url)
        let known = editor.pictureTarget(node, field: field)
        let link = { (added: [String]) -> AetherGraph.Transaction? in
            guard let slot = known.map({ Slot.input(node: $0.node, field: $0.field) }) ?? added.first.map({ Slot.input(node: $0, field: "image") }) else { return nil }
            var ops: [Op] = project.link(in: path, slot: slot).map { [.remove($0.id)] } ?? []
            ops.append(project.linkOp(asset.id, into: path, slot: slot, by: .diffuse))
            return AetherGraph.Transaction(ops, origin: .diffuse, label: "Link \(asset.name)", document: path)
        }
        attaching = link
        if editor.usePicture(name, node: known?.node, field: known?.field) == nil { notice = editor.refusal }
        // The node had this picture already: the link on its own.
        if attaching != nil {
            attaching = nil
            if let tx = link([]) {
                do { try project.apply(tx) } catch { notice = error.localizedDescription }
            }
        }
        show(.graph)
    }

    /// Keep a version of a Load Image's asset, or follow the newest again.
    public func keep(_ number: Int?, for link: AssetLink) {
        guard let project else { return }
        do {
            try project.pin(link, to: number)
        } catch {
            notice = error.localizedDescription
        }
        syncInputs()
    }

    /// The link taken away: the picture stays, no longer updated.
    public func unlink(_ link: AssetLink) {
        do { try project?.unlink(link) } catch { notice = error.localizedDescription }
    }
}
