import DiffuseBridge
import Foundation
import LocalAuthentication
import Security

/// Proton's key for Diffuse's sealed files: 32 bytes kept in the person's
/// login keychain as a password item of Proton's own (service "Proton
/// Diffuse", account "seal key"), read only after they prove they are at the
/// Mac. Photon never makes or changes the key; files Proton never sealed
/// need none.
///
/// The item was made by Proton, so the keychain asks the person, once per
/// build, to let Photon read it. That prompt is theirs to answer.
public enum SealVault {
    static let service = "Proton Diffuse"
    static let account = "seal key"

    public enum Failure: LocalizedError {
        case denied
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .denied: "The keychain didn’t give Photon the key."
            case .keychain(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "The keychain said \(status)."
            }
        }
    }

    /// The key, or `nil` when Proton never made one. Blocks while the
    /// keychain asks the person, so it is called off the main actor.
    public static func readKey() throws -> SealKey? {
        #if DEBUG
        if let file = testKeyFile {
            return try SealKey(key: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        switch status {
        case errSecSuccess:
            guard let data = found as? Data else { throw Failure.keychain(errSecDecode) }
            return try SealKey(key: data)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw Failure.denied
        default:
            throw Failure.keychain(status)
        }
    }

    /// Whether a debug build is using a key from a file instead of the
    /// keychain: `PHOTON_SEAL_KEY_FILE` (or legacy `AETHER_SEAL_KEY_FILE`),
    /// for testing against sealed fixtures. Release builds never read it.
    public static var usesTestKey: Bool {
        #if DEBUG
        testKeyFile != nil
        #else
        false
        #endif
    }

    #if DEBUG
    private static var testKeyFile: String? {
        let env = ProcessInfo.processInfo.environment
        return env["PHOTON_SEAL_KEY_FILE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? env["AETHER_SEAL_KEY_FILE"].flatMap { $0.isEmpty ? nil : $0 }
    }
    #endif
}

/// Ask the person to prove they are at the Mac: Touch ID, or its password.
/// macOS says "Photon is trying to <reason>."
public enum OwnerCheck {
    public enum Failure: LocalizedError {
        case cancelled
        case unavailable(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: nil
            case .unavailable(let why), .failed(let why): why
            }
        }
    }

    public static func ask(reason: String) async throws {
        let context = LAContext()
        var why: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &why) else {
            throw Failure.unavailable(why?.localizedDescription ?? "This Mac can’t ask for Touch ID or its password.")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
            throw Failure.cancelled
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}

/// Names of Diffuse's files, sealed or plain. A sealed file is its plain
/// file's name with `.sealed` after it, as Proton writes it.
public enum SealedFiles {
    public static let suffix = ".sealed"

    /// The plain file `url` stands for: itself, or without `.sealed`.
    public static func plain(_ url: URL) -> URL {
        guard url.lastPathComponent.hasSuffix(suffix) else { return url }
        return url.deletingLastPathComponent().appending(path: String(url.lastPathComponent.dropLast(suffix.count)))
    }

    /// The sealed twin of the plain file `url`.
    public static func sealed(_ url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + suffix)
    }

    /// Whether the plain file `url` is kept sealed.
    public static func isSealed(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: sealed(url).path)
    }

    /// Whether there is a file for the plain file `url`, sealed or plain.
    public static func exists(_ url: URL) -> Bool {
        isSealed(url) || FileManager.default.fileExists(atPath: url.path)
    }
}
