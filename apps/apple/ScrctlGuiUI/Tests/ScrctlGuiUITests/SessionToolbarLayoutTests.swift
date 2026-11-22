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

    func testReservesSpaceForOverflowAtTheFitBoundary() {
        let items: [SessionToolbarItem] = [.pointer, .displays, .keyboard, .disconnect]
        let layout = SessionToolbarLayout(pinned: items, available: items)
        XCTAssertEqual(layout.inlineCount(availableLength: 194, buttonSize: 44), 4)
        XCTAssertEqual(layout.inlineCount(availableLength: 193, buttonSize: 44), 2)
        XCTAssertEqual(layout.inlineCount(availableLength: 194, buttonSize: 44, requiresMore: true), 3)
        XCTAssertEqual(layout.inlineCount(availableLength: 194, buttonSize: 44, leadingLength: 12), 2)
    }

    func testRoundTripPreservesOrderAndEmptyToolbar() throws {
        for items: [SessionToolbarItem] in [[.disconnect, .commands, .download], []] {
            let settings = AppSettings(toolbarItems: items)
            let encoded = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded).toolbarItems, items)
        }
    }
}
