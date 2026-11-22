import CryptoKit
import Darwin
import Foundation
@testable import ScrctlGuiClient
@testable import ScrctlGuiUI
import XCTest

final class FileTransferTests: XCTestCase {
    @MainActor
    func testTransfersOverAppleConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenScreensTransfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = root.appending(path: "upload.bin")
        let downloads = root.appending(path: "downloads")
        let up = Data((0..<172_843).map { UInt8(truncatingIfNeeded: $0 &* 37 ^ ($0 >> 8)) })
        let down = Data((0..<197_391).map { UInt8(truncatingIfNeeded: $0 &* 19 ^ ($0 >> 7)) })
        try up.write(to: uploads)
        let peer = try TransferPeer(download: down)
        let server = Task.detached { try peer.serve() }
        let client = UniFfiRemoteSession(downloadDirectory: downloads)
        let model = SessionViewModel(
            profile: ConnectionProfile(name: "Transfer loopback", host: "127.0.0.1", port: peer.port),
            service: TransferService(client: client)
        )
        model.start()
        defer {
            model.stop()
            peer.resumeDownload.signal()
        }
        try await waitUntil("connected") { model.state.isConnected }

        model.uploadFiles([uploads])
        try await waitUntil("upload record") { model.sentFiles.count == 1 }
        XCTAssertEqual(model.sentFiles.first?.name, "upload.bin")
        XCTAssertEqual(model.sentFiles.first?.folder, "/fixture/inbox")

        model.download(remotePath: "/fixture/download.bin")
        try await waitUntil("partial download") { (model.downloadFraction ?? 0) > 0 }
        XCTAssertTrue(model.requestDisconnectConfirmation())
        XCTAssertEqual(model.disconnectRequest?.interruptsTransfers, true)
        XCTAssertTrue(model.state.isConnected)
        model.cancelDisconnectConfirmation()
        peer.resumeDownload.signal()
        try await waitUntil("download record") { model.receivedFiles.count == 1 }
        let saved = try XCTUnwrap(model.receivedFiles.first?.url)
        XCTAssertEqual(saved.lastPathComponent, "download.bin")
        XCTAssertEqual(saved.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path, downloads.resolvingSymlinksInPath().path)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: saved)), SHA256.hash(data: down))
        XCTAssertFalse(model.requestDisconnectConfirmation())

        model.download(remotePath: "/fixture/cancel.bin")
        try await waitUntil("server cancellation") { !model.hasActiveTransfers }
        XCTAssertTrue(model.failureMessage?.contains("cancelled") == true)
        XCTAssertEqual(model.receivedFiles.count, 1)

        model.download(remotePath: "/fixture/incomplete.bin")
        try await waitUntil("short download failure") { !model.hasActiveTransfers }
        XCTAssertTrue(model.failureMessage?.contains("incomplete") == true)
        XCTAssertEqual(model.receivedFiles.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count, 1)

        model.download(remotePath: "/fixture/disconnect.bin")
        try await waitUntil("download before disconnect") { (model.downloadFraction ?? 0) > 0 }
        XCTAssertTrue(model.requestDisconnectConfirmation())
        let request = try XCTUnwrap(model.disconnectRequest)
        XCTAssertTrue(model.confirmDisconnect(request))
        let receivedUpload = try await server.value
        XCTAssertEqual(SHA256.hash(data: receivedUpload), SHA256.hash(data: up))
        XCTAssertFalse(model.hasActiveTransfers)
        try await waitUntil("incomplete destination removed") {
            (try? FileManager.default.contentsOfDirectory(atPath: downloads.path).count) == 1
        }
    }

    @MainActor
    private func waitUntil(_ phase: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(phase)")
                throw POSIXError(.ETIMEDOUT)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct TransferService: RemoteSessionService {
    let client: UniFfiRemoteSession
    func makeSession() -> any RemoteSessionProtocol { client }
}

private final class TransferPeer: Sendable {
    let resumeDownload = DispatchSemaphore(value: 0)
    let port: Int
    private let listener: Int32
    private let download: Data

    init(download: Data) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        let ready = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && listen(listener, 1) == 0 &&
                    getsockname(listener, $0, &length) == 0
            }
        }
        guard ready else {
            close(listener)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.listener = listener
        self.port = Int(UInt16(bigEndian: address.sin_port))
        self.download = download
    }

    deinit { close(listener) }

    func serve() throws -> Data {
        var incoming = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 5000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let socket = accept(listener, nil, nil)
        guard socket >= 0 else { throw POSIXError(.ECONNABORTED) }
        let peer = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.EINVAL)
        }

        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let chunk = try peer.read(upToCount: count - result.count), !chunk.isEmpty else {
                    throw POSIXError(.ECONNRESET)
                }
                result.append(chunk)
            }
            return result
        }

        func container(_ subtype: UInt16, _ handle: Data, _ payload: Data = Data()) throws {
            try peer.write(contentsOf: Data([0x22, 0]) + bytes(UInt32(8 + payload.count)) +
                Data([0, 1]) + bytes(subtype) + handle + payload)
        }

        try peer.write(contentsOf: Data("RFB 003.889\n".utf8))
        XCTAssertEqual(try read(12), Data("RFB 003.889\n".utf8))
        try peer.write(contentsOf: Data([1, 1]))
        XCTAssertEqual(try read(1), Data([1]))
        try peer.write(contentsOf: Data(count: 4))
        XCTAssertEqual(try read(1), Data([0xC1]))
        try peer.write(contentsOf: Data([
            0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
            0, 0, 0, 0
        ]))

        let destination = Data("/fixture/inbox".utf8)
        var uploaded = Data()
        var uploadChunks = 0
        var disconnectRequested = false
        while let marker = try peer.read(upToCount: 1)?.first {
            switch marker {
            case 0x00: _ = try read(19) // SetPixelFormat
            case 0x02: // SetEncodings
                _ = try read(1)
                _ = try read(4 * Int(number(try read(2)) as UInt16))
            case 0x03: _ = try read(9) // FramebufferUpdateRequest
            case 0x10: _ = try read(17) // Apple pointer input during upload announcement.
            case 0x20: // Drag-in announcement.
                let header = try read(15)
                let handle = Data(header[3..<7])
                _ = try read(Int(number(Data(header[11..<15])) as UInt32))
                try peer.write(contentsOf: Data([0x1E, 0, 0, 0]) + handle +
                    bytes(UInt32(destination.count)) + destination)
            case 0x21: _ = try read(65) // Apple client capabilities.
            case 0x22:
                let header = try read(13)
                let subtype: UInt16 = number(Data(header[7..<9]))
                let handle = Data(header[9..<13])
                let payload = try read(Int(number(Data(header[1..<5])) as UInt32) - 8)
                if subtype == 0x66 {
                    uploadChunks += 1
                    uploaded.append(payload.dropFirst(4))
                } else if subtype == 0x68 {
                    XCTAssertGreaterThan(uploadChunks, 1)
                } else if subtype == 0x01 {
                    let name = String(decoding: payload.dropFirst(10).dropLast(), as: UTF8.self)
                        .split(separator: "/").last.map(String.init) ?? ""
                    let size = bytes(UInt64(download.count))
                    var summary = Data(count: 8) + size + size + Data(count: 4)
                    summary += Data([0, 0, 0, 1]) + Data(count: 20)
                    try container(0x64, handle, summary)
                    var entry = Data(count: 104)
                    entry[0] = 1
                    entry.replaceSubrange(42..<50, with: size)
                    entry.replaceSubrange(94..<96, with: bytes(UInt16(0o100644)))
                    entry.replaceSubrange(100..<102, with: bytes(UInt16(name.utf8.count)))
                    entry += Data(name.utf8) + Data([0])
                    try container(0x65, handle, entry)
                    let chunk = 64 * 1024
                    try container(0x66, handle, bytes(UInt32(chunk)) + Data(download.prefix(chunk)))
                    switch name {
                    case "cancel.bin":
                        try container(0x05, handle)
                    case "incomplete.bin":
                        try container(0x68, handle)
                    case "disconnect.bin":
                        disconnectRequested = true
                    default:
                        guard resumeDownload.wait(timeout: .now() + 5) == .success else {
                            throw POSIXError(.ETIMEDOUT)
                        }
                        for offset in stride(from: chunk, to: download.count, by: chunk) {
                            let data = download[offset..<min(offset + chunk, download.count)]
                            try container(0x66, handle, bytes(UInt32(data.count)) + data)
                        }
                        try container(0x68, handle)
                    }
                }
            default:
                XCTFail("Unexpected RFB message: \(marker)")
                throw POSIXError(.EPROTO)
            }
        }
        XCTAssertTrue(disconnectRequested, "Expected EOF after confirmed disconnect")
        return uploaded
    }

    private func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func number<T: FixedWidthInteger>(_ data: Data) -> T {
        data.reduce(0) { ($0 << 8) | T($1) }
    }
}
