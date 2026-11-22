import XCTest
@testable import ScrctlGuiUI

private actor ClipboardTransport: RemoteSessionProtocol, RemoteSessionService {
    nonisolated let events: AsyncStream<RemoteSessionEvent>
    nonisolated let output: AsyncStream<RemoteSessionEvent>.Continuation
    let pull: Bool
    private(set) var sent: [String] = []
    private(set) var requests = 0

    private var pausedRequest: CheckedContinuation<Bool, Never>?
    private let pauseFirstRequest: Bool

    init(pull: Bool, pauseFirstRequest: Bool = false) {
        self.pauseFirstRequest = pauseFirstRequest
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
        if pauseFirstRequest && requests == 1 {
            return await withCheckedContinuation { pausedRequest = $0 }
        }
        return pull
    }

    func finishFirstRequest() {
        pausedRequest?.resume(returning: pull)
        pausedRequest = nil
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

    func testManualPullExpiresWhenSceneBecomesInactive() async throws {
        let session = ClipboardTransport(pull: true)
        var local = "original"
        let model = SessionViewModel(
            profile: ConnectionProfile(controls: ControlPreferences(sharedClipboard: false)), service: session,
            readClipboardChangeCount: { 0 }, readClipboard: { nil }, writeClipboard: { local = $0 }
        )
        model.start()
        defer { model.stop() }
        try await waitFor { model.state.isConnected }
        model.fetchRemoteClipboard()
        try await waitFor { await session.requests == 1 }
        model.handleScenePhase(.inactive)
        local = "copied elsewhere"
        session.output.yield(.clipboard("late reply"))
        session.output.yield(.pointerPosition(x: 0.25, y: 0.25))
        try await waitFor { model.remoteCursor.x == 0.25 }
        XCTAssertEqual(local, "copied elsewhere")

        model.fetchRemoteClipboard() // An inactive scene cannot start a new fetch.
        model.handleScenePhase(.active)
        session.output.yield(.clipboard("unsolicited after return"))
        session.output.yield(.pointerPosition(x: 0.75, y: 0.75))
        try await waitFor { model.remoteCursor.x == 0.75 }
        XCTAssertEqual(local, "copied elsewhere")
        model.fetchRemoteClipboard()
        try await waitFor { await session.requests >= 2 }
        session.output.yield(.clipboard("fresh reply"))
        try await waitFor { local == "fresh reply" }
        let count = await session.requests
        XCTAssertEqual(count, 2)
    }

    func testCachedFallbackCannotCompleteAfterLeavingAndReturning() async throws {
        let session = ClipboardTransport(pull: false, pauseFirstRequest: true)
        var local = "original"
        let unexpectedWrite = expectation(description: "Expired fallback wrote the clipboard")
        unexpectedWrite.isInverted = true
        let model = SessionViewModel(
            profile: ConnectionProfile(controls: ControlPreferences(sharedClipboard: false)), service: session,
            readClipboardChangeCount: { 0 }, readClipboard: { nil }, writeClipboard: {
                if $0 == "cached before leaving" { unexpectedWrite.fulfill() }
                local = $0
            }
        )
        model.start()
        defer { model.stop() }
        try await waitFor { model.state.isConnected }
        session.output.yield(.clipboard("cached before leaving"))
        session.output.yield(.pointerPosition(x: 0.25, y: 0.25))
        try await waitFor { model.remoteCursor.x == 0.25 }
        model.fetchRemoteClipboard()
        try await waitFor { await session.requests == 1 }
        model.handleScenePhase(.background)
        local = "copied elsewhere"
        model.handleScenePhase(.active)
        await session.finishFirstRequest()
        await fulfillment(of: [unexpectedWrite], timeout: 0.2)
        XCTAssertEqual(local, "copied elsewhere")

        session.output.yield(.clipboard("fresh cached text"))
        session.output.yield(.pointerPosition(x: 0.75, y: 0.75))
        try await waitFor { model.remoteCursor.x == 0.75 }
        model.fetchRemoteClipboard()
        try await waitFor { local == "fresh cached text" }
    }

    func testPrivatePushOnlySessionPreservesManualActions() async throws {
        let session = ClipboardTransport(pull: false)
        var local = "local"
        var reads = 0
        let model = SessionViewModel(
            profile: ConnectionProfile(controls: ControlPreferences(sharedClipboard: false)),
            service: session,
            readClipboardChangeCount: { 0 },
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

    func testManualSendReportsUnreadableLocalClipboardText() async throws {
        for text: String? in [nil, ""] {
            let session = ClipboardTransport(pull: false)
            let model = SessionViewModel(
                profile: ConnectionProfile(), service: session,
                readClipboardChangeCount: { 0 }, readClipboard: { text }, writeClipboard: { _ in }
            )
            model.start()
            defer { model.stop() }
            try await waitFor { model.state.isConnected }

            model.sendLocalClipboard()
            XCTAssertEqual(
                model.clipboardMessage,
                "The local clipboard has no readable text, or clipboard access is unavailable."
            )
            let sent = await session.sent
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testObservingAllowsManualFetchWithoutReadingLocalText() async throws {
        let session = ClipboardTransport(pull: true)
        var local = "local"
        let model = SessionViewModel(
            profile: ConnectionProfile(controls: ControlPreferences(startInObserveMode: true)),
            service: session,
            readClipboardChangeCount: { 0 },
            readClipboard: { XCTFail("Observing read local text"); return local },
            writeClipboard: { local = $0 }
        )
        model.start()
        defer { model.stop() }
        try await waitFor { model.state.isConnected }
        model.sendLocalClipboard()
        await model.watchLocalClipboard()
        session.output.yield(.clipboardRequest)
        model.fetchRemoteClipboard()
        try await waitFor { await session.requests == 1 }
        session.output.yield(.clipboard("requested"))
        try await waitFor { local == "requested" }
        let sent = await session.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualPullWhilePrivateAcceptsOnlyOnePush() async throws {
        let session = ClipboardTransport(pull: true)
        var writes: [String] = []
        let model = SessionViewModel(
            profile: ConnectionProfile(), service: session,
            readClipboardChangeCount: { 0 },
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
