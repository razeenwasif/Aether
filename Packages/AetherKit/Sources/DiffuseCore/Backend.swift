import DiffuseBridge
import Foundation

/// Somewhere flows run. Nexus's image server on forge is the first; a local
/// Core ML backend (RESEARCH_PLAN.md Q3) slots in behind the same protocol.
public protocol ImageBackend: Sendable {
    var displayName: String { get }
    func health() async -> Health
    /// The server's live catalogue and model lists.
    func library() async throws -> NodeLibrary
    /// Send a picture a run's Load Image takes (a PNG or a JPEG); answers
    /// the server's name for it, to put in the graph.
    func upload(_ picture: Data) async throws -> String
    func run(graphJSON: String) async throws -> Queued
    func events(run: String) -> AsyncThrowingStream<RunEvent, Error>
    func image(_ id: String) async throws -> Data
    func cancel(run: String) async throws
}

/// A blocking call into the core, made off the main actor.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

// MARK: - Nexus

/// Where the gateway is: at home on the LAN, and away over Tailscale.
public struct GatewaySettings: Sendable, Equatable {
    public static let defaultHome = "http://atlas:7420/img/v1"

    public var home: String
    public var away: String

    public init(home: String, away: String) {
        self.home = home
        self.away = away
    }

    public var bases: [String] { [home, away].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    /// Aether's own settings; then Proton's, so both apps reach the same
    /// gateway without setting it twice; then the default.
    public static func current(defaults: UserDefaults = .standard) -> GatewaySettings {
        if let override = ProcessInfo.processInfo.environment["AETHER_GATEWAY"], !override.isEmpty {
            return GatewaySettings(home: override, away: "")
        }
        if let home = defaults.string(forKey: "diffuse.gateway") {
            return GatewaySettings(home: home, away: defaults.string(forKey: "diffuse.gatewayAway") ?? "")
        }
        let proton = URL.homeDirectory.appending(path: ".config/proton/settings.json")
        if let data = try? Data(contentsOf: proton),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return GatewaySettings(
                home: object["diffuse.gateway"] as? String ?? defaultHome,
                away: object["diffuse.gatewayAway"] as? String ?? "")
        }
        return GatewaySettings(home: defaultHome, away: "")
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(home, forKey: "diffuse.gateway")
        defaults.set(away, forKey: "diffuse.gatewayAway")
    }
}

/// The gateway key: `NEXUS_KEY` from Aether's environment, else the login
/// shell's (an app opened from the Dock inherits no shell). Kept in memory,
/// never written or shown.
public enum GatewayKey {
    public static func find() -> String? {
        if let key = ProcessInfo.processInfo.environment["NEXUS_KEY"], !key.isEmpty { return key }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        for flags in [["-lc"], ["-lic"]] {
            if let key = run(shell, flags + [#"printf %s "$NEXUS_KEY""#]), !key.isEmpty { return key }
        }
        return nil
    }

    private static func run(_ shell: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date.now.addingTimeInterval(5)
        while process.isRunning && Date.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Nexus's image server on forge, through atlas's gateway.
public final class NexusBackend: ImageBackend {
    public let displayName = "Nexus · forge"
    public let settings: GatewaySettings
    private let gateway: Gateway?

    public init(settings: GatewaySettings, key: String?) {
        self.settings = settings
        gateway = key.flatMap { try? Gateway(bases: settings.bases, key: $0) }
    }

    public func health() async -> Health {
        guard let gateway else {
            return Health(state: .noKey, url: nil, ms: nil, status: nil,
                          message: "No NEXUS_KEY in your shell: export it in your profile, then look again")
        }
        let json = (try? await offMain { gateway.health() }) ?? ""
        return (try? JSONDecoder().decode(Health.self, from: Data(json.utf8)))
            ?? Health(state: .failing, url: nil, ms: nil, status: nil, message: "The gateway's answer could not be read")
    }

    public func library() async throws -> NodeLibrary {
        let gateway = try need()
        let (catalogue, models) = try await offMain { (try gateway.catalogue().json(), try? gateway.models()) }
        return try NodeLibrary(catalogueJSON: catalogue, modelsJSON: models, source: .server(.now))
    }

    public func upload(_ picture: Data) async throws -> String {
        struct Upload: Decodable { var id: String }
        let gateway = try need()
        let json = try await offMain { try gateway.upload(bytes: picture) }
        return try JSONDecoder().decode(Upload.self, from: Data(json.utf8)).id
    }

    public func run(graphJSON: String) async throws -> Queued {
        let gateway = try need()
        let json = try await offMain { try gateway.run(graphJson: graphJSON) }
        return try JSONDecoder().decode(Queued.self, from: Data(json.utf8))
    }

    public func events(run: String) -> AsyncThrowingStream<RunEvent, Error> {
        let gateway = self.gateway
        return AsyncThrowingStream { continuation in
            let thread = Thread {
                do {
                    guard let gateway else { throw BackendError.noKey }
                    let events = try gateway.events(run: run)
                    let decoder = JSONDecoder()
                    while let json = try events.next() {
                        if let event = try? decoder.decode(RunEvent.self, from: Data(json.utf8)) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.name = "diffuse.events.\(run)"
            thread.start()
        }
    }

    public func image(_ id: String) async throws -> Data {
        let gateway = try need()
        return try await offMain { try gateway.image(image: id) }
    }

    public func cancel(run: String) async throws {
        let gateway = try need()
        try await offMain { try gateway.cancel(run: run) }
    }

    private func need() throws -> Gateway {
        guard let gateway else { throw BackendError.noKey }
        return gateway
    }
}

public enum BackendError: LocalizedError {
    case noKey

    public var errorDescription: String? {
        switch self {
        case .noKey: "There is no NEXUS_KEY to send to the gateway"
        }
    }
}
