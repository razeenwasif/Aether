import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PhotonGraph
@testable import DesignCore
@testable import DesignUI

/// Text a known size: each letter half the font's size wide, lines as tall
/// as the line height, wrapped by letters.
private struct Blocks: DesignMeasuring {
    func size(of text: String, font: DesignFont, width: CGFloat?) -> CGSize {
        let line = font.lineHeight ?? font.size * 1.2
        let natural = CGFloat(text.count) * font.size / 2
        guard let width, natural > width else { return CGSize(width: natural, height: line) }
        let perLine = max(1, floor(width / (font.size / 2)))
        return CGSize(width: width, height: ceil(CGFloat(text.count) / perLine) * line)
    }
}

private func page(_ json: String) throws -> DesignPage {
    try JSONDecoder().decode(DesignPage.self, from: Data(json.utf8))
}

private let none = DesignResolver(tokens: [])

struct DesignThemeTests {
    @Test func coloursAreReadAsCSSWritesThem() throws {
        let gold = try #require(DesignResolver.color(css: "#f2b84b"))
        #expect(DesignResolver.hex(gold) == "#f2b84b")
        #expect(DesignResolver.hex(try #require(DesignResolver.color(css: "#fff"))) == "#ffffff")
        #expect(DesignResolver.hex(try #require(DesignResolver.color(css: "rgba(255, 0, 0, .5)"))) == "#ff000080")
        #expect(DesignResolver.hex(try #require(DesignResolver.color(css: "rgb(0 128 255 / 50%)"))) == "#0080ff80")
        #expect(DesignResolver.color(css: "oklch(62% .2 250)") == nil, "said not drawn, rather than drawn wrong")
        #expect(DesignResolver.color(css: "#ggg") == nil)
    }

    @Test func fontsAreReadFromTheShorthand() throws {
        let display = try #require(DesignFont(css: "700 56px/1.05 \"Inter Display\", system-ui"))
        #expect(display.weight == 700 && display.size == 56 && display.family == "Inter Display")
        #expect(abs((display.lineHeight ?? 0) - 58.8) < 0.001)
        let label = try #require(DesignFont(css: "italic bold 1rem/24px serif"))
        #expect(label.italic && label.weight == 700 && label.size == 16 && label.lineHeight == 24 && label.family == "serif")
        #expect(DesignFont(css: "system-ui") == nil, "a font needs a size")
    }

    @Test func tokensResolveThroughEachOtherAndRootComesFirst() {
        let tokens = [
            DesignToken(name: "--gold", value: "#f2b84b", scope: ":root", line: 2),
            DesignToken(name: "--accent", value: "var(--gold)", scope: ":root", line: 3),
            DesignToken(name: "--accent", value: "#89b4fa", scope: "@media (prefers-color-scheme: dark) > :root", line: 7),
            DesignToken(name: "--gap", value: "1.5rem", scope: ":root", line: 4),
            DesignToken(name: "--loop", value: "var(--loop)", scope: ":root", line: 5),
        ]
        let r = DesignResolver(tokens: tokens)
        #expect(r.resolve("--accent") == "#f2b84b")
        #expect(r.length(.text("--gap")) == 24)
        #expect(r.length(.num(12)) == 12)
        #expect(r.resolve("--loop") == nil, "a loop resolves to nothing, and ends")
        #expect(r.resolve("var(--missing, 4px)") == "4px")
        #expect(r.kind(of: tokens[1]) == .color && r.kind(of: tokens[3]) == .length)
    }
}

struct DesignLayoutTests {
    @Test func aColumnStacksItsChildrenInsideItsPadding() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 400}], "layers": [
          {"id": "root", "children": ["a", "b"], "layout": {"gap": 10, "padH": 20, "padV": 30}},
          {"id": "a", "kind": "rect", "h": 50},
          {"id": "b", "kind": "text", "text": "hello", "style": {"font": "20px/24px system-ui"}}
        ]}
        """)
        let laid = DesignLayout.lay(p, width: 400, resolver: none, measure: Blocks())
        #expect(laid.frames["a"] == CGRect(x: 20, y: 30, width: 360, height: 50), "a shape fills the column")
        #expect(laid.frames["b"] == CGRect(x: 20, y: 90, width: 50, height: 24), "text hugs")
        #expect(laid.height - 144 == 0, "\(laid.height - 144)")
        #expect(laid.order == ["root", "a", "b"])
        #expect(laid.hit(CGPoint(x: 30, y: 100)) == "b")
        #expect(laid.hit(CGPoint(x: 5, y: 5)) == "root")
    }

    @Test func aRowSharesWhatsLeftAmongItsFills() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 300}], "layers": [
          {"id": "root", "children": ["a", "b", "c"], "layout": {"direction": "row", "gap": 10, "align": "center"}},
          {"id": "a", "kind": "rect", "w": 80, "h": 40},
          {"id": "b", "kind": "rect", "h": 20},
          {"id": "c", "kind": "rect", "h": "fill"}
        ]}
        """)
        let laid = DesignLayout.lay(p, width: 300, resolver: none, measure: Blocks())
        #expect(laid.frames["a"] == CGRect(x: 0, y: 0, width: 80, height: 40))
        #expect(laid.frames["b"] == CGRect(x: 90, y: 10, width: 100, height: 20), "fill shares, centred across")
        #expect(laid.frames["c"] == CGRect(x: 200, y: 0, width: 100, height: 40), "a fill height is the line's")
        #expect(laid.height == 40)
    }

    @Test func aRowThatWrapsMovesWhatDoesntFitToTheNextLine() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 800}], "layers": [
          {"id": "root", "children": ["a", "b", "c"], "layout": {"direction": "row", "gap": 20, "wrap": true}},
          {"id": "a", "kind": "rect", "minW": 240, "h": 50},
          {"id": "b", "kind": "rect", "minW": 240, "h": 50},
          {"id": "c", "kind": "rect", "minW": 240, "h": 50}
        ]}
        """)
        let wide = DesignLayout.lay(p, width: 800, resolver: none, measure: Blocks())
        #expect(wide.frames["c"]?.minY == 0, "three fit at 800")
        #expect(abs((wide.frames["a"]?.width ?? 0) - 760.0 / 3) < 0.001)
        let narrow = DesignLayout.lay(p, width: 500, resolver: none, measure: Blocks())
        #expect(narrow.frames["b"]?.minY == 0 && narrow.frames["c"]?.minY == 70, "two, then one")
        #expect(narrow.frames["c"]?.width == 500, "alone on its line, it fills it")
        #expect(narrow.height == 120)
    }

    @Test func justifyAndAlignPlaceChildrenInTheSpareRoom() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 300}], "layers": [
          {"id": "root", "children": ["a", "b"], "h": 100, "layout": {"direction": "row", "justify": "between", "align": "end"}},
          {"id": "a", "kind": "rect", "w": 50, "h": 20},
          {"id": "b", "kind": "rect", "w": 50, "h": 40}
        ]}
        """)
        let laid = DesignLayout.lay(p, width: 300, resolver: none, measure: Blocks())
        #expect(laid.frames["a"] == CGRect(x: 0, y: 80, width: 50, height: 20))
        #expect(laid.frames["b"] == CGRect(x: 250, y: 60, width: 50, height: 40))
    }

    @Test func textWrapsToTheColumnAndALoopIsDrawnOnce() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 100}], "layers": [
          {"id": "root", "children": ["t", "root"]},
          {"id": "t", "kind": "text", "text": "twenty-five letters long.", "style": {"font": "10px/12px system-ui"}}
        ]}
        """)
        let laid = DesignLayout.lay(p, width: 100, resolver: none, measure: Blocks())
        #expect(laid.frames["t"] == CGRect(x: 0, y: 0, width: 100, height: 24), "20 letters a line, two lines")
        #expect(laid.order == ["root", "t"])
    }
}

@MainActor
struct DesignWorkspaceTests {
    private func opened() throws -> DesignWorkspaceModel {
        let designs = FileManager.default.temporaryDirectory.appending(path: "photon-design-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = DesignWorkspaceModel(folder: designs)
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return model
    }

    @Test func aNewDesignOpensOnItsPageWithItsTokens() throws {
        let model = try opened()
        let page = try #require(model.page)
        #expect(page.id == "home" && page.breakpoints.map(\.width) == [1280, 390])
        #expect(model.document?.tokens.contains { $0.name == "--color-lantern-500" } == true)
        #expect(model.document?.unsaved.isEmpty == true && model.document?.view.problems.isEmpty == true)
        #expect(model.designs.map(\.name) == ["Lumen"])
        // Laid out as the board has it: three cards in a row on a desktop,
        // one above another on a phone.
        let drawn = try #require(model.document?.expanded["home"])
        let desktop = DesignLayout.lay(drawn.at("desktop"), width: 1280, resolver: model.resolver)
        let phone = DesignLayout.lay(drawn.at("mobile"), width: 390, resolver: model.resolver)
        let cards = ["lantern", "painted", "remembers"]
        #expect(Set(cards.compactMap { desktop.frames[$0]?.minY }).count == 1)
        #expect(Set(cards.compactMap { phone.frames[$0]?.minY }).count == 3)
        for id in drawn.layers.map(\.id) {
            #expect((phone.frames[id]?.maxX ?? 0) <= 390.5, "\(id) stays on the phone")
        }
        let wishlist = try #require(desktop.frames["wishlist"])
        #expect(wishlist.width > 60 && wishlist.width < 200, "the button hugs its label")
        #expect(desktop.frames["wishlist.label"].map { wishlist.contains($0) } == true)
    }

    @Test func eachEditIsOneStepAndUndoWalksPagesAndTheThemeInOrder() throws {
        let model = try opened()
        model.setText("title", "Carry the light.")
        let token = try #require(model.document?.tokens.first { $0.name == "--color-lantern-500" })
        model.setToken(token, to: "#ffcc66")
        model.rename("title", to: "Headline")
        #expect(model.undoLabel == "Rename Title")
        #expect(model.page?.layer("title")?.label == "Headline")
        model.undo()
        #expect(model.undoLabel == "Set --color-lantern-500")
        model.undo()
        #expect(model.document?.tokens.first { $0.name == "--color-lantern-500" }?.value == "#f2b84b")
        #expect(model.page?.layer("title")?.text == "Carry the light.", "the page's step is still there")
        model.undo()
        #expect(model.page?.layer("title")?.text == "Carry the light through the Hollow Grove.")
        #expect(model.document?.unsaved.isEmpty == true)
        model.redo()
        model.redo()
        #expect(model.redoLabel == "Rename Title")
        #expect(model.document?.unsaved.sorted() == ["pages/home.page.json", "theme.css"])
    }

    @Test func aSchemeIsDrawnAsABrowserWouldAndGivenValues() throws {
        let model = try opened()
        #expect(model.schemes == ["light"], "the starter's paper")
        #expect(model.resolver.resolve("--color-ground") == "#0f1412")
        model.scheme = "light"
        #expect(model.resolver.resolve("--color-ground") == "#f6f1e4")
        #expect(model.resolver.resolve("--color-lantern-500") == "#9a5b06", "deep enough to read on paper")
        #expect(model.resolver.resolve("--color-surface") != "#18201c" && model.resolver.resolve("--space-8") == "32px", "unsaid by the scheme: :root's")
        let lantern = try #require(model.document?.tokens.first { $0.name == "--color-lantern-500" && $0.scope == ":root" })
        model.addToken(lantern, scheme: "dark", value: "#ffd27a")
        #expect(model.schemes == ["light", "dark"] && model.undoLabel == "Dark --color-lantern-500")
        model.scheme = "dark"
        #expect(model.resolver.resolve("--color-lantern-500") == "#ffd27a" && model.resolver.resolve("--color-ground") == "#0f1412")
        let radius = try #require(model.document?.tokens.first { $0.name == "--radius-md" })
        model.addToken(radius, scheme: "light")
        #expect(model.document?.tokens.contains { $0.name == "--radius-md" && $0.scope == DesignResolver.scope(of: "light") && $0.value == "12px" } == true, "its own value to start with")
        model.undo()
        model.undo()
        #expect(model.schemes == ["light"] && model.document?.unsaved.isEmpty == true)
    }

    @Test func aColourDraggedThroughManyValuesIsOneStep() throws {
        let model = try opened()
        let token = try #require(model.document?.tokens.first { $0.name == "--color-ink" })
        for value in ["#eeeeee", "#dddddd", "#cccccc"] {
            let now = try #require(model.document?.tokens.first { $0.name == "--color-ink" })
            model.setToken(now, to: value, coalescing: true)
        }
        #expect(model.document?.tokens.first { $0.name == token.name }?.value == "#cccccc")
        model.undo()
        #expect(model.document?.tokens.first { $0.name == token.name }?.value == token.value)
        #expect(model.undoLabel == nil, "one step, from the first value to the last")
    }

    @Test func layersAreAddedMovedFramedAndRemovedWhole() throws {
        let model = try opened()
        model.selection = "hero"
        model.add(.text)
        let id = try #require(model.selection)
        #expect(model.page?.parent(of: id)?.id == "hero" && model.page?.layer("hero")?.children.last == id)
        #expect(model.undoLabel == "Add Text")
        model.moveSelected(by: -1)
        #expect(model.page?.layer("hero")?.children.suffix(2) == [id, "availability"])
        model.selection = "actions"
        model.wrapSelected()
        let frame = try #require(model.selection)
        #expect(model.page?.layer(frame)?.children == ["actions"] && model.page?.parent(of: frame)?.id == "hero")
        model.selection = "features"
        model.removeSelected()
        #expect(model.page?.layer("features") == nil && model.page?.layer("lantern-title") == nil, "the cards went with it")
        #expect(model.selection == "page")
        model.undo()
        #expect(model.page?.layer("lantern-title") != nil, "and came back in one step")
        model.selection = "page"
        model.removeSelected()
        #expect(model.page?.layer("page") != nil, "the page's own frame stays")
    }

    @Test func styleAndLayoutTakeTokensOrValuesAndARefusalSaysWhy() throws {
        let model = try opened()
        model.setLayout("hero", "gap", to: DesignVal.text("--space-12").json)
        model.setStyle("hero", "fill", to: "#202020")
        model.setSize("wishlist", width: true, to: .num(220))
        let hero = try #require(model.page?.layer("hero"))
        #expect(hero.layout.gap == .text("--space-12") && hero.style.fill == "#202020")
        #expect(model.page?.layer("wishlist")?.width == .num(220))
        model.setStyle("hero", "fill", to: nil)
        #expect(model.page?.layer("hero")?.style.fill == nil)
        model.setSize("title", width: true, to: .text("wide"))
        #expect(model.notice?.contains("hug, fill or a number") == true)
        #expect(model.page?.layer("title")?.width == .fill)
    }

    @Test func savingWritesTheFilesAndClosingWaitsForIt() throws {
        let model = try opened()
        let url = try #require(model.document?.url)
        model.setText("logo", "Lumen")
        model.close()
        #expect(model.document != nil && model.notice?.contains("unsaved") == true)
        model.saveNow()
        #expect(model.document?.unsaved.isEmpty == true)
        let text = try String(contentsOf: url.appending(path: "pages/home.page.json"), encoding: .utf8)
        #expect(text.contains("\"text\": \"Lumen\""))
        model.close()
        #expect(model.document == nil)
        model.open(url)
        #expect(model.page?.layer("logo")?.text == "Lumen")
    }

    @Test func previewWritesThePageAsItIsBesideItsTheme() throws {
        DesignWorkspaceModel.previewsQuietly = true
        let model = try opened()
        let token = try #require(model.document?.tokens.first { $0.name == "--color-lantern-500" })
        model.setToken(token, to: "#ffcc66")
        let file = try #require(model.preview())
        let html = try String(contentsOf: file, encoding: .utf8)
        #expect(html.contains("<link rel=\"stylesheet\" href=\"theme.css\">") && html.contains("var(--color-lantern-500)"))
        let theme = try String(contentsOf: file.deletingLastPathComponent().appending(path: "theme.css"), encoding: .utf8)
        #expect(theme.contains("--color-lantern-500: #ffcc66"), "unsaved, and previewed")
        model.selection = "wishlist"
        let code = try #require(model.code)
        #expect(code.html.hasPrefix("<a class=\"wishlist button button--variant-primary\">") && code.css.contains("border-radius: var(--radius-full);"))
    }
}

struct DesignBreakpointTests {
    @Test func aNarrowerBreakpointSaysWhatDiffersAndTheNarrowerStillInherit() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "phone", "width": 390}, {"id": "desk", "width": 1280}, {"id": "tab", "width": 768}], "layers": [
          {"id": "root", "children": ["a", "b"], "layout": {"direction": "row", "gap": 10}, "at": {"tab": {"layout": {"direction": "column"}}}},
          {"id": "a", "kind": "rect", "h": 50, "at": {"tab": {"hidden": true}, "phone": {"hidden": false, "h": 20}}},
          {"id": "b", "kind": "rect", "h": 50}
        ]}
        """)
        #expect(p.widestFirst.map(\.id) == ["desk", "tab", "phone"])
        #expect(p.at("desk").layer("root")?.layout.isRow == true)
        #expect(p.at("tab").layer("root")?.layout.isRow == false)
        #expect(p.at("phone").layer("root")?.layout.isRow == false, "the tablet's column holds narrower too")
        #expect(p.at("tab").layer("a")?.hidden == true && p.at("phone").layer("a")?.hidden == false)
        let tab = DesignLayout.lay(p.at("tab"), width: 768, resolver: none, measure: Blocks())
        #expect(tab.frames["a"] == nil && tab.frames["b"] == CGRect(x: 0, y: 0, width: 768, height: 50), "hidden takes no room")
        let phone = DesignLayout.lay(p.at("phone"), width: 390, resolver: none, measure: Blocks())
        #expect(phone.frames["a"]?.height == 20 && phone.frames["b"]?.minY == 30)
        #expect(p.layer("a")?.at["phone"]?.says(["h"]) == true && p.layer("a")?.at["phone"]?.says(["w"]) == false)
        #expect(p.layer("root")?.at["tab"]?.says(["layout", "direction"]) == true && p.layer("root")?.at["tab"]?.says(["layout", "gap"]) == false)
    }

    @Test func aPictureIsAsTallAsItsWidthAtItsOwnAspect() throws {
        let p = try page("""
        {"id": "p", "root": "root", "breakpoints": [{"id": "d", "width": 400}], "layers": [
          {"id": "root", "children": ["pic", "none"]},
          {"id": "pic", "kind": "image", "src": "images/a.png"},
          {"id": "none", "kind": "image", "src": "images/missing.png"}
        ]}
        """)
        let laid = DesignLayout.lay(p, width: 400, resolver: none, measure: Blocks()) { $0 == "images/a.png" ? CGSize(width: 1600, height: 900) : nil }
        #expect(laid.frames["pic"] == CGRect(x: 0, y: 0, width: 400, height: 225))
        #expect(laid.frames["none"]?.height == 225, "no picture: a wide frame's shape, until there is one")
    }
}

/// A picture of one colour, as PNG bytes.
private func png(_ gray: CGFloat, width: Int = 32, height: Int = 18) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}

@MainActor
struct DesignProjectTests {
    private func opened() throws -> (DesignWorkspaceModel, ProjectGraph) {
        let designs = FileManager.default.temporaryDirectory.appending(path: "photon-design-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = DesignWorkspaceModel(folder: designs)
        let project = ProjectGraph(folder: nil)
        model.project = project
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return (model, project)
    }

    /// Key art, made by a flow, at version 1.
    private func keyArt(_ project: ProjectGraph) async throws -> Asset {
        let asset = try project.asset(madeBy: "Flows/key.flow.json", named: "Key art", in: .diffuse)
        let blob = try await project.pool.store(try png(0.2))
        try project.publish(asset.id, blob: blob, width: 32, height: 18)
        return try #require(project.asset(asset.id))
    }

    @Test func aBreakpointsChangeIsItsOwnAndPutBackInOneStep() throws {
        let (model, project) = try opened()
        model.breakpoint = "mobile"
        model.setLayout("features", "direction", to: "column")
        #expect(model.page?.layer("features")?.layout.direction == "row", "the page's own is untouched")
        #expect(model.pageHere?.layer("features")?.layout.direction == "column")
        #expect(model.says("features", ["layout", "direction"]) && !model.says("features", ["layout", "gap"]))
        #expect(model.undoLabel == "Direction of Features on Mobile")
        model.setLayout("features", "gap", to: DesignVal.text("--space-3").json)
        #expect(model.pageHere?.layer("features")?.layout.gap == .text("--space-3") && model.pageHere?.layer("features")?.layout.isRow == false)
        model.reset("features", ["layout", "direction"])
        #expect(model.pageHere?.layer("features")?.layout.isRow == true && !model.says("features", ["layout", "direction"]))
        model.setHidden("availability", true)
        #expect(model.pageHere?.layer("availability")?.hidden == true && model.page?.layer("availability")?.hidden == false)
        model.breakpoint = nil
        model.setStyle("hero", "fill", to: "--color-surface")
        #expect(model.page?.layer("hero")?.style.fill == "--color-surface" && model.page?.layer("hero")?.at["mobile"]?.style.fill == nil)
        // Every step on the project's history, in the design's name.
        project.undo(in: model.documentPath) { model.document!.undo() }
        #expect(model.page?.layer("hero")?.style.fill == nil)
        #expect(model.undoLabel == "Hide of Availability on Mobile")
        let css = try #require(model.document?.code(page: "home", layer: "page")).css
        #expect(css.contains("@media (max-width: 1279px)") && css.contains(".availability {\n    display: none;\n  }"))
    }

    @Test func anImageFollowsItsAssetAndItsLinkUndoesWithIt() async throws {
        let (model, project) = try opened()
        let asset = try await keyArt(project)
        model.selection = "hero"
        model.addImage(from: asset)
        await model.writing?.value
        let id = try #require(model.selection)
        let layer = try #require(model.page?.layer(id))
        #expect(layer.kind == .image && layer.src == "images/Key art.png" && model.page?.parent(of: id)?.id == "hero")
        let link = try #require(model.link(for: id))
        #expect(link.slot == "design:home/\(id)" && link.consumer == .design && link.pinned == nil)
        let file = try #require(model.document?.file(layer.src))
        #expect(try Data(contentsOf: file) == (try await project.pool.data(asset.newest!.blob)))
        #expect(model.imageSize(layer.src) == CGSize(width: 32, height: 18))
        #expect(model.undoLabel == "Add Key art")

        // A new version is written over the picture.
        let v2 = try png(0.8)
        try project.publish(asset.id, blob: try await project.pool.store(v2), width: 32, height: 18)
        await model.writing?.value
        #expect(try Data(contentsOf: file) == v2)
        // Keeping version 1 puts it back, and is a step.
        model.keep(1, for: try #require(model.link(for: id)))
        await model.writing?.value
        #expect(try Data(contentsOf: file) == (try await project.pool.data(asset.versions[0].blob)))
        #expect(model.link(for: id)?.pinned == 1 && model.undoLabel == "Keep Version 1")
        model.undo()
        await model.writing?.value
        #expect(try Data(contentsOf: file) == v2, "following the newest again")

        // The layer and its link go together, and come back together.
        model.undo()
        #expect(model.page?.layer(id) == nil && project.links.isEmpty)
        model.redo()
        #expect(model.page?.layer(id) != nil && model.link(for: id) != nil)
        model.selection = id
        model.removeSelected()
        #expect(model.page?.layer(id) == nil && project.links.isEmpty)
        model.undo()
        #expect(model.link(for: id) != nil)
    }

    @Test func aPictureFromAFileIsCopiedInAndPreviewedBesideThePage() throws {
        DesignWorkspaceModel.previewsQuietly = true
        let (model, _) = try opened()
        let source = FileManager.default.temporaryDirectory.appending(path: "photon-design-\(UUID().uuidString)-Lantern.png")
        try png(0.5, width: 40, height: 20).write(to: source)
        model.addImage(file: source)
        let id = try #require(model.selection)
        let src = try #require(model.page?.layer(id)?.src)
        #expect(src == "images/\(source.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: try #require(model.document?.file(src)).path))
        // The same file again is the same picture, not a second copy.
        model.addImage(file: source)
        #expect(model.page?.layer(try #require(model.selection))?.src == src)
        let page = try #require(model.preview())
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("<img class=\"\(id)\" src=\"\(src)\""))
        #expect(FileManager.default.fileExists(atPath: page.deletingLastPathComponent().appending(path: src).path))
        model.addImage(file: URL(fileURLWithPath: "/tmp/notes.txt"))
        #expect(model.notice?.contains("isn’t a PNG") == true)
    }

    @Test func aColourDragIsOneStepOnTheProjectsHistoryToo() throws {
        let (model, project) = try opened()
        for value in ["#eeeeee", "#dddddd"] {
            let now = try #require(model.document?.tokens.first { $0.name == "--color-ink" })
            model.setToken(now, to: value, coalescing: true)
        }
        #expect(project.history.done.count == 1 && model.undoLabel == "Set --color-ink")
        model.undo()
        #expect(model.document?.tokens.first { $0.name == "--color-ink" }?.value == "#f2efe6")
        #expect(model.undoLabel == nil)
    }
}

@MainActor
struct DesignComponentTests {
    private func opened() throws -> (DesignWorkspaceModel, ProjectGraph) {
        let designs = FileManager.default.temporaryDirectory.appending(path: "photon-design-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = DesignWorkspaceModel(folder: designs)
        let project = ProjectGraph(folder: nil)
        model.project = project
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return (model, project)
    }

    private func drawn(_ model: DesignWorkspaceModel, _ id: String) -> DesignLayer? {
        model.document?.expanded["home"]?.layer(id)
    }

    @Test func aPagesInstancesAreDrawnAsTheirComponentAndChosenWhole() throws {
        let (model, _) = try opened()
        #expect(model.page?.layer("wishlist")?.kind == .instance)
        #expect(drawn(model, "wishlist")?.kind == .frame && drawn(model, "wishlist.label")?.text == "Wishlist now")
        #expect(drawn(model, "trailer")?.style.stroke == "--color-line")
        #expect(DesignLayer.owner(of: "wishlist.label") == "wishlist" && DesignLayer.owner(of: "hero") == "hero")
        #expect(model.uses(of: "button").map(\.layer) == ["wishlist", "trailer"])
        #expect(model.document?.component("button")?.options.map(\.key) == ["variant=primary", "variant=secondary", "state=hover", "state=pressed", "state=disabled"])
    }

    @Test func anInstancePicksAnOptionAndItsOwnWords() throws {
        let (model, _) = try opened()
        model.setProp("wishlist", "variant", to: "secondary")
        #expect(drawn(model, "wishlist")?.style.fill == "transparent" && model.undoLabel == "Variant of Wishlist CTA")
        model.setProp("wishlist", "variant", to: nil)
        #expect(drawn(model, "wishlist")?.style.fill == "--color-lantern-500" && model.page?.layer("wishlist")?.props.isEmpty == true)
        model.setProp("wishlist", "variant", to: "ghost")
        #expect(model.notice?.contains("variant=ghost") == true)
        model.setWords("trailer", for: "label", to: "See the grove move")
        #expect(drawn(model, "trailer.label")?.text == "See the grove move")
        model.undo()
        #expect(drawn(model, "trailer.label")?.text == "Watch the trailer")
    }

    @Test func anOptionEditedInTheComponentReachesTheInstancesThatPickIt() throws {
        let (model, project) = try opened()
        model.selection = "wishlist"
        model.editComponent("button")
        #expect(model.page?.id == "button" && model.selection == nil)
        model.variant = "variant=secondary"
        #expect(model.overriding?.name == "Secondary")
        model.setStyle("label", "font", to: "--type-body")
        #expect(model.says("label", ["style", "font"]))
        #expect(drawn(model, "trailer.label")?.style.font == "--type-body", "the secondary changed")
        #expect(drawn(model, "wishlist.label")?.style.font == "--type-label-md", "the primary didn't")
        #expect(model.undoLabel == "Font of Label on Secondary")
        model.variant = nil
        model.setStyle("button", "radius", to: DesignVal.num(4).json)
        #expect(drawn(model, "wishlist")?.style.radius == .num(4) && drawn(model, "trailer")?.style.radius == .num(4))
        #expect(model.document?.unsaved == ["components/button.component.json"])
        // Steps in the component are the design's, undone in order.
        project.undo(in: model.documentPath) { model.document!.undo() }
        #expect(drawn(model, "trailer")?.style.radius == .text("--radius-full"))
        let code = try #require(model.code)
        #expect(code.css.contains(".button--variant-secondary .button__label {") && code.html.contains("button__label"))
        model.closeComponent()
        #expect(model.componentID == nil && model.selection == "wishlist")
    }

    @Test func aStateIsEditedOnItsArtboardAndAPageCanDisableAnInstance() throws {
        let (model, _) = try opened()
        model.editComponent("button")
        model.variant = "state=hover"
        #expect(model.overriding?.name == "Hover")
        model.setStyle("button", "opacity", to: 0.6)
        #expect(model.document?.component("button")?.asPage("state=hover").layer("button")?.style.opacity == 0.6)
        #expect(model.code?.css.contains(".button:hover:not(.button--state-disabled) {\n  opacity: 0.6;\n}") == true)
        model.closeComponent()
        model.setDisabled("trailer", true)
        #expect(drawn(model, "trailer")?.style.opacity == 0.4 && model.undoLabel == "State of Watch the trailer")
        #expect(model.document?.code(page: "home", layer: "trailer")?.html.contains("aria-disabled=\"true\"") == true)
        // The component can't drop the look a page is using.
        model.editComponent("button")
        model.setStates(["hover", "pressed"])
        #expect(model.notice?.contains("disabled") == true && model.component?.states.contains("disabled") == true)
        model.setStates(["hover", "focus", "pressed", "disabled"])
        #expect(model.component?.states == ["hover", "focus", "pressed", "disabled"])
    }

    @Test func aDetachedInstanceIsPlainLayersInOneStep() throws {
        let (model, project) = try opened()
        model.selection = "trailer"
        model.detachSelected()
        #expect(model.page?.layer("trailer")?.kind == .frame && model.page?.layer("trailer-label")?.text == "Watch the trailer")
        #expect(model.uses(of: "button").map(\.layer) == ["wishlist"])
        #expect(model.undoLabel == "Detach Watch the trailer" && project.history.done.count == 1)
        model.undo()
        #expect(model.page?.layer("trailer")?.kind == .instance && model.page?.layer("trailer-label") == nil)
        model.selection = "hero"
        model.detachSelected()
        #expect(model.page?.layer("hero")?.kind == .frame && project.history.done.isEmpty, "only an instance detaches")
    }

    @Test func aComponentHoldsAnotherAndTheyreDrawnAsOne() throws {
        let (model, _) = try opened()
        model.selection = "hero"
        model.makeComponent()
        #expect(model.page?.layer("hero")?.kind == .instance)
        #expect(drawn(model, "hero.wishlist")?.component == "button" && drawn(model, "hero.wishlist.label")?.text == "Wishlist now")
        #expect(DesignLayer.owner(of: "hero.wishlist.label") == "hero", "a click on it chooses the outer instance")
        let header = try #require(model.page?.layer("hero")?.component)
        #expect(model.document?.expandedComponent(header, option: nil)?.layer("trailer.label")?.text == "Watch the trailer")
        // Inside the component, its buttons are instances to pick options for.
        model.editComponent(header)
        model.setProp("trailer", "variant", to: "primary")
        #expect(drawn(model, "hero.trailer")?.style.fill == "--color-lantern-500")
        // Another placed inside it; but nothing inside itself.
        model.selection = "actions"
        model.place(component: "button")
        #expect(model.component?.layers.filter { $0.kind == .instance }.count == 3)
        model.closeComponent()
        model.editComponent("button")
        model.place(component: header)
        #expect(model.notice?.contains("inside itself") == true && model.component?.layers.allSatisfy { $0.kind != .instance } == true)
        // Its uses inside Hero count, and lead there.
        let inside = model.uses(of: "button").filter { $0.page.hasPrefix("component:") }
        #expect(inside.count == 3 && model.place(of: inside[0]) == "in Hero")
        model.show(inside[0])
        #expect(model.componentID == header && model.selection == inside[0].layer)
        // What the page's breakpoints said of the hero's layers stays.
        #expect(model.document?.expanded["home"]?.at("mobile").layer("hero.title")?.style.font == "--type-display-sm")
    }

    @Test func aComponentIsEditedAtThePagesBreakpoints() throws {
        let (model, _) = try opened()
        model.selection = "hero"
        model.makeComponent()
        let header = try #require(model.page?.layer("hero")?.component)
        model.editComponent(header)
        #expect(model.componentBreakpoints.map(\.name) == ["Desktop", "Mobile"])
        #expect(model.pageHere?.layer("title")?.style.font == "--type-display")
        model.componentBreakpoint = "mobile"
        #expect(model.overriding == DesignOverrideTarget(field: "at", key: "mobile", name: "Mobile"))
        #expect(model.pageHere?.layer("title")?.style.font == "--type-display-sm", "what Mobile said, kept")
        #expect(model.says("title", ["style", "font"]))
        model.setStyle("title", "color", to: "--color-lantern-500")
        #expect(model.undoLabel == "Colour of Title on Mobile")
        let drawn = model.document?.expanded["home"]
        #expect(drawn?.at("mobile").layer("hero.title")?.style.color == "--color-lantern-500")
        #expect(drawn?.at("desktop").layer("hero.title")?.style.color == "--color-ink")
        // A narrower breakpoint is what's edited, ahead of an option.
        model.variant = "state=hover"
        #expect(model.overriding?.field == "at")
        model.reset("title", ["style", "color"])
        #expect(model.document?.expanded["home"]?.at("mobile").layer("hero.title")?.style.color == "--color-ink")
    }

    @Test func aFrameMadeAComponentIsOneStepOnTheProjectsHistory() throws {
        let (model, project) = try opened()
        model.selection = "lantern"
        model.makeComponent()
        let instance = try #require(model.page?.layer("lantern"))
        #expect(instance.kind == .instance && instance.component == "a-lantern-that-matters")
        #expect(model.page?.layer("lantern-title") == nil && drawn(model, "lantern.lantern-title")?.text == "A lantern that matters")
        #expect(model.undoLabel == "Make A lantern that matters a Component" && project.history.done.count == 1)
        #expect(model.document?.view.components.map(\.id) == ["a-lantern-that-matters", "button"])
        model.undo()
        #expect(model.page?.layer("lantern")?.kind == .frame && model.document?.component("a-lantern-that-matters") == nil)
        model.redo()
        #expect(model.page?.layer("lantern")?.kind == .instance)
        // Placed again on the page: the same component, another instance.
        model.selection = "features"
        model.place(component: "a-lantern-that-matters")
        #expect(model.uses(of: "a-lantern-that-matters").count == 2)
        // Not a frame, or the page itself: said, not done.
        model.selection = "title"
        model.makeComponent()
        #expect(model.notice?.contains("Choose a frame") == true)
    }
}

@MainActor
struct DesignSyncTests {
    private func opened() throws -> (DesignWorkspaceModel, ProjectGraph, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "photon-design-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = DesignWorkspaceModel(folder: root.appending(path: "Designs", directoryHint: .isDirectory))
        let project = ProjectGraph(folder: nil)
        model.project = project
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        let folder = root.appending(path: "site/src/components", directoryHint: .isDirectory)
        model.keepInStep(with: folder)
        return (model, project, folder)
    }

    private func edit(_ folder: URL, _ rel: String, _ from: String, _ to: String) throws {
        let file = folder.appending(path: rel)
        let text = try String(contentsOf: file, encoding: .utf8)
        let found = try #require(text.range(of: from), "\(rel) has no \(from)")
        try text.replacingCharacters(in: found, with: to).write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func aFolderNearTheDesignIsSaidFromIt() {
        let design = URL(fileURLWithPath: "/Users/a/Lumen.photon/Designs/lumen", isDirectory: true)
        #expect(DesignWorkspaceModel.path(of: URL(fileURLWithPath: "/Users/a/site/src/components"), from: design) == "../../../site/src/components")
        #expect(DesignWorkspaceModel.path(of: URL(fileURLWithPath: "/Volumes/Other/site"), from: design) == "/Volumes/Other/site")
    }

    @Test func keepingInStepWritesTheFolderAsOneStep() throws {
        let (model, _, folder) = try opened()
        #expect(model.undoLabel == "Keep in Step with components")
        #expect(model.syncFolder?.standardizedFileURL == folder.standardizedFileURL)
        for rel in ["theme.css", "button.css", "button.html", "pages/home.css", "pages/home.html"] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: rel).path), "\(rel)")
        }
        // Nothing edited, nothing read back.
        model.checkSync()
        #expect(model.undoLabel == "Keep in Step with components")
        model.keepInStep(with: nil)
        #expect(model.syncFolder == nil)
    }

    @Test func aFileEditedOutsideComesBackAsAStepAndUndoes() throws {
        let (model, project, folder) = try opened()
        try edit(folder, "button.css", "border: 1px solid var(--color-line);", "border: 1px solid var(--color-ink);")
        model.checkSync()
        #expect(model.document?.component("button")?.layers.first?.when["variant=secondary"]?.style.stroke == "--color-ink")
        #expect(model.undoLabel == "From button.css" && project.history.done.count == 2)
        try edit(folder, "pages/home.html", "Carry the light through the Hollow Grove.", "Carry the light home.")
        model.checkSync()
        #expect(model.page?.layer("title")?.text == "Carry the light home." && model.undoLabel == "From pages/home.html")
        model.undo()
        #expect(model.page?.layer("title")?.text == "Carry the light through the Hollow Grove.")
        // Saving writes the folder as the design now is.
        model.saveNow()
        let page = try String(contentsOf: folder.appending(path: "pages/home.html"), encoding: .utf8)
        #expect(page.contains("Carry the light through the Hollow Grove."))
        #expect(model.notice?.contains("wrote") == true)
    }

    @Test func whatAFileSaysThatALayerDoesntIsSaid() throws {
        let (model, _, folder) = try opened()
        try edit(folder, "button.css", ".button__label {\n", ".button__label {\n  letter-spacing: 1px;\n")
        model.checkSync()
        #expect(model.syncNotes.count == 1 && model.syncNotes[0].contains("letter-spacing"))
        #expect(model.notice?.contains("letter-spacing") == true)
    }

    @Test func aFolderChosenAgainIsReadBeforeItsWrittenOver() throws {
        let (model, _, folder) = try opened()
        model.keepInStep(with: nil)
        try edit(folder, "pages/home.html", ">LUMEN<", ">Lumen<")
        model.keepInStep(with: folder)
        #expect(model.page?.layer("logo")?.text == "Lumen")
        let page = try String(contentsOf: folder.appending(path: "pages/home.html"), encoding: .utf8)
        #expect(page.contains(">Lumen<"), "the edit stands")
    }

    @Test func editsMadeWhileTheDesignWasClosedComeInWhenItOpens() throws {
        let (model, _, folder) = try opened()
        model.saveNow()
        let url = try #require(model.document?.url)
        model.close()
        try edit(folder, "pages/home.html", ">LUMEN<", ">Lumen<")
        model.open(url)
        #expect(model.page?.layer("logo")?.text == "Lumen" && model.undoLabel == "From pages/home.html")
    }

    private func exists(_ folder: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: rel).path)
    }

    @Test func writtenAsReactTheHTMLGoesAndTheTSXComesBack() throws {
        let (model, project, folder) = try opened()
        #expect(model.syncAs == "html")
        model.writeSync(as: "react")
        #expect(model.syncAs == "react" && model.undoLabel == "Write as React" && project.history.done.count == 2)
        for rel in ["theme.css", "button.css", "Button.tsx", "pages/home.css", "pages/Home.tsx"] {
            #expect(exists(folder, rel), "\(rel)")
        }
        #expect(!exists(folder, "button.html") && !exists(folder, "pages/home.html"), "Photon's HTML taken out")
        #expect(model.notice?.contains("as React") == true && model.notice?.contains("took out the 2") == true, "\(model.notice ?? "")")
        // Nothing edited, nothing read back.
        model.checkSync()
        #expect(model.undoLabel == "Write as React")
        // Words and an instance's props, edited in the .tsx, come back.
        try edit(folder, "pages/Home.tsx", ">Carry the light through the Hollow Grove.<", ">Carry the light home.<")
        try edit(folder, "pages/Home.tsx", "variant=\"secondary\" ", "")
        model.checkSync()
        #expect(model.page?.layer("title")?.text == "Carry the light home." && model.undoLabel == "From pages/Home.tsx")
        #expect(model.page?.layer("trailer")?.props.isEmpty == true)
        try edit(folder, "Button.tsx", "label = \"Button\"", "label = \"Go\"")
        model.checkSync()
        #expect(model.document?.component("button")?.layers.first { $0.id == "label" }?.text == "Go")
        // Saving keeps design.json saying so.
        model.saveNow()
        let design = try String(contentsOf: try #require(model.document?.url).appending(path: "design.json"), encoding: .utf8)
        #expect(design.contains("\"syncAs\": \"react\""))
    }

    @Test func writtenAsTailwindTheCSSGoesAndAClassComesBack() throws {
        let (model, project, folder) = try opened()
        model.writeSync(as: "react")
        model.writeSync(as: "tailwind")
        #expect(model.syncAs == "tailwind" && model.undoLabel == "Write as React and Tailwind" && project.history.done.count == 3)
        #expect(exists(folder, "Button.tsx") && exists(folder, "pages/Home.tsx"))
        #expect(!exists(folder, "button.css") && !exists(folder, "pages/home.css"), "a component's look is in its classes now")
        let theme = try String(contentsOf: folder.appending(path: "theme.css"), encoding: .utf8)
        #expect(theme.hasPrefix("@import \"tailwindcss\";") && theme.contains("@theme static {"))
        // A class edited there comes back as a step.
        try edit(folder, "pages/Home.tsx", "className=\"logo flex-none text-ink", "className=\"logo flex-none text-lantern-500")
        model.checkSync()
        #expect(model.page?.layer("logo")?.style.color == "--color-lantern-500" && model.undoLabel == "From pages/Home.tsx")
        #expect(model.syncNotes.isEmpty)
        model.undo()
        #expect(model.page?.layer("logo")?.style.color == "--color-ink")
    }

    @Test func anEditMadeJustBeforeTheFolderChangesKindComesInFirst() throws {
        let (model, project, folder) = try opened()
        try edit(folder, "button.html", ">Button<", ">Go<")
        model.writeSync(as: "react")
        #expect(model.document?.component("button")?.layers.first { $0.id == "label" }?.text == "Go")
        #expect(project.history.done.count == 3, "keep in step, from button.html, write as React")
        #expect(!exists(folder, "button.html"))
        let button = try String(contentsOf: folder.appending(path: "Button.tsx"), encoding: .utf8)
        #expect(button.contains("label = \"Go\""))
        // Back to HTML: the .tsx go, the HTML is written again.
        model.writeSync(as: "html")
        #expect(!exists(folder, "Button.tsx") && !exists(folder, "pages/Home.tsx") && exists(folder, "pages/home.html"))
        #expect(model.syncAs == "html" && model.undoLabel == "Write as HTML and CSS")
    }
}

struct DesignReviewTests {
    private func one(_ json: String, tokens: [DesignToken] = []) throws -> [DesignFinding] {
        DesignReview.review(try page(json), tokens: tokens, measure: Blocks())
    }

    @Test func contrastIsWCAGs() throws {
        let white = try #require(DesignResolver.color(css: "#ffffff"))
        let black = try #require(DesignResolver.color(css: "#000000"))
        #expect(abs(DesignReview.ratio(white, black) - 21) < 0.01)
        #expect(abs(DesignReview.ratio(white, white) - 1) < 0.01)
    }

    @Test func wordsTooFaintAreFoundAgainstWhatsBehindThem() throws {
        let found = try one("""
        {"id": "p", "name": "P", "root": "root", "breakpoints": [{"id": "d", "name": "Desktop", "width": 400}], "layers": [
          {"id": "root", "tag": "main", "children": ["card"], "style": {"fill": "#ffffff"}},
          {"id": "card", "children": ["faint", "fine", "big", "ghost"], "style": {"fill": "#00000000"}},
          {"id": "faint", "kind": "text", "tag": "h1", "text": "faint", "style": {"color": "#f2b84b", "font": "15px/18px system-ui"}},
          {"id": "fine", "kind": "text", "text": "fine", "style": {"color": "#222222", "font": "15px/18px system-ui"}},
          {"id": "big", "kind": "text", "text": "big", "style": {"color": "#8a8a8a", "font": "700 30px/32px system-ui"}},
          {"id": "ghost", "kind": "text", "text": "ghost", "style": {"color": "#222222", "font": "15px/18px system-ui", "opacity": 0.2}}
        ]}
        """)
        let faint = found.filter { $0.kind == "contrast" }
        #expect(Set(faint.map(\.layer)) == ["faint", "ghost"], "\(faint.map(\.said))")
        #expect(faint.first { $0.layer == "faint" }?.said.contains("1.8:1") == true, "\(faint.map(\.said))")
        #expect(faint.first?.level == .problem && faint.first?.breakpoint == nil, "the same at every breakpoint: said for the page")
    }

    @Test func aNameTwoLayersShareIsSaidWithItsFrame() throws {
        let found = try one("""
        {"id": "p", "name": "P", "root": "root", "breakpoints": [{"id": "d", "name": "Desktop", "width": 400}], "layers": [
          {"id": "root", "name": "Page", "tag": "main", "children": ["t", "one", "two"], "style": {"fill": "#ffffff"}},
          {"id": "t", "name": "Title", "kind": "text", "tag": "h1", "text": "title", "style": {"color": "#fafafa", "font": "15px/18px system-ui"}},
          {"id": "one", "name": "First", "children": ["a"]},
          {"id": "two", "name": "Second", "children": ["b"]},
          {"id": "a", "name": "Body", "kind": "text", "text": "a", "style": {"color": "#fafafa", "font": "15px/18px system-ui"}},
          {"id": "b", "name": "Body", "kind": "text", "text": "b", "style": {"color": "#fafafa", "font": "15px/18px system-ui"}}
        ]}
        """)
        let said = found.map(\.said)
        #expect(said.contains { $0.hasPrefix("Title's words") }, "\(said)")
        #expect(said.contains { $0.hasPrefix("Body (First)'s words") } && said.contains { $0.hasPrefix("Body (Second)'s words") }, "\(said)")
    }

    @Test func aSchemeIsReviewedOnItsOwnPalette() throws {
        let tokens = [
            DesignToken(name: "--ground", value: "#000000", scope: ":root", line: 1),
            DesignToken(name: "--ink", value: "#ffffff", scope: ":root", line: 2),
            DesignToken(name: "--ground", value: "#ffffff", scope: DesignResolver.scope(of: "light"), line: 3),
        ]
        let found = try one("""
        {"id": "p", "name": "P", "root": "root", "breakpoints": [{"id": "d", "name": "Desktop", "width": 400}], "layers": [
          {"id": "root", "children": ["t"], "style": {"fill": "--ground"}},
          {"id": "t", "kind": "text", "tag": "h1", "text": "words", "style": {"color": "--ink", "font": "15px/18px system-ui"}}
        ]}
        """, tokens: tokens)
        #expect(found.map(\.scheme) == ["light"], "\(found.map(\.said))")
    }

    @Test func whatRunsOutOfItsFrameIsMeasured() throws {
        let found = try one("""
        {"id": "p", "name": "P", "root": "root", "breakpoints": [{"id": "d", "name": "Desktop", "width": 500}, {"id": "m", "name": "Mobile", "width": 300}], "layers": [
          {"id": "root", "name": "Page", "children": ["row", "tight"], "style": {"fill": "#fff"}},
          {"id": "row", "name": "Row", "children": ["a", "b"], "layout": {"direction": "row"}},
          {"id": "a", "name": "A", "kind": "rect", "w": 200, "h": 10},
          {"id": "b", "name": "B", "kind": "rect", "w": 150, "h": 10},
          {"id": "tight", "name": "Tight", "kind": "text", "tag": "h1", "text": "twenty-five letters long.", "h": 10, "w": "fill", "style": {"color": "#000", "font": "10px/12px system-ui"}}
        ]}
        """)
        let over = found.filter { $0.kind == "overflow" }
        #expect(over.contains { $0.layer == "b" && $0.breakpoint == "m" && $0.said == "B runs 50 pt past Row at Mobile." }, "\(over.map(\.said))")
        #expect(!over.contains { $0.layer == "b" && $0.breakpoint == "d" }, "it fits at 500")
        #expect(over.contains { $0.layer == "tight" && $0.said == "Tight's words need 12 pt at Mobile, and it's set to 10 pt." }, "\(over.map(\.said))")
    }

    @Test func targetsHeadingsPicturesSmallTextAndRawValues() throws {
        let tokens = [DesignToken(name: "--gold", value: "#f2b84b", scope: ":root", line: 1)]
        let found = try one("""
        {"id": "p", "name": "Home", "root": "root", "breakpoints": [{"id": "d", "name": "Desktop", "width": 1000}, {"id": "m", "name": "Mobile", "width": 400}], "layers": [
          {"id": "root", "name": "Page", "children": ["link", "second", "third", "pic", "tiny", "raw"], "style": {"fill": "#fff"}},
          {"id": "link", "name": "Link", "kind": "text", "tag": "a", "text": "go", "style": {"color": "#000", "font": "15px/18px system-ui"}},
          {"id": "second", "name": "Second", "kind": "text", "tag": "h2", "text": "second", "style": {"color": "#000", "font": "15px/18px system-ui"}},
          {"id": "third", "name": "Fourth", "kind": "text", "tag": "h4", "text": "fourth", "style": {"color": "#000", "font": "15px/18px system-ui"}},
          {"id": "pic", "name": "Pic", "kind": "image", "src": "images/a.png"},
          {"id": "tiny", "name": "Tiny", "kind": "text", "text": "tiny", "style": {"color": "#000", "font": "9px/11px system-ui"}},
          {"id": "raw", "name": "Raw", "kind": "rect", "style": {"fill": "#F2B84B"}}
        ]}
        """, tokens: tokens)
        let said = found.map(\.said)
        #expect(found.contains { $0.kind == "touch" && $0.layer == "link" && $0.breakpoint == "m" }, "\(said)")
        #expect(!found.contains { $0.kind == "touch" && $0.breakpoint == "d" }, "a desktop has no fingers")
        #expect(said.contains("Home has no h1: nothing says what the page is."))
        #expect(said.contains("Fourth is an h4 after an h2: a level is skipped for someone reading by headings."))
        #expect(said.contains("Pic doesn't say what it shows, for someone who can't see it."))
        #expect(found.contains { $0.kind == "small" && $0.layer == "tiny" })
        #expect(said.contains("Raw says #F2B84B where --gold says the same: with the token, it follows the palette."))
        // Most serious first.
        #expect(found.map(\.level) == found.map(\.level).sorted())
    }
}

@MainActor
struct DesignReviewWorkspaceTests {
    private func opened() throws -> DesignWorkspaceModel {
        let designs = FileManager.default.temporaryDirectory.appending(path: "photon-design-\(UUID().uuidString)", directoryHint: .isDirectory)
        let model = DesignWorkspaceModel(folder: designs)
        model.create()
        _ = try #require(model.document, "\(model.notice ?? "")")
        return model
    }

    @Test func theStarterHasOnlyItsSmallNavLinksToFix() throws {
        let model = try opened()
        let found = model.findings
        #expect(found.allSatisfy { $0.kind == "touch" && $0.breakpoint == "mobile" }, "\(found.map(\.said))")
        #expect(Set(found.map(\.layer)) == ["story", "world", "press"], "\(found.map(\.said))")
    }

    @Test func aFindingFollowsTheEditAndLeadsToWhereItShows() throws {
        let model = try opened()
        let before = model.findings.count
        // The old lantern on paper: too faint, in the light scheme only.
        let lantern = try #require(model.document?.tokens.first { $0.name == "--color-lantern-500" && $0.scope == DesignResolver.scope(of: "light") })
        model.setToken(lantern, to: "#f2b84b")
        let faint = try #require(model.findings.first { $0.kind == "contrast" && $0.layer == "eyebrow" })
        #expect(faint.scheme == "light" && faint.breakpoint == nil && model.findings.first?.level == .problem)
        model.show(faint)
        #expect(model.selection == "eyebrow" && model.scheme == "light")
        model.undo()
        #expect(model.findings.count == before)
        let touch = try #require(model.findings.first)
        model.scheme = nil
        model.show(touch)
        #expect(model.selection == touch.layer && model.breakpoint == "mobile" && model.scheme == nil)
    }
}
