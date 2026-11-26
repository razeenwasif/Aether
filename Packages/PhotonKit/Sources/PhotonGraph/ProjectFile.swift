import Foundation

/// `project.json`: the graph's nodes, sorted by id and keys sorted, so it
/// diffs well in git as Proton's formats do (§4, package format).
struct ProjectFile: Codable {
    static let name = "project.json"

    var format = "photon.project"
    var version = 1
    var name: String
    var nodes: [Node]

    init(name: String, nodes: [Node]) {
        self.name = name
        self.nodes = nodes.sorted { $0.id < $1.id }
    }

    static func read(from folder: URL) throws -> ProjectFile? {
        let file = folder.appending(path: Self.name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ProjectFile.self, from: Data(contentsOf: file))
        guard project.format == "photon.project" || project.format == "aether.project" else { throw CocoaError(.fileReadCorruptFile) }
        guard project.version <= 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        return project
    }

    func write(into folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: folder.appending(path: Self.name), options: .atomic)
    }
}
