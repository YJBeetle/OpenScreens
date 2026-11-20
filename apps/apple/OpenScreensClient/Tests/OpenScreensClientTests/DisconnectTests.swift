import Darwin
import Foundation
import OpenScreensClient
import OpenScreensUI
import XCTest

final class DisconnectTests: XCTestCase {
    func testDisconnectDrainsKeyReleaseAndClosesIdleTCPPeer() async throws {
        let (listener, profile) = try Self.makeListener()
        defer { close(listener) }
        let peer = Task.detached { try Self.serve(listener) }
        let client = UniFfiRemoteSession()
        try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        await client.sendKey(RemoteKeyEvent(key: .text("a")))
        await client.disconnect()
        try await peer.value
        // The peer must receive FIN while the client object and process are still alive.
        await client.disconnect()
    }

    func testClientDisconnectClosesPendingHandshake() async throws {
        try await checkPendingHandshake(cancelTask: false)
    }

    func testTaskCancellationClosesPendingHandshake() async throws {
        try await checkPendingHandshake(cancelTask: true)
    }

    private func checkPendingHandshake(cancelTask: Bool) async throws {
        let (listener, profile) = try Self.makeListener()
        defer { close(listener) }
        let client = UniFfiRemoteSession()
        let connection = Task {
            try await client.connect(profile: profile, password: "fixture", macSessionChoice: nil)
        }
        let peer = try await Task.detached {
            let peer = try Self.acceptPeer(listener)
            let version = Data("RFB 003.008\n".utf8)
            try peer.write(contentsOf: version)
            XCTAssertEqual(try Self.read(12, from: peer), version)
            return peer
        }.value

        if cancelTask { connection.cancel() } else { await client.disconnect() }
        var byte: UInt8 = 0
        XCTAssertEqual(recv(peer.fileDescriptor, &byte, 1, 0), 0, "The server should see EOF during negotiation")
        try peer.close()
        do {
            try await connection.value
            XCTFail("A cancelled handshake should not produce a session")
        } catch is CancellationError {}
    }

    private static func makeListener() throws -> (Int32, ConnectionProfile) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(listener, $0, length) == 0, listen(listener, 1) == 0,
                      getsockname(listener, $0, &length) == 0 else {
                    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    close(listener)
                    throw error
                }
            }
        }
        let profile = ConnectionProfile(
            name: "Loopback", host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port))
        )
        return (listener, profile)
    }

    private static func acceptPeer(_ listener: Int32) throws -> FileHandle {
        var incoming = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 3000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let socket = accept(listener, nil, nil)
        guard socket >= 0 else { throw POSIXError(.ECONNABORTED) }
        let peer = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.EINVAL)
        }

        return peer
    }

    private static func read(_ count: Int, from peer: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try peer.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            data.append(chunk)
        }
        return data
    }

    private static func serve(_ listener: Int32) throws {
        let peer = try acceptPeer(listener)
        func read(_ count: Int) throws -> Data { try Self.read(count, from: peer) }

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
        XCTAssertEqual(recv(peer.fileDescriptor, &byte, 1, 0), 0, "Expected TCP EOF after the queued key release, errno=\(errno)")
    }
}
