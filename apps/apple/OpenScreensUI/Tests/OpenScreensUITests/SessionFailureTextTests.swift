import XCTest
@testable import OpenScreensUI

final class SessionFailureTextTests: XCTestCase {
    func testMissingPasswordIsLocalized() {
        XCTAssertEqual(
            SessionFailureText.localized(
                .missingPassword,
                reason: "handshake failed: server requires authentication but no password is configured"
            ),
            "The server requires authentication, but no password is configured."
        )
    }

    func testMissingUsernameIsLocalized() {
        XCTAssertEqual(
            SessionFailureText.localized(
                .missingUsername,
                reason: "handshake failed: server requires Apple authentication but no username is configured"
            ),
            "The server requires Apple authentication, but no username is configured."
        )
    }

    func testTransportFailuresAreLocalized() {
        XCTAssertEqual(
            SessionFailureText.localized(.tunnel, reason: "tunnel failed: no route"),
            "The tunnel connection failed."
        )
        XCTAssertEqual(
            SessionFailureText.localized(.decode, reason: "decode failed: InvalidData"),
            "The remote screen data could not be decoded."
        )
        XCTAssertEqual(
            SessionFailureText.localized(.closed, reason: "connection closed"),
            "The connection was closed."
        )
    }

    func testUnknownKindKeepsReason() {
        let reason = "The remote computer ended the session."
        XCTAssertEqual(SessionFailureText.localized(.unknown, reason: reason), reason)
    }
}
