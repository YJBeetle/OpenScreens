import XCTest
@testable import OpenScreensUI

final class DisconnectActionTests: XCTestCase {
    func testLegacyUnsupportedAndUnknownActionsDefaultToNone() throws {
        var profile = ConnectionProfile(platform: .macos)
        let legacy = try JSONEncoder().encode(profile)
        let decode = { try JSONDecoder().decode(ConnectionProfile.self, from: $0) }
        XCTAssertEqual(try decode(legacy).supportedDisconnectAction, .none)
        profile.disconnectAction = .lockScreen
        XCTAssertEqual(try decode(JSONEncoder().encode(profile)).supportedDisconnectAction, .lockScreen)
        profile.platform = .linux
        XCTAssertEqual(profile.supportedDisconnectAction, .none)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["disconnectAction"] = "future-action"
        XCTAssertEqual(try decode(JSONSerialization.data(withJSONObject: object)).supportedDisconnectAction, .none)
    }
}
