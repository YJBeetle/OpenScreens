import CoreGraphics

enum TrackpadTwoFingerMode {
    case scroll
    case pinch

    static func recognize(translation: CGFloat, spanChange: CGFloat) -> Self? {
        // Allow some span drift as the fingers move together. The added margin
        // also gives a briefly lagging finger time to catch up.
        if spanChange >= max(6, translation * 1.5 + 3) {
            return .pinch
        }
        if translation >= 6 {
            return .scroll
        }
        return nil
    }
}
