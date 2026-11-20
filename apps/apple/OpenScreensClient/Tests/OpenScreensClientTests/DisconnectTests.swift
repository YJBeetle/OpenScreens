import Darwin
import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class DisconnectTests: XCTestCase {
    func testDisconnectDrainsKeyReleaseAndClosesIdleTCPPeer() async throws {
        let listener = try LoopbackListener()
        let peer = Task.detached {
            try listener.accept { peer in
                try peer.handshake()
                XCTAssertEqual(try peer.read(16), Data([4, 1, 0, 0, 0, 0, 0, 97, 4, 0, 0, 0, 0, 0, 0, 97]))
                peer.expectEOF()
            }
        }
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
}
