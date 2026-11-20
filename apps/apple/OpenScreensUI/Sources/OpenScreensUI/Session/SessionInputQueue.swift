import Foundation

/// AppKit/UIKit deliver input synchronously. A single consumer preserves that
/// order across async transport calls, including the release before Observe.
struct SessionInputQueue {
    enum Input: Sendable {
        case pointer(PointerEvent)
        case scroll(CGPoint, Int32, Int32)
        case key(RemoteKeyEvent)
        case observe(Bool)
    }

    let events: AsyncStream<Input>.Continuation

    init(session: any RemoteSessionProtocol) {
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        events = continuation
        Task {
            for await event in stream {
                switch event {
                case .pointer(let pointer): await session.sendPointer(pointer)
                case .scroll(let point, let x, let y): await session.sendScroll(at: point, stepsX: x, stepsY: y)
                case .key(let key): await session.sendKey(key)
                case .observe(let enabled): await session.setObserveMode(enabled)
                }
            }
            await session.disconnect()
        }
    }
}
