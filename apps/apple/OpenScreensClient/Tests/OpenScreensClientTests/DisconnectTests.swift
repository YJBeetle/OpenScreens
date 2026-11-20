import Darwin
import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class DisconnectTests: XCTestCase {
    func testDisconnectDrainsKeyReleaseAndClosesIdleTCPPeer() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(listener) }

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
        let peer = Task.detached { try Self.serve(listener) }
        let client = UniFfiRemoteSession()
        let profile = ConnectionProfile(
            name: "Loopback", host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port))
        )
        try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        await client.sendKey(RemoteKeyEvent(key: .text("a")))
        await client.disconnect()
        try await peer.value
        // The peer must receive FIN while the client object and process are still alive.
        await client.disconnect()
    }

    private static func serve(_ listener: Int32) throws {
        var incoming = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 3000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let socket = accept(listener, nil, nil)
        guard socket >= 0 else { throw POSIXError(.ECONNABORTED) }
        let peer = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.EINVAL)
        }

        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let chunk = try peer.read(upToCount: count - data.count), !chunk.isEmpty else {
                    throw POSIXError(.ECONNRESET)
                }
                data.append(chunk)
            }
            return data
        }

        let version = Data("RFB 003.008\n".utf8)
        try peer.write(contentsOf: version)
        XCTAssertEqual(try read(12), version)
        try peer.write(contentsOf: Data([1, 1])) // SecurityType None
        XCTAssertEqual(try read(1), Data([1]))
        try peer.write(contentsOf: Data(repeating: 0, count: 4))
        _ = try read(1)
        // One synthetic pixel, BGRA8888, no desktop name.
        try peer.write(contentsOf: Data([
            0, 1, 0, 1,
            32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
            0, 0, 0, 0
        ]))
        _ = try read(20) // SetPixelFormat
        let encodings = try read(4)
        _ = try read(4 * (Int(encodings[2]) * 256 + Int(encodings[3])))
        _ = try read(10) // Full update request. Stay idle to keep nextEvent suspended.
        XCTAssertEqual(try read(16), Data([4, 1, 0, 0, 0, 0, 0, 97, 4, 0, 0, 0, 0, 0, 0, 97]))
        var byte: UInt8 = 0
        XCTAssertEqual(recv(socket, &byte, 1, 0), 0, "Expected TCP EOF after the queued key release, errno=\(errno)")
    }
}
