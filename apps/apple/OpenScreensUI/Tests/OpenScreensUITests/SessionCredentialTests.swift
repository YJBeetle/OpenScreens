import Metal
import OpenScreensCanvas
import XCTest
@testable import OpenScreensUI

@MainActor
final class SessionCredentialTests: XCTestCase {
    func testCredentialRetryAndMacSessionChoiceSurviveReconnectWithoutSaving() async throws {
        let service = LoginService()
        var profile = ConnectionProfile(name: "Test", host: "localhost")
        profile.disconnectAction = .lockScreen
        let model = SessionViewModel(profile: profile, service: service)
        defer { model.stop() }

        model.scheduleViewportUpdate(in: CGSize(width: 320, height: 640), screenPixelWidth: 960)
        model.start()
        try await wait { model.credentialChallenge == .missingUsername }
        model.reconnect()
        XCTAssertEqual(model.credentialChallenge, .missingUsername)
        model.submitCredentials(username: "guest", password: "wrong", remember: true)
        try await wait { model.credentialChallenge == .authenticationFailed }
        XCTAssertEqual(model.loginUsername, "guest")

        model.submitCredentials(username: "user", password: " test ", remember: false)
        try await wait { model.needsMacSessionChoice }
        model.reconnect()
        XCTAssertTrue(model.needsMacSessionChoice)
        model.chooseMacSession(.personal)
        try await wait { model.state.isConnected }
        try await wait { model.receivedFrames == 2 }
        #if DEBUG
        let diagnosticsRequested = ProcessInfo.processInfo.environment["OPENSCREENS_FIRST_FRAME_DIAGNOSTICS"] == "1"
        XCTAssertEqual(model.firstUpdateHasColor, diagnosticsRequested ? true : nil)
        XCTAssertEqual(model.renderer.presentation != nil, diagnosticsRequested)
        #endif
        XCTAssertEqual(model.frameSize, CGSize(width: 2, height: 2))
        if MTLCreateSystemDefaultDevice() != nil {
            let image = try XCTUnwrap(model.renderer.snapshot())
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertEqual(bytes, Data([0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 255, 1, 0, 0, 0]))
        }
        XCTAssertFalse(model.rememberLogin)
        XCTAssertTrue(model.requestDisconnectConfirmation())
        let staleRequest = try XCTUnwrap(model.disconnectRequest)
        let transport = await service.log.latest
        await service.log.failNextHandshakes([.connectionRefused, .network])
        transport?.yield(.state(.disconnected(reason: "network")))
        try await wait { if case .reconnecting = model.state { return true }; return false }
        try await wait(timeout: .seconds(9)) { model.state.isConnected }
        let count = await service.log.accepted
        XCTAssertEqual(count, 2)
        XCTAssertFalse(model.confirmDisconnect(staleRequest))

        model.stop()
        model.start()
        try await wait { model.credentialChallenge == .missingUsername }
        XCTAssertEqual(model.loginUsername, "")
        model.disconnect()
        XCTAssertNil(model.credentialChallenge)
    }

    #if DEBUG
    func testBlackUpdateIgnoresAlphaAndFindsOneColoredPixel() {
        let black = Data([0, 0, 0, 255, 0, 0, 0, 0])
        XCTAssertFalse(SessionViewModel.containsNonblackPixel(black))
        XCTAssertTrue(SessionViewModel.containsNonblackPixel(black + Data([0, 1, 0, 0])))
    }
    #endif

    func testAutomaticReconnectStopsAfterThreeFailedHandshakes() async throws {
        let service = LoginService()
        let model = SessionViewModel(profile: ConnectionProfile(name: "Test", host: "localhost"), service: service)
        defer { model.stop() }

        try await establishSession(model)
        let transport = await service.log.latest
        let before = await service.log.handshakes
        await service.log.failNextHandshakes([.network, .network, .connectionRefused])
        transport?.yield(.state(.disconnected(reason: "network")))
        try await wait(timeout: .seconds(9)) {
            if case .disconnected(_, .connectionRefused) = model.state { return true }
            return false
        }
        let after = await service.log.handshakes
        XCTAssertEqual(after - before, 3)
        model.reconnect()
        try await wait { model.state.isConnected }
    }

    func testRecoveryPausesForInteractionAndExplicitDisconnectCancelsPendingRetry() async throws {
        let service = LoginService()
        let model = SessionViewModel(profile: ConnectionProfile(name: "Test", host: "localhost"), service: service)
        defer { model.stop() }
        try await establishSession(model)

        let first = await service.log.latest
        await service.log.failNextHandshakes([.macSessionChoiceRequired])
        first?.yield(.state(.disconnected(reason: "network")))
        try await wait { model.needsMacSessionChoice }
        try await verifyNoFurtherHandshakes(service)
        model.chooseMacSession(.personal)
        try await wait { model.state.isConnected }

        let second = await service.log.latest
        await service.log.failNextHandshakes([.authenticationFailed])
        second?.yield(.state(.disconnected(reason: "network")))
        try await wait { model.credentialChallenge == .authenticationFailed }
        try await verifyNoFurtherHandshakes(service)
        model.submitCredentials(username: "user", password: " test ", remember: false)
        try await wait { model.state.isConnected }

        let third = await service.log.latest
        await service.log.failNextHandshakes([.network])
        third?.yield(.state(.disconnected(reason: "network")))
        try await wait { model.state == .reconnecting(attempt: 2) }
        model.disconnect()
        try await verifyNoFurtherHandshakes(service)
    }

    func testFirstNetworkFailureWaitsForUser() async throws {
        let service = LoginService()
        let model = SessionViewModel(profile: ConnectionProfile(name: "Test", host: "localhost"), service: service)
        defer { model.stop() }

        await service.log.failNextHandshakes([.connectionRefused])
        model.start()
        try await wait { model.state.isTerminal }
        try await verifyNoFurtherHandshakes(service)
        let count = await service.log.handshakes
        XCTAssertEqual(count, 1)
    }

    private func verifyNoFurtherHandshakes(_ service: LoginService) async throws {
        let before = await service.log.handshakes
        try await Task.sleep(for: .milliseconds(2250))
        let after = await service.log.handshakes
        XCTAssertEqual(before, after)
    }

    private func establishSession(_ model: SessionViewModel) async throws {
        model.start()
        try await wait { model.credentialChallenge == .missingUsername }
        model.submitCredentials(username: "user", password: " test ", remember: false)
        try await wait { model.needsMacSessionChoice }
        model.chooseMacSession(.personal)
        try await wait { model.state.isConnected }
    }

    private func wait(timeout: Duration = .seconds(5), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "SessionCredentialTests.Timeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor LoginLog {
    var latest: AsyncStream<RemoteSessionEvent>.Continuation?
    var accepted = 0
    var handshakes = 0
    private var failures: [RemoteFailureKind] = []

    func failNextHandshakes(_ failures: [RemoteFailureKind]) {
        self.failures = failures
    }

    func beginHandshake() throws {
        handshakes += 1
        if !failures.isEmpty {
            throw RemoteSessionFailure(kind: failures.removeFirst(), reason: "scripted handshake failure")
        }
    }

    func connected(_ stream: AsyncStream<RemoteSessionEvent>.Continuation) {
        latest = stream
        accepted += 1
    }
}

private struct LoginService: RemoteSessionService {
    let log = LoginLog()
    func makeSession() -> any RemoteSessionProtocol { LoginTransport(log: log) }
}

private struct LoginTransport: RemoteSessionProtocol {
    let log: LoginLog
    let events: AsyncStream<RemoteSessionEvent>
    let stream: AsyncStream<RemoteSessionEvent>.Continuation

    init(log: LoginLog) {
        self.log = log
        (events, stream) = AsyncStream.makeStream(of: RemoteSessionEvent.self)
    }

    func selectDisplay(_ id: Int?) async throws {}
    func connect(profile: ConnectionProfile, password: String?, macSessionChoice: MacSessionChoice?) async throws {
        stream.yield(.state(.connecting))
        try await log.beginHandshake()
        guard !profile.username.isEmpty else { throw RemoteSessionFailure(kind: .missingUsername, reason: "") }
        guard profile.username == "user", password == " test " else {
            throw RemoteSessionFailure(kind: .authenticationFailed, reason: "")
        }
        guard macSessionChoice == .personal else {
            throw RemoteSessionFailure(kind: .macSessionChoiceRequired, reason: "")
        }
        await log.connected(stream)
        stream.yield(.displays([RemoteDisplay(id: 0, name: "Fixture", width: 2, height: 2)]))
        stream.yield(.state(.connected))
    }

    func setViewport(_ normalizedRect: CGRect?, screenPixelWidth: Int) async {
        guard normalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1),
              screenPixelWidth == 960 else { return }
        for row in 0..<2 {
            let region = RemoteRegion(x: 0, y: row, width: 2, height: 1)
            // Transparent/opaque black in the first damage rect, colour in the second.
            let pixels = Data([0, 0, 0, 255, UInt8(row), 0, 0, 0])
            stream.yield(.frame(RemoteFrame(width: 2, height: 2, region: region, data: pixels, sequence: 1)))
        }
    }

    func disconnect() async { stream.finish() }
    func sendPointer(_ event: PointerEvent) async {}
    func sendKey(_ event: RemoteKeyEvent) async {
        XCTFail("A credential, retry or teardown path sent a remote key")
    }
    func setClipboardSharing(_ enabled: Bool) async {}
    func sendClipboard(_ text: String, automatic: Bool) async {}
    func requestClipboard() async -> Bool { false }
    func setObserveMode(_ observing: Bool) async {}
}
