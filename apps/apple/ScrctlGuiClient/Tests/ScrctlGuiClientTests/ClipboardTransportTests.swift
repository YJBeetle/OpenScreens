import Foundation
import ScrctlGuiClient
import ScrctlGuiUI
import XCTest

final class ClipboardTransportTests: XCTestCase {
    func testStandardCutText() async throws { try await exercise(apple: false) }
    func testApplePasteboard() async throws { try await exercise(apple: true) }

    private enum ClipboardEvent: Equatable {
        case request
        case text(String)
    }

    private func nextClipboard(_ client: UniFfiRemoteSession) async throws -> ClipboardEvent {
        for await event in client.events {
            switch event {
            case .clipboard(let text): return .text(text)
            case .clipboardRequest: return .request
            case .failure(let message): throw NSError(domain: message, code: 1)
            case .state(.disconnected): throw POSIXError(.ECONNRESET)
            default: continue
            }
        }
        throw POSIXError(.ECONNRESET)
    }

    private func exercise(apple: Bool) async throws {
        let listener = try LoopbackListener()
        let server = Task.detached {
            try listener.accept { peer in try Self.serve(peer, apple: apple) }
        }
        let client = UniFfiRemoteSession()
        let profile = ConnectionProfile(
            name: "Fixture", host: "127.0.0.1", port: listener.port,
            controls: ControlPreferences(sharedClipboard: false)
        )
        let original = apple ? "世界🙂\r\ne\u{301}" : "Café\r\n£"
        do {
            try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
            try await client.sendClipboard(original, automatic: false)
            let requested = try await client.requestClipboard()
            XCTAssertEqual(requested, apple)
            let initial = try await nextClipboard(client)
            XCTAssertEqual(initial, .text(apple ? original : "Café\n£"))
            if !apple {
                do {
                    try await client.sendClipboard("世界🙂", automatic: false)
                    XCTFail("Expected an encoding error")
                } catch let error as RemoteSessionFailure {
                    XCTAssertEqual(error.kind, .invalidInput)
                }
            }
            try await client.setClipboardSharing(true)
            if apple {
                let request = try await nextClipboard(client)
                XCTAssertEqual(request, .request)
            }
            try await client.sendClipboard("sync", automatic: true)
            let reflected = try await nextClipboard(client)
            XCTAssertEqual(reflected, .text("sync"))
            try await client.sendClipboard("sync", automatic: true)
            try await client.sendClipboard("done", automatic: false)
            await client.setObserveMode(true)
            for automatic in [false, true] {
                do {
                    try await client.sendClipboard("blocked", automatic: automatic)
                    XCTFail("Observing allowed a clipboard send")
                } catch RemoteTransferError.notConnected {}
            }
            let last = try await nextClipboard(client)
            XCTAssertEqual(last, .text("done"))
        } catch {
            await client.disconnect()
            try await server.value
            throw error
        }
        await client.disconnect()
        try await server.value
    }

    private static func serve(_ peer: RFBTestPeer, apple: Bool) throws {
        func expectSharing(_ on: Bool) throws {
            if apple { XCTAssertEqual(try peer.read(8), Data([21, 0, 0, on ? 1 : 2, 0, 0, 0, 0])) }
        }
        func readMessage() throws -> Data {
            let header = try peer.read(apple ? 16 : 8)
            XCTAssertEqual(header.first, apple ? 31 : 6)
            let length = header.suffix(4).reduce(0) { $0 * 256 + Int($1) }
            guard length <= 4096 else { throw POSIXError(.EMSGSIZE) }
            return try header + peer.read(length)
        }
        func reflect(_ message: Data) throws {
            var push = message
            if !apple { push[0] = 3 }
            try peer.handle.write(contentsOf: push)
        }
        func request() throws {
            if apple { try peer.handle.write(contentsOf: Data([20, 0, 4, 0, 4, 0, 1, 2])) }
        }
        try peer.handshake(apple: apple)
        try expectSharing(false)
        let first = try readMessage()
        if apple {
            XCTAssertEqual(try peer.read(8).first, 11)
        } else {
            XCTAssertEqual(Data(first.dropFirst(8)), Data([67, 97, 102, 233, 10, 163]))
        }
        try reflect(first)
        try expectSharing(true)
        try request()
        try reflect(readMessage())
        let done = try readMessage()
        try expectSharing(false)
        try request()
        try reflect(done)
        peer.expectEOF()
    }
}
