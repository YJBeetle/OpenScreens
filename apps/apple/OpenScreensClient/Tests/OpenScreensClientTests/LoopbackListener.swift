import Darwin
import Foundation

struct LoopbackListener: Sendable {
    private let handle: FileHandle
    let port: Int

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        let handle = FileHandle(fileDescriptor: listener, closeOnDealloc: true)

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
        self.handle = handle
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func accept() throws -> FileHandle {
        var incoming = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&incoming, 1, 3000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let socket = Darwin.accept(handle.fileDescriptor, nil, nil)
        guard socket >= 0 else { throw POSIXError(.ECONNABORTED) }
        let peer = FileHandle(fileDescriptor: socket, closeOnDealloc: true)
        var noSigpipe: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout.size(ofValue: noSigpipe))) == 0 else {
            throw POSIXError(.EINVAL)
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.EINVAL)
        }

        return peer
    }
}

extension FileHandle {
    func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try read(upToCount: count - data.count), !chunk.isEmpty else {
                throw POSIXError(.ECONNRESET)
            }
            data.append(chunk)
        }
        return data
    }
}
