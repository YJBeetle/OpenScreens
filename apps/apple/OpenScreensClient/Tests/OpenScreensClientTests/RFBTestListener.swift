import Darwin
import Foundation
import XCTest

final class RFBTestListener: @unchecked Sendable {
    private let descriptor: Int32
    let port: Int

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        var initialized = false
        defer { if !initialized { close(listener) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(listener, $0, length) == 0, listen(listener, 1) == 0,
                      getsockname(listener, $0, &length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        descriptor = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        initialized = true
    }

    deinit { close(descriptor) }

    func accept(_ handler: (RFBTestPeer) throws -> Void) throws {
        let listener = descriptor
        var incoming = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 3000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let socket = Darwin.accept(listener, nil, nil)
        guard socket >= 0 else { throw POSIXError(.ECONNABORTED) }
        let peer = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.EINVAL)
        }

        try handler(RFBTestPeer(handle: peer))
    }
}

struct RFBTestPeer {
    let handle: FileHandle

    func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            data.append(chunk)
        }
        return data
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
