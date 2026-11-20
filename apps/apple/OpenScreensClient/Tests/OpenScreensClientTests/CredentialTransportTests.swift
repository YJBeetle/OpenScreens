import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class CredentialTransportTests: XCTestCase {
    func testPasswordPromptCanOverrideAnUnauthenticatedProfile() async throws {
        let listener = try LoopbackListener()
        let profile = ConnectionProfile(
            name: "Loopback", host: "127.0.0.1", port: listener.port, authentication: .none
        )
        let server = Task.detached {
            try listener.accept { peer in
                try peer.offerSecurityType(2)
                peer.expectEOF()
            }
            try listener.accept { peer in
                try peer.offerSecurityType(2)
                XCTAssertEqual(try peer.read(1), Data([2]))
                try peer.handle.write(contentsOf: Data(0..<16))
                // VNC response to the fixed challenge using the password "fixture".
                XCTAssertEqual(try peer.read(16), Data([
                    0xb6, 0xcd, 0xfe, 0xac, 0x10, 0xa6, 0xa4, 0x56,
                    0xb5, 0xd5, 0x3a, 0x16, 0x44, 0xa7, 0xa4, 0x75
                ]))
                try peer.startDesktop()
                peer.expectEOF()
            }
        }
        do {
            try await UniFfiRemoteSession().connect(profile: profile, password: nil, macSessionChoice: nil)
            XCTFail("Expected the server to require a password")
        } catch let failure as RemoteSessionFailure {
            XCTAssertEqual(failure.kind, .missingPassword)
        }
        let retry = UniFfiRemoteSession()
        try await retry.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        await retry.disconnect()
        try await server.value
    }
}
