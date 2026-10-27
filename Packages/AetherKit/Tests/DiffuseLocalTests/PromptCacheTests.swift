import CoreML
import StableDiffusion
import Testing
@testable import DiffuseLocal

struct PromptCacheTests {
    private let output = (hiddenEmbeddings: MLShapedArray<Float32>(scalars: [1, 2], shape: [2]),
                          pooledOutputs: MLShapedArray<Float32>(scalars: [3], shape: [1]))

    @Test func aPromptSeenBeforeIsntEncodedAgain() throws {
        let cache = PromptCache(keeps: true)
        var calls = 0
        let encode = { () -> TextEncoderXLModel.TextEncoderXLOutput in
            calls += 1
            return output
        }
        _ = try cache.output(slot: 1, text: "a lighthouse", encode: encode)
        let again = try cache.output(slot: 1, text: "a lighthouse", encode: encode)
        #expect(calls == 1 && again.hiddenEmbeddings == output.hiddenEmbeddings)
        // The other encoder, and another prompt, are encoded.
        _ = try cache.output(slot: 2, text: "a lighthouse", encode: encode)
        _ = try cache.output(slot: 1, text: "a harbour", encode: encode)
        #expect(calls == 3)
        let counts = cache.counts()
        #expect(counts.encoded == 3 && counts.kept == 1)
    }

    @Test func turnedOffItEncodesEveryTime() throws {
        let cache = PromptCache(keeps: false)
        var calls = 0
        for _ in 0..<3 {
            _ = try cache.output(slot: 1, text: "a lighthouse") {
                calls += 1
                return output
            }
        }
        #expect(calls == 3 && cache.counts().kept == 0)
    }

    @Test func itKeepsAFewRunsWorthAndLetsTheOldestGo() throws {
        let cache = PromptCache(keeps: true)
        var calls = 0
        let encode = { () -> TextEncoderXLModel.TextEncoderXLOutput in
            calls += 1
            return output
        }
        for n in 0...32 { _ = try cache.output(slot: 1, text: "prompt \(n)", encode: encode) }
        #expect(calls == 33)
        _ = try cache.output(slot: 1, text: "prompt 32", encode: encode)
        #expect(calls == 33, "the newest is kept")
        _ = try cache.output(slot: 1, text: "prompt 0", encode: encode)
        #expect(calls == 34, "the oldest made room")
    }
}
