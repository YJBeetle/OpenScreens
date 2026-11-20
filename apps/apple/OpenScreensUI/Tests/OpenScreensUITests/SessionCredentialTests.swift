import XCTest
@testable import OpenScreensUI

@MainActor
final class SessionCredentialTests: XCTestCase {
    func testRejectedAttemptCanBeCorrectedAndReconnectedWithoutSaving() async throws {
        let service = LoginService()
        let profile = ConnectionProfile(name: "Test", host: "localhost")
        let model = SessionViewModel(profile: profile, service: service)
        defer { model.stop() }

        model.start()
        try await wait { model.credentialChallenge == .missingUsername }
        model.reconnect()
        XCTAssertEqual(model.credentialChallenge, .missingUsername)
        model.submitCredentials(username: "guest", password: "wrong", remember: true)
        try await wait { model.credentialChallenge == .authenticationFailed }
        XCTAssertEqual(model.loginUsername, "guest")

        model.submitCredentials(username: "user", password: " test ", remember: false)
        try await wait { model.state.isConnected }
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

    func selectDisplay(_ id: Int?) async throws {}
    func connect(profile: ConnectionProfile, password: String?) async throws {
        guard !profile.username.isEmpty else { throw RemoteSessionFailure(kind: .missingUsername, reason: "") }
        guard profile.username == "user", password == " test " else {
            throw RemoteSessionFailure(kind: .authenticationFailed, reason: "")
        }
        await log.connected(stream)
        stream.yield(.state(.connected))
    }

    func disconnect() async { stream.finish() }
    func sendPointer(_ event: PointerEvent) async {}
    func sendKey(_ event: RemoteKeyEvent) async {}
    func sendClipboard(_ text: String) async {}
    func requestClipboard() async {}
    func setObserveMode(_ observing: Bool) async {}
}
