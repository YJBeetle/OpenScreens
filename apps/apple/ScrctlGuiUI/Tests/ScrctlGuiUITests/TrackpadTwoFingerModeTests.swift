import XCTest
@testable import ScrctlGuiUI

final class TrackpadTwoFingerModeTests: XCTestCase {
    func testParallelAndDriftingFingersScroll() {
        XCTAssertEqual(TrackpadTwoFingerMode.recognize(translation: 8, spanChange: 0), .scroll)
        XCTAssertEqual(TrackpadTwoFingerMode.recognize(translation: 8, spanChange: 7), .scroll)
    }

    func testPinchWithStableOrMovingCenter() {
        XCTAssertEqual(TrackpadTwoFingerMode.recognize(translation: 0, spanChange: 7), .pinch)
        XCTAssertEqual(TrackpadTwoFingerMode.recognize(translation: 4, spanChange: 10), .pinch)
    }

    func testPinchNeedsMoreTravelWhenOneFingerLags() {
        XCTAssertNil(TrackpadTwoFingerMode.recognize(translation: 4, spanChange: 8))
        XCTAssertEqual(TrackpadTwoFingerMode.recognize(translation: 7, spanChange: 14), .pinch)
    }

    func testSmallMovementDoesNotStartGesture() {
        XCTAssertNil(TrackpadTwoFingerMode.recognize(translation: 4, spanChange: 5))
    }
}
