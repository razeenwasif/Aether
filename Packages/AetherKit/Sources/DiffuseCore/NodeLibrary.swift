import DiffuseBridge
import Foundation

/// What the image server can run — its node catalogue and model lists — and
/// where that knowledge came from. A flow always opens and edits: when the
/// server is away, the last catalogue it served is used, and before it has
/// ever answered, the v1 catalogue shipped with the app.
public final class NodeLibrary: Sendable {
    public enum Source: Sendable, Equatable {
        case builtIn
        case cached(Date)
        case server(Date)

        public var label: String {
            switch self {
            case .builtIn: "Built-in catalogue"
            case .cached(let d): "Saved catalogue · \(d.formatted(date: .abbreviated, time: .shortened))"
            case .server: "Live from the server"
            }
        }
    }

    public let catalogue: Catalogue
    /// The same catalogue, held by the core for checking edits.
    public let core: NodeCatalogue
    public let models: ModelLists?
    public let modelsJSON: String?
    public let source: Source

    public init(catalogueJSON: String, modelsJSON: String?, source: Source) throws {
        core = try NodeCatalogue.parse(json: catalogueJSON)
        catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(catalogueJSON.utf8))
        self.modelsJSON = modelsJSON
        models = try modelsJSON.map { try JSONDecoder().decode(ModelLists.self, from: Data($0.utf8)) }
        self.source = source
    }

    /// The v1 catalogue and model lists that ship with Aether.
    public static func builtIn() -> NodeLibrary {
        // Both files are in the bundle and parse; a failure here is a broken build.
        let catalogue = try! String(contentsOf: Bundle.module.url(forResource: "catalogue-v1", withExtension: "json")!, encoding: .utf8)
        let models = try? String(contentsOf: Bundle.module.url(forResource: "models", withExtension: "json")!, encoding: .utf8)
        return try! NodeLibrary(catalogueJSON: catalogue, modelsJSON: models, source: .builtIn)
    }

    /// The last catalogue a server served, or the built-in one.
    public static func saved() -> NodeLibrary {
        let dir = LibraryCache.directory
        let catalogueURL = dir.appending(path: "catalogue.json")
        guard let text = try? String(contentsOf: catalogueURL, encoding: .utf8) else { return builtIn() }
        let models = try? String(contentsOf: dir.appending(path: "models.json"), encoding: .utf8)
        let date = (try? catalogueURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        return (try? NodeLibrary(catalogueJSON: text, modelsJSON: models, source: .cached(date))) ?? builtIn()
    }
}

/// Where the last catalogue a server served is kept, so graphs edit while it
/// is off: `~/Library/Application Support/Aether/Diffuse/`.
public enum LibraryCache {
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Aether/Diffuse", directoryHint: .isDirectory)
    }

    public static func keep(_ library: NodeLibrary) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? library.core.json().write(to: dir.appending(path: "catalogue.json"), atomically: true, encoding: .utf8)
        if let models = library.modelsJSON {
            try? models.write(to: dir.appending(path: "models.json"), atomically: true, encoding: .utf8)
        }
    }
}
