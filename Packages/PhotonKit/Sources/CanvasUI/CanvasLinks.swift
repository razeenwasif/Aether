import PhotonGraph
import CanvasCore
import DiffuseBridge
import Foundation

/// The canvas in the project: its steps in the project's one history, layers
/// that follow another workspace's asset, and the canvas as an asset itself
/// (RESEARCH_PLAN.md §6.4a).
extension CanvasWorkspaceModel {
    /// How the project names the canvas open.
    public var documentPath: String? {
        guard let project, let document else { return nil }
        return project.path(of: document.url)
    }

    /// The link a layer follows, if it follows one.
    public func link(of layer: CanvasLayer) -> AssetLink? {
        guard let project, let path = documentPath else { return nil }
        return project.links(in: path).first { Slot.layer(of: $0.slot).map { $0 % CanvasCel.step } == layer.id }
    }

    /// Why a layer that follows an asset can't be drawn on, or `nil`.
    func linkedRefusal(_ layer: CanvasLayer) -> String? {
        guard let link = link(of: layer), let asset = project?.asset(link.asset) else { return nil }
        return "\(layer.name) follows \(asset.name) from \(asset.source.title): unlink it in the inspector to paint on it."
    }

    func listen() {
        listening = project?.onPublish { [weak self] asset, version in self?.published(asset, version) }
    }

    /// A new version: the layers following it take it.
    private func published(_ asset: Asset, _ version: AssetVersion) {
        guard let project, let path = documentPath else { return }
        for link in project.links(in: path) where link.asset == asset.id && link.pinned == nil {
            take(version, of: asset, for: link)
        }
    }

    /// Layers whose asset moved on while the canvas was shut take the
    /// version they should show.
    func catchUp() {
        guard let project, let path = documentPath else { return }
        for link in project.links(in: path) {
            guard let asset = project.asset(link.asset), let version = project.version(for: link), version.number != link.shown else { continue }
            take(version, of: asset, for: link)
        }
    }

    /// A linked layer takes `version`: one step in the canvas, with
    /// `attached` (a version kept, say) made with it.
    func take(_ version: AssetVersion, of asset: Asset, for link: AssetLink, with attached: Transaction? = nil) {
        guard let project, let cel = Slot.layer(of: link.slot) else { return }
        let before = following
        following = Task { [weak self] in
            await before?.value
            let bytes: Data
            do {
                bytes = try await project.pool.data(version.blob)
            } catch {
                self?.notice = "Couldn’t read \(asset.name) v\(version.number): \(Self.describe(error))"
                return
            }
            // Read and tiled off the main thread, at the canvas's size;
            // only the step is made here.
            guard let canvas = self?.document else { return }
            let name = "\(asset.name).png"
            let (width, height) = (canvas.width, canvas.height)
            let prepared: PreparedPicture
            do {
                let preparing = AssetPool.signposter.beginInterval("prepare", "\(bytes.count) bytes for a canvas layer")
                defer { AssetPool.signposter.endInterval("prepare", preparing) }
                prepared = try await Task.detached(priority: .userInitiated) {
                    try CanvasDocument.prepare(bytes, named: name, width: width, height: height)
                }.value
            } catch {
                self?.notice = "Couldn’t read \(asset.name) v\(version.number): \(Self.describe(error))"
                return
            }
            // Gone in the meantime: the canvas shut, or the layer undone.
            guard let self, let document = self.document, document === canvas, project.path(of: document.url) == link.document,
                  document.state.layers.contains(where: { $0.id == cel % CanvasCel.step }) else { return }
            self.stop()
            self.finishTransform()
            // Which version the layer shows goes with the step, so undo
            // takes it back with the pixels.
            let ops = (attached?.ops ?? []) + [.set(link.id, property: "shown", value: .int(version.number))]
            let with = Transaction(ops, origin: .canvas, label: attached?.label ?? "Take v\(version.number)", document: link.document)
            self.attaching = { (_: CanvasDocument.Applied) in with }
            let taking = AssetPool.signposter.beginInterval("take", "a prepared picture into a canvas layer")
            let put = document.putPrepared(prepared, into: cel, label: "Update \(asset.name) to v\(version.number)")
            AssetPool.signposter.endInterval("take", taking)
            if put == nil {
                self.notice = document.refusal
            }
            // The picture was the same: no step to go with, so on its own,
            // an undo step only when it keeps a version.
            if self.attaching != nil {
                self.attaching = nil
                var alone = with
                alone.undoable = attached != nil
                do { try project.apply(alone) } catch { self.notice = error.localizedDescription }
            }
        }
    }

    /// A linked layer behind its asset's newest version (undo put an older
    /// one back) takes the newest again.
    public func takeNewest(_ link: AssetLink) {
        guard let project, let asset = project.asset(link.asset), let newest = asset.newest else { return }
        take(newest, of: asset, for: link)
    }

    /// Keep a version of a linked layer's asset, or follow the newest again
    /// with `nil`: the layer shows it at once, one step.
    public func keep(_ number: Int?, for link: AssetLink) {
        guard let project, let asset = project.asset(link.asset), link.pinned != number,
              let version = number.map({ n in asset.versions.first { $0.number == n } }) ?? asset.newest else { return }
        let label = number.map { "Keep Version \($0)" } ?? "Follow the Newest"
        take(version, of: asset, for: link, with: Transaction([.set(link.id, property: "pinned", value: number.map(PropertyValue.int))], origin: .canvas, label: label, document: link.document))
    }

    /// The link taken away: the layer keeps what it shows, to paint on.
    public func unlink(_ link: AssetLink) {
        do { try project?.unlink(link) } catch { notice = error.localizedDescription }
    }

    /// An asset brought in as a layer that follows it, over the one drawn
    /// on: one step, the layer and its link together.
    public func place(_ asset: Asset) {
        guard let project, let document, let path = documentPath else {
            notice = "Open a canvas to place \(asset.name) in."
            return
        }
        guard asset.document != path else {
            notice = "A canvas can’t follow itself."
            return
        }
        guard let version = asset.newest else {
            notice = "\(asset.name) has no version yet."
            return
        }
        let frame = self.frame
        following = Task { [weak self] in
            guard let bytes = try? await project.pool.data(version.blob) else {
                self?.notice = "Couldn’t read \(asset.name) v\(version.number)."
                return
            }
            guard let self, self.document === document else { return }
            self.attaching = { (applied: CanvasDocument.Applied) in
                applied.made.map { made in
                    Transaction([project.linkOp(asset.id, into: path, slot: Slot.layer(CanvasCel.id(layer: made, frame: frame)), by: .canvas)], origin: .canvas, label: "Link \(asset.name)", document: path)
                }
            }
            self.bringIn(bytes, named: asset.name)
            self.attaching = nil
        }
    }

    /// A step in the canvas's own history, and the project change made
    /// with it, onto the project's history.
    func stepped(_ label: String, _ applied: CanvasDocument.Applied, in doc: CanvasDocument?) {
        let tx = attaching?(applied)
        attaching = nil
        guard let project, let doc else { return }
        do {
            try project.documentStepped(project.path(of: doc.url), label: label, with: tx)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// The canvas open let go: its history goes with it, so its steps leave
    /// the project's; and with changes not saved, the links made with them
    /// go too, or one would fasten on to the next layer given that id.
    func letGo() {
        guard let project, let document, let path = documentPath else { return }
        if document.state.dirty { project.discard(document: path) } else { project.forget(document: path) }
    }

    /// Saved, the canvas is published when something uses it.
    func publishIfUsed() {
        leaveMade()
        guard let project, let document, let path = documentPath, let asset = project.asset(madeBy: path), let png = try? document.png() else { return }
        let (width, height) = (document.width, document.height)
        publishing = Task { [weak self] in
            do {
                let blob = try await project.pool.store(png)
                try project.publish(asset.id, blob: blob, width: width, height: height, note: "saved")
            } catch {
                self?.notice = "Couldn’t publish \(asset.name): \(error.localizedDescription)"
            }
        }
    }

    /// The canvas at `url` as an asset with a version, for another workspace
    /// to use: the canvas open as it is now, any other as saved.
    public func asset(ofCanvasAt url: URL) async throws -> Asset {
        guard let project else { throw CocoaError(.featureUnsupported) }
        let path = project.path(of: url)
        let open = document.flatMap { project.path(of: $0.url) == path ? $0 : nil }
        if open != nil { leaveMade() }
        let doc = try open ?? CanvasDocument.open(url)
        let png = try doc.png()
        let asset = try project.asset(madeBy: path, named: doc.name, in: .canvas)
        let blob = try await project.pool.store(png)
        try project.publish(asset.id, blob: blob, width: doc.width, height: doc.height, note: doc.state.dirty ? "as open" : "saved")
        return project.asset(asset.id) ?? asset
    }

    /// The canvas open made an asset, as it is now, for other canvases and
    /// flows to follow; each save after publishes it again.
    public func publishAsAsset() {
        guard let document else { return }
        publishing = Task { [weak self] in
            do {
                let asset = try await self?.asset(ofCanvasAt: document.url)
                if let asset { self?.notice = "\(asset.name) is an asset: place it in another canvas, or use it in a flow’s Load Image. Saving publishes it again." }
            } catch {
                self?.notice = "Couldn’t publish \(document.name): \(error.localizedDescription)"
            }
        }
    }

    /// Who uses the canvas open, for the inspector.
    public var usedBy: [AssetLink] {
        guard let project, let path = documentPath, let asset = project.asset(madeBy: path) else { return [] }
        return project.links(to: asset.id)
    }
}
