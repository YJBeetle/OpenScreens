import XCTest
@testable import OpenScreensUI

private actor ClipboardTransport: RemoteSessionProtocol, RemoteSessionService {
    nonisolated let events: AsyncStream<RemoteSessionEvent>
    nonisolated let output: AsyncStream<RemoteSessionEvent>.Continuation
    let pull: Bool
    private(set) var sent: [String] = []
    private(set) var requests = 0

    init(pull: Bool) {
        (events, output) = AsyncStream.makeStream()
        self.pull = pull
    }

    nonisolated func makeSession() -> any RemoteSessionProtocol { self }
    func selectDisplay(_ id: Int?) async throws {}
    func connect(profile: ConnectionProfile, password: String?, macSessionChoice: MacSessionChoice?) async throws { output.yield(.state(.connected)) }
    func disconnect() async { output.finish() }
    func sendPointer(_ event: PointerEvent) async {}
    func sendKey(_ event: RemoteKeyEvent) async {}
    func setObserveMode(_ observing: Bool) async {}
    func setClipboardSharing(_ enabled: Bool) async {}
    func sendClipboard(_ text: String, automatic: Bool) async { sent.append(text) }
    func requestClipboard() async -> Bool {
        requests += 1
        return pull
    }
}

@MainActor
final class SessionClipboardTests: XCTestCase {
    private func waitFor(_ predicate: () async -> Bool, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            if ContinuousClock.now >= deadline {
                XCTFail("Session did not reach the expected state", line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPrivatePushOnlySessionPreservesManualActions() async throws {
        let session = ClipboardTransport(pull: false)
        var local = "local"
        var reads = 0
        let model = SessionViewModel(
            profile: ConnectionProfile(controls: ControlPreferences(sharedClipboard: false)),
            service: session,
            readClipboard: { reads += 1; return local },
            writeClipboard: { local = $0 }
        )
        model.start()
        defer { model.stop() }
        try await waitFor { model.state.isConnected }

        model.fetchRemoteClipboard()
        try await waitFor { model.clipboardMessage == "Copy text on the remote computer first." }
        session.output.yield(.clipboard("remote"))
        session.output.yield(.clipboardRequest)
        session.output.yield(.pointerPosition(x: 0.25, y: 0.25))
        try await waitFor { model.remoteCursor.x == 0.25 }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(local, "local")

        model.sendLocalClipboard()
        try await waitFor { await session.sent == ["local"] }
        model.fetchRemoteClipboard()
        try await waitFor { local == "remote" }
        XCTAssertEqual(reads, 1)
    }

    func testManualPullWhilePrivateAcceptsOnlyOnePush() async throws {
        let session = ClipboardTransport(pull: true)
        var writes: [String] = []
        let model = SessionViewModel(
            profile: ConnectionProfile(), service: session,
            readClipboard: { "local change" }, writeClipboard: { writes.append($0) }
        )
        model.start()
        defer { model.stop() }
        try await waitFor { model.state.isConnected }
        session.output.yield(.clipboard("shared"))
        session.output.yield(.clipboardRequest)
        try await waitFor { await session.sent == ["local change"] }
        XCTAssertEqual(writes, ["shared"])

        model.setClipboardSharing(false)
        model.fetchRemoteClipboard()
        try await waitFor { await session.requests == 1 }
        session.output.yield(.clipboard("requested"))
        session.output.yield(.clipboard("unsolicited"))
        session.output.yield(.pointerPosition(x: 0.25, y: 0.25))
        try await waitFor { model.remoteCursor.x == 0.25 }
        XCTAssertEqual(writes, ["shared", "requested"])
    }
}
