import XCTest
@testable import ScrctlGuiUI

final class RemoteCommandTests: XCTestCase {
    func testCommandsUseTheRemotePlatformsChords() throws {
        let mac = RemoteDesktopCommand.commands(for: .macos)
        let windows = RemoteDesktopCommand.commands(for: .windows)
        let lock = try XCTUnwrap(mac.first { $0.title == "Lock Screen" })
        XCTAssertEqual(lock.event.key, .text("q"))
        XCTAssertEqual(lock.event.modifiers, [.control, .command])
        let attention = try XCTUnwrap(windows.first { $0.title == "Ctrl-Alt-Delete" })
        XCTAssertEqual(attention.event.key, .deleteForward)
        XCTAssertEqual(attention.event.modifiers, [.control, .option])
        XCTAssertFalse(mac.contains { $0.title == attention.title })
        XCTAssertFalse(windows.contains { $0.title == "Mission Control" })
        for platform in [RemoteOS.linux, .unix, .generic] {
            XCTAssertFalse(RemoteDesktopCommand.commands(for: platform).contains { $0.title == "Lock Screen" })
        }
    }
}
