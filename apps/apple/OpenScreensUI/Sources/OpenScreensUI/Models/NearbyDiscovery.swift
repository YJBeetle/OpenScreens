import Foundation
import Observation
import SwiftUI
import os

/// A VNC server advertised over Bonjour on the local network.
public struct DiscoveredComputer: Identifiable, Hashable, Sendable {
    public var name: String
    public var host: String
    public var port: Int

    public var id: String { "\(host.lowercased()):\(port)" }

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses `_rfb._tcp` services published by computers on the local network.
@MainActor
@Observable
public final class NearbyDiscovery: NSObject {
    private static let logger = Logger(subsystem: "app.openscreens", category: "NearbyDiscovery")
    private static let serviceType = "_rfb._tcp."
    private static let domain = "local."

    public private(set) var computers: [DiscoveredComputer] = []
    public private(set) var isSearching = false
    public private(set) var failureMessage: String?

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var known: [String: NetService] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var resolved: [String: DiscoveredComputer] = [:]

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        guard !isSearching else { return }
        failureMessage = nil
        isSearching = true
        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.domain)
    }

    public func stop() {
        browser.stop()
        isSearching = false
        for service in known.values {
            service.delegate = nil
            service.stop()
        }
        known.removeAll()
        resolving.removeAll()
        resolved.removeAll()
        computers = []
    }

    private static func key(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func resolve(_ service: NetService) {
        let key = Self.key(for: service)
        guard known[key] == nil, !service.name.isEmpty else { return }
        known[key] = service
        resolving.insert(key)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    private func finishResolving(_ service: NetService, hostName: String?) {
        let key = Self.key(for: service)
        resolving.remove(key)
        guard let hostName, service.port > 0 else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        resolved[key] = DiscoveredComputer(name: service.name, host: host, port: service.port)
        publish()
    }

    private func remove(_ service: NetService) {
        let key = Self.key(for: service)
        known.removeValue(forKey: key)
        resolving.remove(key)
        resolved.removeValue(forKey: key)
        publish()
    }

    private func publish() {
        var seen = Set<String>()
        computers = resolved.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.id).inserted }
    }
}

/// NetService calls its delegates on the run loop the browser was created on.
extension NearbyDiscovery: @MainActor NetServiceBrowserDelegate, @MainActor NetServiceDelegate {
    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        resolve(service)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        remove(service)
    }

    public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isSearching = true
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        isSearching = false
        failureMessage = NSLocalizedString(
            "Nearby discovery is unavailable. Allow local network access for OpenScreens in Settings.",
            comment: "Nearby discovery failure"
        )
        Self.logger.error("Bonjour search failed: \(errorDict, privacy: .public)")
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        finishResolving(sender, hostName: sender.hostName)
    }

    public func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        resolving.remove(Self.key(for: sender))
        Self.logger.debug("Unable to resolve \(sender.name, privacy: .public): \(errorDict, privacy: .public)")
    }
}

private struct NearbyDiscoveryLifecycle: ViewModifier {
    @Environment(NearbyDiscovery.self) private var discovery
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: settings.settings.discoverNearby) {
                if settings.settings.discoverNearby {
                    discovery.start()
                } else {
                    discovery.stop()
                    store.syncDiscovered([])
                }
            }
            .onChange(of: discovery.computers) { _, computers in
                store.syncDiscovered(computers)
            }
            .onChange(of: scenePhase) { _, phase in
                guard settings.settings.discoverNearby else { return }
                switch phase {
                case .active:
                    discovery.start()
                case .background:
                    discovery.stop()
                    store.syncDiscovered([])
                default:
                    break
                }
            }
    }
}

public extension View {
    /// Browses for nearby computers while the view's scene is active.
    func nearbyDiscoveryLifecycle() -> some View {
        modifier(NearbyDiscoveryLifecycle())
    }
}
