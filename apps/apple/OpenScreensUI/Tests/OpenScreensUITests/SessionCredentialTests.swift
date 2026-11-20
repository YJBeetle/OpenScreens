import Metal
import OpenScreensCanvas
import XCTest
@testable import OpenScreensUI

@MainActor
final class SessionCredentialTests: XCTestCase {
    func testRejectedAttemptCanBeCorrectedAndReconnectedWithoutSaving() async throws {
        let service = LoginService()
        let profile = ConnectionProfile(name: "Test", host: "localhost")
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
        try await wait { model.state.isConnected }
        try await wait { model.receivedFrames == 2 }
        #if DEBUG
        XCTAssertEqual(model.firstUpdateHasColor, true)
        #endif
        XCTAssertEqual(model.frameSize, CGSize(width: 2, height: 2))
        if MTLCreateSystemDefaultDevice() != nil {
            let image = try XCTUnwrap(model.renderer.snapshot())
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertEqual(bytes, Data([0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 255, 1, 0, 0, 0]))
        }
        XCTAssertFalse(model.rememberLogin)
        let transport = await service.log.latest
        transport?.yield(.state(.disconnected(reason: "network")))
        try await wait { if case .reconnecting = model.state { return true }; return false }
        try await wait { model.state.isConnected }
        let count = await service.log.accepted
        XCTAssertEqual(count, 2)

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

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
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

    func connect(profile: ConnectionProfile, password: String?) async throws {
        guard !profile.username.isEmpty else { throw RemoteSessionFailure(kind: .missingUsername, reason: "") }
        guard profile.username == "user", password == " test " else {
            throw RemoteSessionFailure(kind: .authenticationFailed, reason: "")
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
    func sendKey(_ event: RemoteKeyEvent) async {}
    func sendClipboard(_ text: String) async {}
    func requestClipboard() async {}
    func setObserveMode(_ observing: Bool) async {}
}
