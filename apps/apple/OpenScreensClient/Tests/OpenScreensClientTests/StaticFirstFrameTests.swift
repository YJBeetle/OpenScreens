import Foundation
import Metal
import OpenScreensClient
import OpenScreensUI
import XCTest

/// Loopback Apple RFB peer with no capture source, input, or periodic frames.
/// Each metadata batch consumes one request. A stationary peer can satisfy an
/// incremental request by waiting indefinitely for the desktop to change.
final class StaticFirstFrameTests: XCTestCase {
    @MainActor
    func testStaticDesktopAcrossReconnectsAndSparseDamage() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Requires a Metal texture for readback")
        let listener = try LoopbackListener()
        var profile = ConnectionProfile(name: "Static fixture", host: "127.0.0.1", port: listener.port)
        profile.controls.autoReconnect = false
        let model = SessionViewModel(profile: profile, service: UniFfiSessionService())
        defer { model.stop() }

        let layout = Self.layoutRectangle
        let table = Self.tableRectangle
        let black = Data([0, 0, 0, 255])
        let pattern = Data([0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255])
        let blackFrame = black + black + black + black
        let scenarios = [
            ([[layout, table]], Self.rawRectangle(width: 2, height: 2, pixels: blackFrame), blackFrame),
            ([[layout], [table]], Self.whiteDCTRectangle, Data(repeating: 255, count: 16)),
            ([[table], [layout]], Self.rawRectangle(width: 2, height: 2, pixels: pattern), pattern)
        ]
        for (attempt, (metadata, firstRectangle, pixels)) in scenarios.enumerated() {
            if attempt == 0 { model.start() } else { model.reconnect() }
            let peer = try await Task.detached { try Self.acceptAppleClient(listener) }.value
            try await Self.expectRequest(peer, incremental: false)
            for rectangles in metadata {
                try peer.write(contentsOf: Self.update(rectangles))
                try await Self.expectRequest(peer, incremental: false)
            }
            try await wait { model.state.isConnected && model.displays.count == 1 }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.receivedFrames, 0)
            XCTAssertNil(model.renderer.snapshot(), "Metadata and an old session's texture cannot supply the baseline")

            try peer.write(contentsOf: Self.update([firstRectangle]))
            try await Self.expectRequest(peer, incremental: true)
            try await wait { model.receivedFrames == 1 }
            XCTAssertEqual(try textureBytes(model), pixels)

            if attempt == 2 {
                let patch = Self.rawRectangle(x: 1, y: 1, width: 1, height: 1, pixels: black)
                try peer.write(contentsOf: Self.update([patch]))
                try await Self.expectRequest(peer, incremental: true)
                try await wait { model.receivedFrames == 2 }
                XCTAssertEqual(try textureBytes(model), Data(pattern.prefix(12)) + black)
            }
            try peer.close()
            try await wait { model.state.isTerminal }
        }
    }

    @MainActor
    func testZoomKeepsReceivingIncrementalDesktopDamage() async throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Requires Metal for texture readback")
        let listener = try LoopbackListener()
        var profile = ConnectionProfile(name: "Zoom fixture", host: "127.0.0.1", port: listener.port)
        profile.controls.autoReconnect = false
        let model = SessionViewModel(profile: profile, service: UniFfiSessionService())
        defer { model.stop() }

        model.start()
        let peer = try await Task.detached { try Self.acceptAppleClient(listener, side: 240) }.value
        defer { try? peer.close() }
        try await Self.expectRequest(peer, incremental: false, side: 240)
        let initial = Self.update([Self.rawRectangle(width: 240, height: 240, pixels: Data(repeating: 255, count: 240 * 240 * 4))])
        try peer.write(contentsOf: initial)
        try await Self.expectRequest(peer, incremental: true, side: 240)
        try await wait { model.receivedFrames == 1 }

        let size = CGSize(width: 240, height: 240)
        let center = CGPoint(x: 120, y: 120)
        model.applyPinch(scale: 4, startZoom: 1, startPan: .zero, startFocal: center, currentFocal: center, in: size)
        model.scheduleViewportUpdate(in: size, screenPixelWidth: 240)
        try await Self.expectRequest(peer, incremental: false, side: 240)
        // A sparse update can arrive while the full refresh is still pending.
        let patch = Self.rawRectangle(x: 120, y: 120, width: 1, height: 1, pixels: Data([0, 255, 0, 255]))
        try peer.write(contentsOf: Self.update([patch]))
        try await Self.expectRequest(peer, incremental: true, side: 240)
        try await wait { model.viewport != nil && model.receivedFrames == 2 }
        let viewport = try XCTUnwrap(model.viewport)
        XCTAssertLessThan(viewport.width, 240, "Keep the local zoom crop")
        XCTAssertEqual(viewport.scale, 1)
        let baseline = try XCTUnwrap(model.renderer.snapshot())
        XCTAssertEqual(baseline.width, viewport.bufferWidth)
        XCTAssertEqual(baseline.height, viewport.bufferHeight)
        let baselineBytes = try XCTUnwrap(baseline.dataProvider?.data) as Data
        XCTAssertEqual(Data(baselineBytes.prefix(4)), Data(repeating: 255, count: 4))

        // Verify a second pixel update without another zoom or pan.
        for (index, pixel) in [Data([0, 0, 0, 255]), Data([0, 0, 255, 255])].enumerated() {
            let patch = Self.rawRectangle(x: 120, y: 120, width: 1, height: 1, pixels: pixel)
            try peer.write(contentsOf: Self.update([patch]))
            try await Self.expectRequest(peer, incremental: true, side: 240)
            try await wait { model.receivedFrames == 3 + index }
            let image = try XCTUnwrap(model.renderer.snapshot())
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            let offset = (120 - viewport.y) * image.bytesPerRow + (120 - viewport.x) * 4
            XCTAssertEqual(bytes.subdata(in: offset..<(offset + 4)), pixel)
        }
    }

    @MainActor
    private func textureBytes(_ model: SessionViewModel) throws -> Data {
        let image = try XCTUnwrap(model.renderer.snapshot())
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    @MainActor
    private func wait(until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static let pixelFormat = Data([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])

    private static func acceptAppleClient(_ listener: LoopbackListener, side: UInt8 = 2) throws -> FileHandle {
        let peer = try listener.accept()
        let version = Data("RFB 003.889\n".utf8)
        try peer.write(contentsOf: version)
        XCTAssertEqual(try peer.readExactly(12), version)
        try peer.write(contentsOf: Data([1, 1]))
        XCTAssertEqual(try peer.readExactly(1), Data([1]))
        try peer.write(contentsOf: Data([0, 0, 0, 0]))
        XCTAssertEqual(try peer.readExactly(1), Data([0xc1]))
        try peer.write(contentsOf: Data([0, side, 0, side]) + pixelFormat + Data([0, 0, 0, 0]))
        XCTAssertEqual(try peer.readExactly(66).first, 0x21)
        XCTAssertEqual(try peer.readExactly(20).first, 0)
        let header = try peer.readExactly(4)
        XCTAssertEqual(header.first, 2)
        _ = try peer.readExactly(4 * (Int(header[2]) * 256 + Int(header[3])))
        return peer
    }

    private static func expectRequest(_ peer: FileHandle, incremental: Bool, side: UInt8 = 2) async throws {
        let bytes = try await Task.detached { try peer.readExactly(10) }.value
        let expected = Data([3, incremental ? 1 : 0, 0, 0, 0, 0, 0, side, 0, side])
        guard bytes == expected else {
            XCTFail("Expected request \(Array(expected)), got \(Array(bytes))")
            throw POSIXError(.EPROTO)
        }
    }

    private static func update(_ rectangles: [Data]) -> Data {
        rectangles.reduce(Data([0, 0, 0, UInt8(rectangles.count)]), +)
    }

    private static func rawRectangle(x: UInt8 = 0, y: UInt8 = 0, width: UInt8, height: UInt8, pixels: Data) -> Data {
        Data([0, x, 0, y, 0, width, 0, height, 0, 0, 0, 0]) + pixels
    }

    // Apple DesktopInfo (1101), one 2x2 display with id 1.
    private static let layoutRectangle = Data([
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 77,
        0, 2, 0, 2, 0, 0, 0, 0, 0, 1,
        0, 0, 0, 1, 0, 2, 0, 2, 0, 0, 0, 0
    ]) + pixelFormat

    // Adaptive DCT type 0, coefficient offset 7, command 0 fills one white tile.
    private static let whiteDCTRectangle = Data([
        0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 3, 243, 0, 0, 0, 7,
        0, 15, 25, 0, 0, 7, 0
    ])

    // Apple Adaptive DCT (1011), type 2 updates two 64-entry quantisation tables.
    private static let tableRectangle = Data([
        0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 3, 243, 0, 0, 0, 129, 2
    ]) + Data(repeating: 1, count: 128)
}
