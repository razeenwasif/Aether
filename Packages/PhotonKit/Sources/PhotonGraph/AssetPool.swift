import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os

/// Where assets' bytes are kept: once each, in the project's `blobs/` under
/// their SHA-256, so a version used in three places is one file. Pictures
/// are decoded once and the same image is given to every view that asks.
/// File work happens here, off the main actor (§7).
public actor AssetPool {
    /// `blobs/`, or `nil` to keep the bytes in memory, for tests.
    public nonisolated let folder: URL?
    private var memory: [String: Data] = [:]
    private var images: [String: SharedImage] = [:]

    /// Where an asset's bytes go between workspaces, timed for Instruments:
    /// kept, read and taken in, under `dev.razeen.photon` / `assets` (§7a).
    public static let signposter = OSSignposter(subsystem: "dev.razeen.photon", category: "assets")

    public init(blobs folder: URL?) {
        self.folder = folder
    }

    /// Keep `data`; answers its blob: the SHA-256 in hex.
    public func store(_ data: Data) throws -> String {
        let state = Self.signposter.beginInterval("store", "\(data.count) bytes")
        defer { Self.signposter.endInterval("store", state) }
        let blob = Self.hash(data)
        guard let folder else {
            memory[blob] = data
            return blob
        }
        let file = folder.appending(path: "\(blob).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return blob
    }

    /// Keep the file at `url`: cloned in, on APFS, so it costs no space until
    /// one of them changes.
    public func store(contentsOf url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let blob = Self.hash(data)
        guard let folder else {
            memory[blob] = data
            return blob
        }
        let file = folder.appending(path: "\(blob).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try FileManager.default.copyItem(at: url, to: file) } catch { try data.write(to: file, options: .atomic) }
        }
        return blob
    }

    public func data(_ blob: String) throws -> Data {
        let state = Self.signposter.beginInterval("read")
        defer { Self.signposter.endInterval("read", state) }
        if let data = memory[blob] { return data }
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: folder.appending(path: "\(blob).png"))
    }

    /// The picture a blob holds, decoded the first time it's asked for and
    /// the same image every time after.
    public func image(_ blob: String) -> SharedImage? {
        if let image = images[blob] { return image }
        guard let data = try? data(blob), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let shared = SharedImage(image)
        images[blob] = shared
        return shared
    }

    /// A picture's size, read from its header.
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A decoded picture shared by every view of it. A `CGImage` is immutable,
/// so handing the same one to each is safe.
public struct SharedImage: @unchecked Sendable {
    public let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
