import Darwin
import Foundation
import XCTest

extension LoopbackListener {
    func accept(_ handler: (RFBTestPeer) throws -> Void) throws {
        try handler(RFBTestPeer(handle: accept()))
    }
}

struct RFBTestPeer {
    let handle: FileHandle

    func read(_ count: Int) throws -> Data {
        try handle.readExactly(count)
    }

    func handshake(apple: Bool = false) throws {
        let version = Data((apple ? "RFB 003.889\n" : "RFB 003.008\n").utf8)
        try handle.write(contentsOf: version)
        XCTAssertEqual(try read(12), version)
        try handle.write(contentsOf: Data([1, 1]))
        XCTAssertEqual(try read(1), Data([1]))
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        _ = try read(1)
        var initMessage = Data([0, 1, 0, 1, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        if apple {
            var name = Data(repeating: 0, count: 22)
            name[8] = 2 // Feature bits 41 and 32 in the first big-endian bitmap.
            name[9] = 1
            initMessage.append(contentsOf: [0, 0, 0, 23])
            initMessage.append(name)
            initMessage.append(65)
        } else {
            initMessage.append(contentsOf: [0, 0, 0, 0])
        }
        try handle.write(contentsOf: initMessage)
        if apple { XCTAssertEqual(try read(66).first, 33) }
        _ = try read(20)
        let encodings = try read(4)
        _ = try read(4 * (Int(encodings[2]) * 256 + Int(encodings[3])))
        _ = try read(10)
    }

    func expectEOF() {
        var byte: UInt8 = 0
        XCTAssertEqual(recv(handle.fileDescriptor, &byte, 1, 0), 0, "Expected TCP EOF, errno=\(errno)")
    }
}
