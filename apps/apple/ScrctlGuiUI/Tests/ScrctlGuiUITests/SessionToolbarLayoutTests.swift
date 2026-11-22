import XCTest
@testable import ScrctlGuiUI

final class SessionToolbarLayoutTests: XCTestCase {
    func testUsesOneOrderAcrossTargetsAndOnlyOffersAvailableActions() {
        let order: [SessionToolbarItem] = [.download, .keyboard, .pointer]
        let available: [SessionToolbarItem] = [.pointer, .keyboard, .disconnect]
        let layout = SessionToolbarLayout(pinned: order, available: available)

        XCTAssertEqual(layout.pinned, [.keyboard, .pointer])
        XCTAssertEqual(layout.overflow(after: 1), [.pointer, .disconnect])

        let restored = SessionToolbarLayout(pinned: order, available: available + [.download])
        XCTAssertEqual(restored.pinned, order)
    }

    func testShowsUnpinnedActionsInMoreWithoutRepeatingPinnedItems() {
        let layout = SessionToolbarLayout(
            pinned: [.keyboard, .keyboard],
            available: [.pointer, .keyboard, .disconnect]
        )
        XCTAssertEqual(layout.pinned, [.keyboard])
        XCTAssertEqual(layout.overflow(after: 1), [.pointer, .disconnect])
        XCTAssertEqual(layout.overflow(after: 0), [.keyboard, .pointer, .disconnect])
    }

    func testRoundTripPreservesOrderAndEmptyToolbar() throws {
        for items: [SessionToolbarItem] in [[.disconnect, .commands, .download], []] {
            let settings = AppSettings(toolbarItems: items)
            let encoded = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded).toolbarItems, items)
        }
    }
}
