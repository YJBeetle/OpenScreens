import Darwin
import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class DisconnectTests: XCTestCase {
    func testDisconnectDrainsKeyReleaseAndClosesIdleTCPPeer() async throws {
        let listener = try LoopbackListener()
        let peer = Task.detached { try Self.serve(listener) }
        let client = UniFfiRemoteSession()
        let profile = ConnectionProfile(
            name: "Loopback", host: "127.0.0.1", port: listener.port
        )
        try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        await client.sendKey(RemoteKeyEvent(key: .text("a")))
        await client.disconnect()
        try await peer.value
        // The peer must receive FIN while the client object and process are still alive.
        await client.disconnect()
    }

    func testClientDisconnectClosesPendingHandshake() async throws {
        try await checkPendingHandshake(cancelTask: false)
    }

    func testTaskCancellationClosesPendingHandshake() async throws {
        try await checkPendingHandshake(cancelTask: true)
    }

    private func checkPendingHandshake(cancelTask: Bool) async throws {
        let listener = try LoopbackListener()
        let profile = ConnectionProfile(name: "Loopback", host: "127.0.0.1", port: listener.port)
        let client = UniFfiRemoteSession()
        let connection = Task {
            try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        }
        let peer = try await Task.detached {
            let peer = try listener.accept()
            let version = Data("RFB 003.008\n".utf8)
            try peer.write(contentsOf: version)
            XCTAssertEqual(try peer.readExactly(12), version)
            return peer
        }.value

        if cancelTask { connection.cancel() } else { await client.disconnect() }
        var byte: UInt8 = 0
        XCTAssertEqual(recv(peer.fileDescriptor, &byte, 1, 0), 0, "The server should see EOF during negotiation")
        try peer.close()
        do {
            try await connection.value
            XCTFail("A cancelled handshake should not produce a session")
        } catch is CancellationError {}
    }

    private static func serve(_ listener: LoopbackListener) throws {
        let peer = try listener.accept()
        let version = Data("RFB 003.008\n".utf8)
        try peer.write(contentsOf: version)
        XCTAssertEqual(try peer.readExactly(12), version)
        try peer.write(contentsOf: Data([1, 1])) // SecurityType None
        XCTAssertEqual(try peer.readExactly(1), Data([1]))
        try peer.write(contentsOf: Data(repeating: 0, count: 4))
        _ = try peer.readExactly(1)
        // One synthetic pixel, BGRA8888, no desktop name.
        try peer.write(contentsOf: Data([
            0, 1, 0, 1,
            32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
            0, 0, 0, 0
        ]))
        _ = try peer.readExactly(20) // SetPixelFormat
        let encodings = try peer.readExactly(4)
        _ = try peer.readExactly(4 * (Int(encodings[2]) * 256 + Int(encodings[3])))
        _ = try peer.readExactly(10) // Full update request. Stay idle to keep nextEvent suspended.
        XCTAssertEqual(try peer.readExactly(16), Data([4, 1, 0, 0, 0, 0, 0, 97, 4, 0, 0, 0, 0, 0, 0, 97]))
        var byte: UInt8 = 0
        XCTAssertEqual(recv(peer.fileDescriptor, &byte, 1, 0), 0, "Expected TCP EOF after the queued key release, errno=\(errno)")
    }
}
