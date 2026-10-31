import Foundation

#if os(macOS)
/// A private key discovered in the user's `~/.ssh` directory.
public struct SSHKeyFile: Identifiable, Hashable, Sendable {
    public let path: String

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    public init(path: String) {
        self.path = path
    }
}

public enum SSHKeyCatalog {
    /// Lists regular files under `~/.ssh` whose contents look like a private key.
    public static func available() -> [SSHKeyFile] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: url)
            else { return nil }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: 128)).flatMap { $0 } ?? Data()
            let text = String(decoding: prefix, as: UTF8.self)
            guard text.contains("PRIVATE KEY") else { return nil }
            return SSHKeyFile(path: url.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
