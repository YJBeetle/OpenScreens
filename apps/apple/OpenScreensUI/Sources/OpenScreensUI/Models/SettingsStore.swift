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

public enum LibraryLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .grid: NSLocalizedString("Grid", comment: "Library layout")
        case .list: NSLocalizedString("List", comment: "Library layout")
        }
    }

    public var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
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

public enum LibrarySortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case lastConnected
    case connectionCount
    case manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: NSLocalizedString("Name", comment: "Library sort order")
        case .lastConnected: NSLocalizedString("Last Connected", comment: "Library sort order")
        case .connectionCount: NSLocalizedString("Connection Count", comment: "Library sort order")
        case .manual: NSLocalizedString("Custom Order", comment: "Library sort order")
        }
    }
}

/// Screen edge the session toolbar is docked to. The toolbar can be dragged
/// between edges on iPad; left and right rails stack vertically.
public enum ToolbarDock: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom
    case left
    case right

    public var id: String { rawValue }

    public var orientation: FloatingBarOrientation {
        self == .bottom ? .horizontal : .vertical
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance: AppAppearance
    public var tileDensity: TileDensity
    public var librarySort: LibrarySortOrder
    public var libraryLayout: LibraryLayout
    public var defaultCursorMode: CursorMode
    public var sharedClipboard: Bool
    public var autoReconnect: Bool
    public var confirmDisconnect: Bool
    public var updateChannel: UpdateChannel
    public var showToolbarOnLaunch: Bool
    public var toolbarItems: [SessionToolbarItem]
    public var toolbarDock: ToolbarDock
    /// Browse for computers advertising VNC over Bonjour on the local network.
    public var discoverNearby: Bool
    /// iOS-only privacy gate: require Face ID / Touch ID when returning to the app.
    public var requireBiometrics: Bool

    public init(
        appearance: AppAppearance = .system,
        tileDensity: TileDensity = .comfortable,
        librarySort: LibrarySortOrder = .name,
        libraryLayout: LibraryLayout = .grid,
        defaultCursorMode: CursorMode = .touch,
        sharedClipboard: Bool = true,
        autoReconnect: Bool = true,
        confirmDisconnect: Bool = true,
        updateChannel: UpdateChannel = .release,
        showToolbarOnLaunch: Bool = true,
        toolbarItems: [SessionToolbarItem] = SessionToolbarItem.allCases,
        toolbarDock: ToolbarDock = .bottom,
        discoverNearby: Bool = true,
        requireBiometrics: Bool = false
    ) {
        self.appearance = appearance
        self.tileDensity = tileDensity
        self.librarySort = librarySort
        self.libraryLayout = libraryLayout
        self.defaultCursorMode = defaultCursorMode
        self.sharedClipboard = sharedClipboard
        self.autoReconnect = autoReconnect
        self.confirmDisconnect = confirmDisconnect
        self.updateChannel = updateChannel
        self.showToolbarOnLaunch = showToolbarOnLaunch
        self.toolbarItems = toolbarItems
        self.toolbarDock = toolbarDock
        self.discoverNearby = discoverNearby
        self.requireBiometrics = requireBiometrics
    }

    private enum CodingKeys: String, CodingKey {
        case appearance, tileDensity, librarySort, libraryLayout, defaultCursorMode, sharedClipboard
        case autoReconnect, confirmDisconnect, updateChannel, showToolbarOnLaunch, toolbarItems
        case toolbarDock, discoverNearby, requireBiometrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decode(AppAppearance.self, forKey: .appearance)
        tileDensity = try container.decode(TileDensity.self, forKey: .tileDensity)
        librarySort = try container.decodeIfPresent(LibrarySortOrder.self, forKey: .librarySort) ?? .name
        libraryLayout = try container.decodeIfPresent(LibraryLayout.self, forKey: .libraryLayout) ?? .grid
        defaultCursorMode = try container.decode(CursorMode.self, forKey: .defaultCursorMode)
        sharedClipboard = try container.decode(Bool.self, forKey: .sharedClipboard)
        autoReconnect = try container.decode(Bool.self, forKey: .autoReconnect)
        confirmDisconnect = try container.decode(Bool.self, forKey: .confirmDisconnect)
        updateChannel = try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .release
        showToolbarOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .showToolbarOnLaunch) ?? true
        toolbarItems = try container.decodeIfPresent([SessionToolbarItem].self, forKey: .toolbarItems)
            ?? SessionToolbarItem.allCases
        toolbarDock = try container.decodeIfPresent(ToolbarDock.self, forKey: .toolbarDock) ?? .bottom
        discoverNearby = try container.decodeIfPresent(Bool.self, forKey: .discoverNearby) ?? true
        requireBiometrics = try container.decodeIfPresent(Bool.self, forKey: .requireBiometrics) ?? false
    }
}

/// Buttons that can be shown in the session toolbar. The hide and disconnect
/// controls are always present and intentionally not configurable.
public enum SessionToolbarItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case pointer
    case displays
    case keyboard
    case clipboard
    case download
    case display
    case hotCorners
    case observe
    case screenshot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pointer: NSLocalizedString("Pointer", comment: "Toolbar item")
        case .displays: NSLocalizedString("Select Display", comment: "Toolbar item")
        case .keyboard: NSLocalizedString("Keyboard", comment: "Toolbar item")
        case .clipboard: NSLocalizedString("Clipboard", comment: "Toolbar item")
        case .download: NSLocalizedString("Download", comment: "Toolbar item")
        case .display: NSLocalizedString("Display options", comment: "Toolbar item")
        case .hotCorners: NSLocalizedString("Hot Corners", comment: "Toolbar item")
        case .observe: NSLocalizedString("Observe Mode", comment: "Toolbar item")
        case .screenshot: NSLocalizedString("Screenshot", comment: "Toolbar item")
        }
    }

    public var systemImage: String {
        switch self {
        case .pointer: "cursorarrow"
        case .displays: "rectangle.on.rectangle"
        case .keyboard: "keyboard"
        case .clipboard: "doc.on.clipboard"
        case .download: "arrow.down.doc"
        case .display: "display"
        case .hotCorners: "square.grid.3x3"
        case .observe: "eye"
        case .screenshot: "camera"
        }
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
