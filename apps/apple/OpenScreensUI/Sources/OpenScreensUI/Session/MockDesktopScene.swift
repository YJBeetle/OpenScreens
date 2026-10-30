import CoreGraphics
import Foundation
import OpenScreensCanvas

/// Procedural desktop used to prove the canvas, input and session plumbing until
/// the RFB engine is wired in. It deliberately contains no external artwork.
struct MockDesktopScene {
    var width = 768
    var height = 480
    var cursor = CGPoint(x: 0.5, y: 0.55)
    var clickPoint: CGPoint?
    var clickAge: Double?
    var keyPulseAge: Double?
    var observing = false

    func fullFrame(at time: Double) -> RemoteFrame {
        RemoteFrame(
            width: width,
            height: height,
            data: render(region: nil, at: time)
        )
    }

    func regionFrame(_ region: RemoteRegion, at time: Double) -> RemoteFrame {
        RemoteFrame(
            width: width,
            height: height,
            region: region,
            data: render(region: region, at: time)
        )
    }

    private func render(region: RemoteRegion?, at time: Double) -> Data {
        let painter = MockDesktopPainter(scene: self, time: time)
        let bounds = region ?? RemoteRegion(x: 0, y: 0, width: width, height: height)
        var data = Data(count: bounds.byteCount)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let pixels = base.bindMemory(to: UInt32.self, capacity: bounds.width * bounds.height)
            var index = 0
            for y in bounds.y..<(bounds.y + bounds.height) {
                for x in bounds.x..<(bounds.x + bounds.width) {
                    pixels[index] = painter.color(x: x, y: y)
                    index += 1
                }
            }
        }
        return data
    }
}

// MARK: - Painter

private struct MockRect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func contains(_ px: Int, _ py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }
}

private struct MockRGB {
    var r: Int
    var g: Int
    var b: Int

    func mixed(with other: MockRGB, amount: Double) -> MockRGB {
        let t = min(max(amount, 0), 1)
        return MockRGB(
            r: Int(Double(r) + Double(other.r - r) * t),
            g: Int(Double(g) + Double(other.g - g) * t),
            b: Int(Double(b) + Double(other.b - b) * t)
        )
    }

    func scaled(_ factor: Double) -> MockRGB {
        mixed(with: MockRGB(r: 0, g: 0, b: 0), amount: 1 - factor)
    }

    var packed: UInt32 {
        let red = UInt32(min(max(r, 0), 255))
        let green = UInt32(min(max(g, 0), 255))
        let blue = UInt32(min(max(b, 0), 255))
        return (255 << 24) | (red << 16) | (green << 8) | blue
    }
}

private struct MockWindow {
    var frame: MockRect
    var header: MockRGB
    var hasSidebar: Bool
}

private struct MockDesktopPainter {
    let width: Int
    let height: Int
    let time: Double
    let windows: [MockWindow]
    let dock: MockRect
    let cursor: CGPoint
    let click: (point: CGPoint, age: Double)?
    let keyPulseAge: Double?
    let observing: Bool

    init(scene: MockDesktopScene, time: Double) {
        width = scene.width
        height = scene.height
        self.time = time

        let sway = sin(time * 0.35) * 9
        let counterSway = cos(time * 0.28) * 7
        let first = MockRect(
            x: Int(Double(scene.width) * 0.08 + sway),
            y: Int(Double(scene.height) * 0.16),
            width: Int(Double(scene.width) * 0.50),
            height: Int(Double(scene.height) * 0.48)
        )
        let second = MockRect(
            x: Int(Double(scene.width) * 0.57 + counterSway),
            y: Int(Double(scene.height) * 0.30),
            width: Int(Double(scene.width) * 0.34),
            height: Int(Double(scene.height) * 0.38)
        )
        windows = [
            MockWindow(frame: first, header: MockRGB(r: 54, g: 126, b: 146), hasSidebar: true),
            MockWindow(frame: second, header: MockRGB(r: 98, g: 70, b: 168), hasSidebar: false)
        ]

        dock = MockRect(
            x: scene.width / 2 - 148,
            y: scene.height - 62,
            width: 296,
            height: 46
        )

        cursor = CGPoint(
            x: scene.cursor.x * Double(scene.width),
            y: scene.cursor.y * Double(scene.height)
        )
        if let point = scene.clickPoint, let age = scene.clickAge {
            click = (CGPoint(x: point.x * Double(scene.width), y: point.y * Double(scene.height)), age)
        } else {
            click = nil
        }
        keyPulseAge = scene.keyPulseAge
        observing = scene.observing
    }

    func color(x: Int, y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0xFF000000 }
        var color = background(x: x, y: y)

        for window in windows {
            paintWindow(window, x: x, y: y, onto: &color)
        }
        paintDock(x: x, y: y, onto: &color)
        paintMenuBar(x: x, y: y, onto: &color)
        paintIndicators(x: x, y: y, onto: &color)
        paintRipple(x: x, y: y, onto: &color)
        paintCursor(x: x, y: y, onto: &color)

        return color.packed
    }

    // MARK: Background

    private func background(x: Int, y: Int) -> MockRGB {
        let nx = Double(x) / Double(max(width - 1, 1))
        let ny = Double(y) / Double(max(height - 1, 1))
        var color = MockRGB(
            r: 10 + Int(ny * 11) + Int(nx * 5),
            g: 13 + Int(ny * 13) + Int(nx * 2),
            b: 22 + Int(ny * 26) + Int(nx * 9)
        )

        let band = (x * 2 + y * 3 + Int(time * 26)) % 420
        if band < 80 {
            let amount = Double(80 - band) / 80 * 0.34
            color = color.mixed(with: MockRGB(r: 62, g: 48, b: 128), amount: amount)
        }
        if y % 4 == 0 {
            color = color.scaled(0.955)
        }
        return color
    }

    // MARK: Windows

    private func paintWindow(_ window: MockWindow, x: Int, y: Int, onto color: inout MockRGB) {
        let frame = window.frame
        let shadow = MockRect(x: frame.x + 10, y: frame.y + 13, width: frame.width + 10, height: frame.height + 10)
        if shadow.contains(x, y) && !frame.contains(x, y) {
            color = color.scaled(0.58)
            return
        }
        guard frame.contains(x, y) else { return }

        if x == frame.x || x == frame.maxX - 1 || y == frame.y || y == frame.maxY - 1 {
            color = MockRGB(r: 96, g: 104, b: 126)
            return
        }

        let headerHeight = 26
        let localX = x - frame.x
        let localY = y - frame.y

        if localY < headerHeight {
            let trafficLights = [
                MockRGB(r: 255, g: 95, b: 87),
                MockRGB(r: 254, g: 188, b: 46),
                MockRGB(r: 40, g: 200, b: 64)
            ]
            for (index, lightColor) in trafficLights.enumerated() {
                let centerX = Double(frame.x + 13 + index * 14)
                let centerY = Double(frame.y + 13)
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                if dx * dx + dy * dy <= 9 {
                    color = lightColor
                    return
                }
            }

            if localY >= 10, localY <= 14, localX >= frame.width / 2 - 34, localX <= frame.width / 2 + 34 {
                color = window.header.mixed(with: MockRGB(r: 255, g: 255, b: 255), amount: 0.38)
                return
            }

            color = localY == headerHeight - 1
                ? window.header.scaled(0.55)
                : window.header
            return
        }

        let contentY = localY - headerHeight
        color = MockRGB(r: 29, g: 32, b: 41)

        if window.hasSidebar, localX < 76 {
            color = MockRGB(r: 22, g: 25, b: 33)
            if localX == 75 {
                color = MockRGB(r: 53, g: 58, b: 74)
            }
            return
        }

        guard contentY > 12 else { return }
        let row = (contentY - 12) / 18
        let withinRow = (contentY - 12) % 18
        guard row < 10, withinRow < 5 else { return }

        let inset = window.hasSidebar ? 90 : 16
        let available = frame.width - inset - 16
        guard available > 30 else { return }
        let rowWidth = available - (row % 3) * 26
        guard localX >= inset, localX < inset + rowWidth else { return }

        color = MockRGB(r: 45, g: 50, b: 64)
        if row == 0, localX < inset + 46 {
            color = window.header.mixed(with: MockRGB(r: 255, g: 255, b: 255), amount: 0.18)
        }
    }

    // MARK: Dock

    private func paintDock(x: Int, y: Int, onto color: inout MockRGB) {
        guard dockContains(x: x, y: y) else { return }
        color = color.mixed(with: MockRGB(r: 48, g: 53, b: 70), amount: 0.86)

        if y == dock.y {
            color = MockRGB(r: 104, g: 112, b: 136)
            return
        }

        let iconColors = [
            MockRGB(r: 88, g: 148, b: 255),
            MockRGB(r: 80, g: 196, b: 140),
            MockRGB(r: 245, g: 156, b: 72),
            MockRGB(r: 226, g: 98, b: 132),
            MockRGB(r: 150, g: 118, b: 238),
            MockRGB(r: 74, g: 190, b: 206)
        ]
        let iconWidth = 30
        let gap = 10
        let totalWidth = iconColors.count * iconWidth + (iconColors.count - 1) * gap
        let startX = dock.x + (dock.width - totalWidth) / 2
        let top = dock.y + 8
        guard y >= top, y < top + iconWidth else { return }
        for (index, iconColor) in iconColors.enumerated() {
            let originX = startX + index * (iconWidth + gap)
            if x >= originX, x < originX + iconWidth {
                color = iconColor
                if y == top || x == originX {
                    color = iconColor.mixed(with: MockRGB(r: 255, g: 255, b: 255), amount: 0.22)
                }
                return
            }
        }
    }

    private func dockContains(x: Int, y: Int) -> Bool {
        guard y >= dock.y, y < dock.maxY else { return false }
        let radius = Double(dock.height) / 2
        if Double(x) < Double(dock.x) + radius {
            let dx = Double(x) - (Double(dock.x) + radius)
            let dy = Double(y) - (Double(dock.y) + radius)
            return dx * dx + dy * dy <= radius * radius
        }
        if Double(x) > Double(dock.maxX) - radius {
            let dx = Double(x) - (Double(dock.maxX) - radius)
            let dy = Double(y) - (Double(dock.y) + radius)
            return dx * dx + dy * dy <= radius * radius
        }
        return x >= dock.x && x < dock.maxX
    }

    // MARK: Chrome

    private func paintMenuBar(x: Int, y: Int, onto color: inout MockRGB) {
        guard y < 24 else { return }
        color = MockRGB(r: 15, g: 17, b: 25)

        let logoCenter = CGPoint(x: 20, y: 12)
        let logoDX = Double(x) - logoCenter.x
        let logoDY = Double(y) - logoCenter.y
        if logoDX * logoDX + logoDY * logoDY <= 30 {
            color = MockRGB(r: 126, g: 104, b: 255)
            return
        }

        let items: [(start: Int, width: Int)] = [
            (38, 24), (72, 32), (114, 20), (144, 36), (190, 24)
        ]
        for item in items where x >= item.start && x < item.start + item.width && y >= 9 && y <= 14 {
            color = MockRGB(r: 156, g: 162, b: 178)
            return
        }

        if y >= 8, y <= 15 {
            if x >= width - 36, x < width - 18 {
                color = MockRGB(r: 170, g: 176, b: 190)
                return
            }
            if x >= width - 70, x < width - 54 {
                color = MockRGB(r: 170, g: 176, b: 190)
                return
            }
        }
    }

    private func paintIndicators(x: Int, y: Int, onto color: inout MockRGB) {
        if observing, y < 2 {
            color = color.mixed(with: MockRGB(r: 255, g: 179, b: 64), amount: 0.9)
        }

        guard let keyPulseAge, keyPulseAge < 0.7 else { return }
        let centerX = Double(width - 44)
        let centerY = 38.0
        let dx = Double(x) - centerX
        let dy = Double(y) - centerY
        if dx * dx + dy * dy <= 25 {
            let alpha = (1 - keyPulseAge / 0.7) * 0.9
            color = color.mixed(with: MockRGB(r: 64, g: 214, b: 138), amount: alpha)
        }
    }

    // MARK: Cursor feedback

    private func paintRipple(x: Int, y: Int, onto color: inout MockRGB) {
        guard let click, click.age < 0.75 else { return }
        let dx = Double(x) - click.point.x
        let dy = Double(y) - click.point.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let radius = 8 + click.age * 170
        let fade = 1 - click.age / 0.75

        if abs(distance - radius) < 2.5 {
            color = color.mixed(with: MockRGB(r: 255, g: 255, b: 255), amount: fade * 0.75)
        } else if click.age < 0.16, distance < 4 {
            color = color.mixed(with: MockRGB(r: 255, g: 255, b: 255), amount: 0.85)
        }
    }

    private func paintCursor(x: Int, y: Int, onto color: inout MockRGB) {
        let originX = cursor.x
        let originY = cursor.y
        guard x >= Int(originX) - 2, x <= Int(originX) + 14,
              y >= Int(originY) - 2, y <= Int(originY) + 22
        else { return }

        let localX = Double(x) - originX
        let localY = Double(y) - originY
        let filled = Self.pointInsideCursor(x: localX, y: localY)
        if filled {
            color = MockRGB(r: 248, g: 248, b: 252)
            return
        }

        for offsetX in -1...1 {
            for offsetY in -1...1 where offsetX != 0 || offsetY != 0 {
                if Self.pointInsideCursor(x: localX + Double(offsetX), y: localY + Double(offsetY)) {
                    color = MockRGB(r: 8, g: 10, b: 16)
                    return
                }
            }
        }
    }

    private static let cursorPolygon: [(Double, Double)] = [
        (0, 0), (0, 17), (4.2, 12.8), (6.8, 18.6), (9.6, 17.4), (7.0, 11.8), (12, 11.8)
    ]

    private static func pointInsideCursor(x: Double, y: Double) -> Bool {
        var inside = false
        var j = cursorPolygon.count - 1
        for i in 0..<cursorPolygon.count {
            let xi = cursorPolygon[i].0
            let yi = cursorPolygon[i].1
            let xj = cursorPolygon[j].0
            let yj = cursorPolygon[j].1
            if (yi > y) != (yj > y),
               x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
