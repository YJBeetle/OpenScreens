import CoreGraphics
import Foundation
import Observation
import os
import SwiftUI

public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: NSLocalizedString("System", comment: "Appearance")
        case .light: NSLocalizedString("Light", comment: "Appearance")
        case .dark: NSLocalizedString("Dark", comment: "Appearance")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum TileDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case comfortable
    case spacious

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compact: NSLocalizedString("Compact", comment: "Tile density")
        case .comfortable: NSLocalizedString("Comfortable", comment: "Tile density")
        case .spacious: NSLocalizedString("Spacious", comment: "Tile density")
        }
    }

    public var minimumTileWidth: CGFloat {
        switch self {
        case .compact: 156
        case .comfortable: 196
        case .spacious: 248
        }
    }

    public var maximumTileWidth: CGFloat {
        switch self {
        case .compact: 220
        case .comfortable: 280
        case .spacious: 340
        }
    }

    public var columnSpacing: CGFloat {
        switch self {
        case .compact: 12
        case .comfortable: 16
        case .spacious: 20
        }
    }
}

public enum UpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case release
    case prerelease
    case snapshot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .release: NSLocalizedString("Release", comment: "Update channel")
        case .prerelease: NSLocalizedString("Pre-release", comment: "Update channel")
        case .snapshot: NSLocalizedString("Snapshot", comment: "Update channel")
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance: AppAppearance
    public var tileDensity: TileDensity
    public var defaultCursorMode: CursorMode
    public var sharedClipboard: Bool
    public var autoReconnect: Bool
    public var confirmDisconnect: Bool
    public var updateChannel: UpdateChannel

    public init(
        appearance: AppAppearance = .system,
        tileDensity: TileDensity = .comfortable,
        defaultCursorMode: CursorMode = .touch,
        sharedClipboard: Bool = true,
        autoReconnect: Bool = true,
        confirmDisconnect: Bool = true,
        updateChannel: UpdateChannel = .release
    ) {
        self.appearance = appearance
        self.tileDensity = tileDensity
        self.defaultCursorMode = defaultCursorMode
        self.sharedClipboard = sharedClipboard
        self.autoReconnect = autoReconnect
        self.confirmDisconnect = confirmDisconnect
        self.updateChannel = updateChannel
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, tileDensity, defaultCursorMode, sharedClipboard
        case autoReconnect, confirmDisconnect, updateChannel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decode(AppAppearance.self, forKey: .appearance)
        tileDensity = try container.decode(TileDensity.self, forKey: .tileDensity)
        defaultCursorMode = try container.decode(CursorMode.self, forKey: .defaultCursorMode)
        sharedClipboard = try container.decode(Bool.self, forKey: .sharedClipboard)
        autoReconnect = try container.decode(Bool.self, forKey: .autoReconnect)
        confirmDisconnect = try container.decode(Bool.self, forKey: .confirmDisconnect)
        updateChannel = try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .release
    }
}

@MainActor
@Observable
public final class SettingsStore {
    private static let logger = Logger(subsystem: "app.openscreens", category: "SettingsStore")

    public var settings: AppSettings {
        didSet { persist() }
    }

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    public func resetToDefaults() {
        settings = AppSettings()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Unable to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpenScreens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("settings.json")
    }
}
