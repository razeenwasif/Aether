import DiffuseBridge
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures a flow's Load Images take, kept in the flow's folder as
/// Proton keeps them in Diffuse's: a Load Image names its picture relative
/// to the folder (`inputs/photo.png`, or an output's `outputs/…/x.png`), by
/// the plain name even when the file is sealed beside it.
public enum FlowInputs {
    public enum Failure: LocalizedError {
        case notAPicture(String)

        public var errorDescription: String? {
            switch self {
            case .notAPicture(let name): "\(name) isn’t a picture Aether can read."
            }
        }
    }

    /// The folder a flow's pictures are named from: the flow's own.
    public static func root(of flow: URL) -> URL {
        flow.deletingLastPathComponent()
    }

    /// The plain file a picture's name stands for.
    public static func file(_ name: String, flow: URL) -> URL {
        root(of: flow).appending(path: name)
    }

    /// The file on disk for a picture's name: its sealed twin when there is one.
    public static func onDisk(_ name: String, flow: URL) -> URL {
        let plain = file(name, flow: flow)
        return SealedFiles.isSealed(plain) ? SealedFiles.sealed(plain) : plain
    }

    /// Where the mask painted over a Load Image is kept: beside the flow, as
    /// `<flow>.<node>.mask.png`.
    public static func mask(node: String, flow: URL) -> URL {
        var stem = flow.lastPathComponent
        for suffix in [".json", ".flow"] where stem.hasSuffix(suffix) { stem.removeLast(suffix.count) }
        return root(of: flow).appending(path: "\(stem).\(node).mask.png")
    }

    /// The mask painted over a Load Image, as kept: a PNG, opened with
    /// `key` when it is sealed; `nil` when none was painted.
    public static func readMask(node: String, flow: URL, key: SealKey?) throws -> Data? {
        let plain = mask(node: node, flow: flow)
        guard SealedFiles.exists(plain) else { return nil }
        let onDisk = SealedFiles.isSealed(plain) ? SealedFiles.sealed(plain) : plain
        return try readFile(path: onDisk.path, key: key)
    }

    /// Keep a mask beside the flow, whole or not at all: sealed with `key`,
    /// plain without.
    public static func writeMask(_ png: Data, node: String, flow: URL, key: SealKey?) throws {
        _ = try writeFile(path: mask(node: node, flow: flow).path, bytes: png, key: key)
    }

    /// The name the picture at `url` has in the flow, when it is in the
    /// flow's folder; `nil` when it is elsewhere and has to be kept first.
    public static func name(of url: URL, flow: URL) -> String? {
        let plain = SealedFiles.plain(url).standardizedFileURL.resolvingSymlinksInPath().path
        let base = root(of: flow).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard plain.hasPrefix(base) else { return nil }
        return String(plain.dropFirst(base.count))
    }

    /// Keep the picture at `url` for the flow under its folder's `inputs/`,
    /// made a PNG if it isn't one: the same picture again is the same file.
    /// Sealed with `key`, plain without. Answers its name in the flow.
    /// Reads and draws the picture, so it is called off the main actor.
    public static func keep(_ url: URL, flow: URL, key: SealKey?) throws -> String {
        let sealed = url.lastPathComponent.hasSuffix(SealedFiles.suffix)
        let data = sealed ? try readFile(path: url.path, key: key) : try Data(contentsOf: url)
        let stem = SealedFiles.plain(url).deletingPathExtension().lastPathComponent
        let png = try pngData(data, name: SealedFiles.plain(url).lastPathComponent)
        return try keepPicture(root: root(of: flow).path, name: stem, bytes: png, key: key)
    }

    /// A picture as a PNG: as it is when it is one, else drawn into one at
    /// its full size, turned the way its camera says.
    static func pngData(_ data: Data, name: String) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
        else { throw Failure.notAPicture(name) }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.notAPicture(name)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notAPicture(name) }
        return out as Data
    }
}
