import Foundation
import Observation

/// Metadata for a private key imported through the app. The PEM itself lives in
/// the Keychain; only this listing is written to disk.
public struct ImportedSSHKey: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public enum SSHKeyImportError: LocalizedError {
    case notAPrivateKey

    public var errorDescription: String? {
        NSLocalizedString(
            "The selected file is not an SSH private key in PEM format.",
            comment: "SSH key import error"
        )
    }
}

/// Imported private keys for SSH jump hosts.
@MainActor
@Observable
public final class SSHKeyVault {
    nonisolated public static let secretKind = "ssh-private-key"

    public private(set) var keys: [ImportedSSHKey] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        keys = Self.load(from: self.fileURL)
    }

    @discardableResult
    public func importKey(contentsOf url: URL) throws -> ImportedSSHKey {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        return try importKey(
            name: url.deletingPathExtension().lastPathComponent,
            pem: data
        )
    }

    @discardableResult
    public func importKey(name: String, pem: Data) throws -> ImportedSSHKey {
        guard let text = String(data: pem, encoding: .utf8),
              text.contains("PRIVATE KEY"),
              !text.contains("\0")
        else {
            throw SSHKeyImportError.notAPrivateKey
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ImportedSSHKey(
            name: trimmed.isEmpty
                ? NSLocalizedString("Imported key", comment: "Fallback SSH key name")
                : trimmed
        )
        OpenScreensCredentials.setSecret(text, kind: Self.secretKind, for: key.id)
        keys.append(key)
        persist()
        return key
    }

    public func delete(_ key: ImportedSSHKey) {
        OpenScreensCredentials.deleteSecret(kind: Self.secretKind, for: key.id)
        keys.removeAll { $0.id == key.id }
        persist()
    }

    public func privateKey(for id: UUID) -> String? {
        let pem = OpenScreensCredentials.secret(kind: Self.secretKind, for: id)
        return (pem?.isEmpty == false) ? pem : nil
    }

    // MARK: - Persistence

    private struct StoredVault: Codable {
        var version: Int
        var keys: [ImportedSSHKey]
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(StoredVault(version: 1, keys: keys)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [ImportedSSHKey] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode(StoredVault.self, from: data)
        else {
            return []
        }
        return stored.keys
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenScreens", isDirectory: true)
            .appendingPathComponent("ssh-keys.json")
    }
}
