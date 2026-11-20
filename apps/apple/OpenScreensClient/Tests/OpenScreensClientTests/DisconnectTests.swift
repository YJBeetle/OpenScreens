import Darwin
import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class DisconnectTests: XCTestCase {
    func testDisconnectDrainsKeyReleaseAndClosesIdleTCPPeer() async throws {
        let listener = try RFBTestListener()
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
}
