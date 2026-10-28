import Testing
@testable import AetherShell

@MainActor
struct OmnibarTests {
    private func items() -> [OmniItem] {
        [
            OmniItem(.goTo, "Canvas", detail: "⌘4") {},
            OmniItem(.here, "Brush") {},
            OmniItem(.here, "New Frame") {},
            OmniItem(.assets, "Key art", live: true) {},
            OmniItem(.actions, "New Flow") {},
            OmniItem(.here, "Add KSampler", onlyWhenAsked: true) {},
        ]
    }

    @Test func nothingTypedListsByGroupTheWorkspacesOwnFirst() {
        let omnibar = OmnibarModel()
        #expect(omnibar.results(from: items()).map(\.title) == ["Brush", "New Frame", "New Flow", "Key art", "Canvas"], "nodes to add wait to be asked for")
        omnibar.cycleScope()
        #expect(omnibar.scope == .here && omnibar.results(from: items()).map(\.title) == ["Brush", "New Frame"])
        omnibar.cycleScope(back: true)
        omnibar.cycleScope(back: true)
        #expect(omnibar.scope == .goTo && omnibar.results(from: items()).map(\.title) == ["Canvas"])
    }

    @Test func lettersInOrderMatchBestAtTheStartsOfWords() {
        let omnibar = OmnibarModel()
        omnibar.query = "nf"
        #expect(omnibar.results(from: items()).map(\.title).prefix(2) == ["New Flow", "New Frame"], "the shorter first, for the same letters")
        omnibar.query = "ks"
        #expect(omnibar.results(from: items()).map(\.title) == ["Add KSampler"], "asked for now")
        omnibar.query = "zz"
        #expect(omnibar.results(from: items()).isEmpty)
        #expect(OmnibarModel.score("Key art", "ka")! > OmnibarModel.score("Bake a cake", "ka")!)

        omnibar.selected = 3
        omnibar.query = "k"
        #expect(omnibar.selected == 0, "typing starts at the top")
        omnibar.move(by: -1, in: 3)
        #expect(omnibar.selected == 2, "and round from the end")
    }
}

@MainActor
struct OmnibarTimingTests {
    @Test func aKeystrokeOverTwoThousandItemsFitsInAFrame() {
        let words = ["Add", "KSampler", "Load", "Image", "Save", "Canvas", "Brush", "Frame", "Upscale", "Model", "Latent", "Decode"]
        let items = (0..<2000).map { i in OmniItem(.here, "\(words[i % 12]) \(words[(i / 12) % 12]) \(i)", onlyWhenAsked: i > 200) {} }
        let omnibar = OmnibarModel()
        omnibar.open(with: items)
        let clock = ContinuousClock()
        var found: [OmniItem] = []
        let took = clock.measure {
            omnibar.query = "ksam"
            found = omnibar.results
        }
        #expect(!found.isEmpty && found.allSatisfy { $0.title.hasPrefix("KSampler") || $0.title.contains("KSampler") })
        // A keystroke, each title's letters ready: well inside the 2 ms the
        // chrome has a frame (§7a), in release; a test build is slower.
        #expect(took < .milliseconds(20), "\(took)")
        #expect(omnibar.results.map(\.id) == found.map(\.id), "asked again, the same")
    }
}
