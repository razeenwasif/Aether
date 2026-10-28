import AppKit
import Foundation
import Testing
@testable import CanvasCore
@testable import CanvasUI

struct CanvasRunTests {
    private func walk(_ run: CanvasRun, from start: (frame: Int, forward: Bool), steps: Int) -> [Int] {
        var (at, forward) = start
        var seen = [at]
        for _ in 0..<steps {
            (at, forward) = run.step(at: at, forward: forward)
            seen.append(at)
        }
        return seen
    }

    @Test func framesPlayOnBackOrToTheEndAndBack() {
        let all = CanvasRun(frames: 4, tag: nil)
        #expect(walk(all, from: all.start(), steps: 5) == [0, 1, 2, 3, 0, 1], "on, and round again")
        #expect(all.start(at: 2) == (2, true), "from the frame shown")

        let back = CanvasRun(frames: 6, tag: CanvasTag(name: "walk", from: 1, to: 3, direction: .reverse))
        #expect(walk(back, from: back.start(), steps: 4) == [3, 2, 1, 3, 2])
        let bounce = CanvasRun(frames: 6, tag: CanvasTag(name: "idle", from: 2, to: 4, direction: .pingPong))
        #expect(walk(bounce, from: bounce.start(), steps: 6) == [2, 3, 4, 3, 2, 3, 4], "the ends once each time round")
        #expect(bounce.start(at: 0) == (2, true), "outside the tag: its start")
        #expect(CanvasRun(frames: 3, tag: CanvasTag(name: "gone", from: 2, to: 7)) == CanvasRun(frames: 3, tag: nil), "a tag past the frames: every frame")
        #expect(CanvasRun.thumbSize(64, 32, most: 40) == (40, 20) && CanvasRun.thumbSize(1, 1000, most: 40) == (1, 40))
    }
}

@MainActor
struct CanvasAnimationTests {
    private let red = RGBA(255, 0, 0)
    private let blue = RGBA(0, 0, 255)

    private func model() throws -> CanvasWorkspaceModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "aether-canvases-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = CanvasWorkspaceModel(folder: folder, defaults: UserDefaults(suiteName: "aether-tests-\(UUID().uuidString)")!)
        model.stageSize = CGSize(width: 1400, height: 900)
        model.newCanvas(named: "Frames", preset: .pixel, width: 32, height: 32)
        return model
    }

    private func key(_ characters: String, shift: Bool = false, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func fill(_ model: CanvasWorkspaceModel, at x: Int32, _ color: RGBA) throws {
        let layer = try #require(model.currentLayer)
        model.change(.fillRect(layer: model.cel(layer), x: x, y: 0, width: 4, height: 4, color: color), label: "Fill")
    }

    @Test func eachFrameIsDrawnInAndShownOnItsOwn() throws {
        let model = try model()
        let doc = try #require(model.document)
        try fill(model, at: 0, red)
        model.addFrame()
        #expect(model.frameCount == 2 && model.frame == 1 && doc.state.undo == "New frame")
        try fill(model, at: 10, blue)
        #expect(doc.pick(x: 11, y: 1) == blue && doc.pick(x: 1, y: 1)?.a ?? 0 == 0, "the new frame is clear")
        model.showFrame(0)
        #expect(doc.pick(x: 1, y: 1) == red && doc.pick(x: 11, y: 1)?.a ?? 0 == 0)

        model.copyFrame()
        #expect(model.frameCount == 3 && model.frame == 1 && doc.pick(x: 1, y: 1) == red, "a copy, after it, shown")
        model.moveFrame(2, to: 0)
        #expect(model.frame == 0 && doc.pick(x: 11, y: 1) == blue, "the blue frame moved first")
        model.setDuration(250)
        model.setDurationForAll()
        #expect(doc.state.frames == [250, 250, 250])
        model.removeFrame()
        #expect(model.frameCount == 2 && doc.pick(x: 1, y: 1) == red)
        model.undo()
        #expect(model.frameCount == 3)
    }

    @Test func onionSkinShowsTheFramesEitherSideFaintly() throws {
        let model = try model()
        let doc = try #require(model.document)
        try fill(model, at: 0, red)
        model.addFrame()
        doc.layAll()
        #expect(doc.pixels.pixel(x: 1, y: 1)[3] == 0)
        model.onionOn = true
        let faint = doc.pixels.pixel(x: 1, y: 1)
        #expect(faint[3] > 0 && faint[3] < 255 && faint[0] > faint[2], "the frame before, red and faint: \(faint)")
        #expect(doc.pick(x: 1, y: 1)?.a ?? 0 == 0, "what is picked is the frame alone")
        model.onionBefore = 0
        #expect(doc.pixels.pixel(x: 1, y: 1)[3] == 0)
    }

    @Test func tagsAreAddedWidenedAndTakenAway() throws {
        let model = try model()
        model.addFrame()
        model.addFrame()
        model.showFrame(1)
        model.addTag()
        #expect(model.tags == [CanvasTag(name: "Tag 1", from: 1, to: 1)])
        model.editTag(0, name: " walk ", to: 9, direction: .pingPong)
        #expect(model.tags == [CanvasTag(name: "walk", from: 1, to: 2, direction: .pingPong)], "held to the frames there are")
        model.playTag = "walk"
        model.showFrame(0)
        model.playTag = ""
        model.playTag = "walk"
        #expect(model.frame == 1, "choosing a tag shows its first frame")
        model.removeTag(0)
        #expect(model.tags.isEmpty && model.playTag == "")
    }

    @Test func keysStepCopyAndPlay() async throws {
        let model = try model()
        #expect(model.handleKey(key("N", shift: true)) && model.frameCount == 2 && model.frame == 1)
        #expect(model.handleKey(key(",")) && model.frame == 0)
        #expect(model.handleKey(key(".")) && model.frame == 1)
        #expect(model.handleKey(key(".")) && model.frame == 0, "round from the end")
        #expect(model.handleKey(key("O", shift: true)) && model.onionOn)
        model.onionOn = false
        #expect(model.handleKey(key("n")) && model.tool == .brush, "n without ⇧ is still a tool")

        model.change(.setDuration(from: 0, to: 1, duration: 100), label: "Frame times")
        #expect(model.handleKey(key("\r", code: 36)) && model.playing)
        // Waited for, not timed: other suites share the main actor.
        let clock = ContinuousClock()
        let began = clock.now
        while model.frame == 0, clock.now < began + .seconds(3) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.frame == 1 && clock.now - began >= .milliseconds(90), "a frame on, once its 100 ms are up")
        #expect(model.handleKey(key("\u{1b}", code: 53)) && !model.playing)
        model.play()
        try fill(model, at: 0, red)
        #expect(!model.playing, "an edit stops it")
    }

    @Test func thumbnailsAreDrawnForTheFramesThatChanged() throws {
        let model = try model()
        let doc = try #require(model.document)
        model.addFrame()
        model.refreshThumbs()
        #expect(model.thumbs.count == 2 && model.thumbs[0]?.width == 80)
        try fill(model, at: 0, blue)
        #expect(doc.takeStaleFrames() == [1], "only the frame drawn in")
        model.copyFrame()
        #expect(doc.takeStaleFrames() == nil, "frames added: all of them")
    }

    @Test func aPasteGoesInTheFrameShown() throws {
        let model = try model()
        let doc = try #require(model.document)
        model.clipboard = NSPasteboard(name: NSPasteboard.Name("aether-tests-\(UUID().uuidString)"))
        try fill(model, at: 0, red)
        model.copy()
        model.addFrame()
        model.paste()
        let pasted = try #require(model.currentLayer)
        #expect(pasted.name == "Pasted" && doc.pick(x: 1, y: 1) == red, "in the frame shown")
        model.showFrame(0)
        #expect(doc.lift(model.cel(pasted)) == nil, "and clear in the others")
    }
}
