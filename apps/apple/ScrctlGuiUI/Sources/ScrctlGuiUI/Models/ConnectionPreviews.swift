import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import os

/// A connection's JPEG is local to the library. All access, including policy changes
/// and atomic replacement, is serialized on the main actor.
@MainActor @Observable
final class ConnectionPreviews {
    private final class Entry: NSObject {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    private let directory: URL
    private let settings: SettingsStore?
    @ObservationIgnored private let cache = NSCache<NSUUID, Entry>()
    @ObservationIgnored private var savedAt: [UUID: ContinuousClock.Instant] = [:]
    private var revision = 0
    private static let logger = Logger(subsystem: "app.openscreens", category: "ConnectionPreviews")

    init(libraryURL: URL, settings: SettingsStore?) {
        directory = libraryURL.deletingLastPathComponent().appendingPathComponent("Session Previews", isDirectory: true)
        self.settings = settings
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 128
    }

    var enabled: Bool { settings?.settings.showSessionPreviews ?? true }
    var policyRevision: Int { settings?.previewPolicyRevision ?? 0 }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jpg") }

    func image(for id: UUID) -> CGImage? {
        guard enabled else { return nil }
        _ = revision
        if let cached = cache.object(forKey: id as NSUUID) { return cached.image }
        let image = (try? Data(contentsOf: url(id)))
            .flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        cacheImage(image, for: id)
        return image
    }

    func save(_ image: CGImage, for id: UUID, updatedAt: ContinuousClock.Instant) {
        guard enabled, savedAt[id].map({ $0 < updatedAt }) ?? true else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var localDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try localDirectory.setResourceValues(values)
            try (data as Data).write(to: url(id), options: .atomic)
            savedAt[id] = updatedAt
            cacheImage(image, for: id)
            revision += 1
        } catch {
            Self.logger.error("Unable to save session preview: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ id: UUID) {
        do { try FileManager.default.removeItem(at: url(id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch { Self.logger.error("Unable to remove session preview: \(error.localizedDescription, privacy: .public)") }
        cache.removeObject(forKey: id as NSUUID)
        savedAt[id] = nil
        revision += 1
    }

    private func cacheImage(_ image: CGImage?, for id: UUID) {
        cache.setObject(Entry(image), forKey: id as NSUUID, cost: image.map { $0.bytesPerRow * $0.height } ?? 0)
    }
}
