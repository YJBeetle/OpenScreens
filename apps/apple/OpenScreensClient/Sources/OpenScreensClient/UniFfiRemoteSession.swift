import CoreGraphics
import Foundation
import OpenScreensCanvas
import OpenScreensCore
import OpenScreensUI
import os

/// The production transport: drives the Rust RFB engine through UniFFI.
private struct SessionSetupError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private extension OpenScreensCore.SessionFailureKind {
    var remoteKind: RemoteFailureKind {
        switch self {
        case .unknown: .unknown
        case .network: .network
        case .connectionRefused: .connectionRefused
        case .missingUsername: .missingUsername
        case .missingPassword: .missingPassword
        case .authenticationFailed: .authenticationFailed
        case .unsupportedVersion: .unsupportedVersion
        case .unsupportedSecurityType: .unsupportedSecurityType
        case .`protocol`: .protocolViolation
        case .decode: .decode
        case .tunnel: .tunnel
        case .sshTunnel: .sshTunnel
        case .closed: .closed
        case .invalidInput: .invalidInput
        }
    }
}

public struct UniFfiSessionService: OpenScreensUI.RemoteSessionService {
    public init() {}

    public func makeSession() -> any OpenScreensUI.RemoteSessionProtocol {
        UniFfiRemoteSession()
    }
}

private enum InputCommand: Sendable {
    case pointer(mask: UInt8, x: UInt16, y: UInt16)
    case scroll(x: UInt16, y: UInt16, stepsX: Int32, stepsY: Int32)
    case key(down: Bool, keysym: UInt32)
    case clipboard(String)
}

/// A regular file described for the Apple drag-and-drop upload protocol.
private struct UploadFile: Sendable {
    let url: URL
    let name: String
    let size: UInt64
    let entry: OpenScreensCore.TransferEntry
}

public actor UniFfiRemoteSession: OpenScreensUI.RemoteSessionProtocol {
    public nonisolated let events: AsyncStream<OpenScreensUI.RemoteSessionEvent>

    private let continuation: AsyncStream<OpenScreensUI.RemoteSessionEvent>.Continuation
    private nonisolated let inputContinuation: AsyncStream<InputCommand>.Continuation
    private let inputStream: AsyncStream<InputCommand>

    private var session: OpenScreensCore.RemoteSession?
    private var eventTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

    private var width: UInt16 = 0
    private var height: UInt16 = 0
    // Framebuffer pixels are sampled down so a 6K host does not allocate a
    // full-resolution texture (and a 268 MB frame buffer copy) per frame.
    private var displayScale: UInt16 = 1
    private var scaledWidth = 0
    private var scaledHeight = 0
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var buttonMask: UInt8 = 0
    private var observing = false
    private var finished = false
    private var sharedClipboard = true
    /// Guards against echoing the remote clipboard straight back to the server.
    private var lastRemoteClipboard: String?
    private var lastSentClipboard: String?

    /// Callers waiting for the 0x20 drag info that answers a 0x0E drag-out.
    private var dragOutWaiters: [UInt32: CheckedContinuation<[OpenScreensUI.RemoteFile], Never>] = [:]
    private var dragOutTimeouts: [UInt32: Task<Void, Never>] = [:]
    /// File-promise downloads wait for the engine's DownloadComplete event.
    private var downloadWaiters: [UInt32: CheckedContinuation<URL, Error>] = [:]
    private var downloadNames: [UInt32: String] = [:]

    /// Files announced to the server, keyed by their transfer handle. The
    /// server answers a drag-in with `.uploadRequest(handle:path:)`.
    private var pendingUploads: [UInt32: [URL]] = [:]
    /// Last file name seen for an upload, so a bare ack can clear the UI.
    private var uploadFileNames: [UInt32: String] = [:]
    /// Local destination folder for each download, keyed by transfer handle.
    private var downloadRoots: [UInt32: String] = [:]

    private let logger = Logger(subsystem: "app.openscreens", category: "Session")
    private static let displayTargetWidth = 2560
    /// Conservative Metal 2D texture limit; keeps the simulator and every
    /// supported device inside `maxTextureDimension2D`.
    private static let maxTextureDimension = 8192
    private static let maxSamplingScale = 16
    private static let uploadChunkSize = 64 * 1024
    /// POSIX 0100644: a plain file owned by the uploading user.
    private static let uploadFileMode: UInt16 = 0o100644
    private static let epoch1904Offset: UInt64 = 2_082_844_800
    private static let transferProgressSubtype: UInt16 = 0x00C8
    private static let transferAckSubtype: UInt16 = 0x012C

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: OpenScreensUI.RemoteSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation

        let (input, inputContinuation) = AsyncStream.makeStream(of: InputCommand.self)
        self.inputStream = input
        self.inputContinuation = inputContinuation
    }

    public func connect(profile: ConnectionProfile) async throws {
        guard session == nil, !finished else { return }
        observing = profile.controls.startInObserveMode
        sharedClipboard = profile.controls.sharedClipboard
        cursor = CGPoint(x: 0.5, y: 0.5)
        buttonMask = 0
        continuation.yield(.state(.connecting))

        let storedPassword = OpenScreensCredentials.password(for: profile.id)
        let password = storedPassword ?? debugPassword()
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)

        var sshHost: String?
        var sshPort: UInt16?
        var sshUsername: String?
        var sshAuth: OpenScreensCore.SshAuthConfig?
        var sshFingerprint: String?
        if let ssh = profile.ssh, ssh.enabled {
            let sshUser = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sshUser.isEmpty else {
                throw SessionSetupError(
                    NSLocalizedString("SSH user name is required.", comment: "Session setup error")
                )
            }
            let sshHostValue = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
            sshHost = sshHostValue.isEmpty ? profile.trimmedHost : sshHostValue
            sshPort = UInt16(clamping: ssh.port)
            sshUsername = sshUser
            switch ssh.authMethod {
            case .password:
                let sshPassword = OpenScreensCredentials.secret(kind: "ssh-password", for: profile.id) ?? ""
                sshAuth = .password(password: sshPassword)
            case .privateKey:
                let pem: String
                if let keyID = ssh.importedKeyID,
                   let stored = OpenScreensCredentials.secret(
                       kind: SSHKeyVault.secretKind,
                       for: keyID
                   ),
                   !stored.isEmpty {
                    pem = stored
                } else {
                    let expanded = (ssh.keyPath as NSString).expandingTildeInPath
                    do {
                        pem = try String(contentsOfFile: expanded, encoding: .utf8)
                    } catch {
                        throw SessionSetupError(
                            NSLocalizedString(
                                "Choose an SSH private key for this connection.",
                                comment: "Session setup error"
                            )
                        )
                    }
                }
                let passphrase = OpenScreensCredentials.secret(kind: "ssh-passphrase", for: profile.id)
                sshAuth = .privateKey(pem: pem, passphrase: passphrase)
            }
            let fingerprint = ssh.hostKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            sshFingerprint = fingerprint.isEmpty ? nil : fingerprint
        }
        if profile.hasTunnelConflict {
            throw SessionSetupError(
                NSLocalizedString(
                    "SSH, WireGuard and OpenVPN are mutually exclusive. Choose one.",
                    comment: "Session setup error"
                )
            )
        }

        // macOS draws the pointer client-side; on touch platforms the remote
        // server keeps compositing it into the framebuffer.
        #if os(macOS)
        let localCursor = true
        #else
        let localCursor = false
        #endif

        let config = OpenScreensCore.SessionConfig(
            host: profile.trimmedHost,
            port: UInt16(clamping: profile.port),
            username: username.isEmpty ? nil : username,
            password: (password?.isEmpty == false) ? password : nil,
            shared: true,
            localCursor: localCursor,
            quality: 9,
            frameIntervalMs: 16,
            wireguardConfig: profile.wireGuardConfig,
            wireguardDnsFallback: true,
            openvpnConfig: profile.openVpnConfig,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            sshAuth: sshAuth,
            sshHostKeyFingerprint: sshFingerprint
        )

        do {
            let session = try await OpenScreensCore.RemoteSession.connect(config: config)
            self.session = session
            updateSize(session.size())
            continuation.yield(.displays([
                RemoteDisplay(
                    id: 0,
                    name: session.serverName(),
                    width: Int(width),
                    height: Int(height)
                ),
            ]))
            continuation.yield(.state(.connected))
            startEventPump(session)
            startInputPump(session)
        } catch {
            logger.error("connect failed: \(error.localizedDescription, privacy: .public)")
            if case let OpenScreensCore.SessionFailure.Session(kind, reason) = error {
                throw RemoteSessionFailure(kind: kind.remoteKind, reason: reason)
            }
            throw error
        }
    }

    public func disconnect() async {
        finish(reason: NSLocalizedString("Connection closed", comment: "Session disconnect reason"))
    }

    public func sendPointer(_ event: PointerEvent) async {
        guard !observing, width > 0, height > 0 else { return }

        if event.isRelative {
            cursor.x += event.x
            cursor.y += event.y
        } else {
            cursor = CGPoint(x: event.x, y: event.y)
        }
        cursor.x = min(max(cursor.x, 0), 1)
        cursor.y = min(max(cursor.y, 0), 1)

        let bit = Self.bit(for: event.button)
        switch event.action {
        case .down:
            buttonMask |= bit
        case .up:
            buttonMask &= ~bit
        case .move:
            break
        }

        let x = UInt16(clamping: min(Int(cursor.x * Double(width)), Int(width) - 1))
        let y = UInt16(clamping: min(Int(cursor.y * Double(height)), Int(height) - 1))
        inputContinuation.yield(.pointer(mask: buttonMask, x: x, y: y))
    }

    public func sendScroll(at point: CGPoint, stepsX: Int32, stepsY: Int32) async {
        guard !observing, width > 0, height > 0, stepsX != 0 || stepsY != 0 else { return }
        let x = UInt16(clamping: min(Int(point.x * Double(width)), Int(width) - 1))
        let y = UInt16(clamping: min(Int(point.y * Double(height)), Int(height) - 1))
        inputContinuation.yield(.scroll(x: x, y: y, stepsX: stepsX, stepsY: stepsY))
    }

    public func sendKey(_ event: RemoteKeyEvent) async {
        guard !observing else { return }
        let modifiers = Keysym.modifiers(event.modifiers)
        for keysym in modifiers {
            inputContinuation.yield(.key(down: true, keysym: keysym))
        }

        if case .text(let text) = event.key {
            for scalar in text.unicodeScalars {
                let keysym = Keysym.keysym(for: scalar)
                inputContinuation.yield(.key(down: true, keysym: keysym))
                inputContinuation.yield(.key(down: false, keysym: keysym))
            }
        } else if let keysym = Keysym.keysym(for: event.key) {
            inputContinuation.yield(.key(down: true, keysym: keysym))
            inputContinuation.yield(.key(down: false, keysym: keysym))
        }

        for keysym in modifiers.reversed() {
            inputContinuation.yield(.key(down: false, keysym: keysym))
        }
    }

    public func sendClipboard(_ text: String) async {
        guard !text.isEmpty else { return }
        lastSentClipboard = text
        inputContinuation.yield(.clipboard(text))
    }

    public func requestClipboard() async {}

    /// Answers Apple message 0x14 subtype 2. The engine deduplicates the wire
    /// payload; reading the platform pasteboard is gated by the per-connection
    /// shared clipboard setting.
    private func handleClipboardRequest() {
        guard sharedClipboard, session != nil, !finished else { return }
        Task { @MainActor [weak self] in
            guard let self, let text = PlatformClipboard.string, !text.isEmpty else { return }
            await self.respondToClipboardRequest(text)
        }
    }

    private func respondToClipboardRequest(_ text: String) async {
        guard let session, !finished, sharedClipboard else { return }
        guard text != lastRemoteClipboard, text != lastSentClipboard else { return }
        do {
            try await session.sendClipboard(text: text)
            lastSentClipboard = text
        } catch {
            logger.error("clipboard reply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func setObserveMode(_ observing: Bool) async {
        self.observing = observing
    }

    public func selectDisplay(_ id: Int?) async {
        guard let session, !finished else { return }
        let displayID = id.flatMap { UInt32(exactly: $0) }
        do {
            try await session.selectDisplay(displayId: displayID)
        } catch {
            logger.error("select display failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failure(String(
                format: NSLocalizedString("Could not switch display: %@", comment: "Display switch error"),
                error.localizedDescription
            )))
        }
    }

    /// Subscribes only to the visible framebuffer region and samples it at
    /// roughly one stored pixel per screen pixel, so a zoomed crop stays sharp
    /// without transferring the whole desktop.
    public func setViewport(_ normalizedRect: CGRect?, screenPixelWidth: Int) async {
        guard let session, !finished, width > 0, height > 0 else { return }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let fraction = (normalizedRect ?? unit).intersection(unit)
        guard fraction.width > 0, fraction.height > 0 else { return }

        let full = CGRect(x: 0, y: 0, width: Int(width), height: Int(height))
        let visible = CGRect(
            x: (fraction.minX * CGFloat(width)).rounded(.down),
            y: (fraction.minY * CGFloat(height)).rounded(.down),
            width: (fraction.width * CGFloat(width)).rounded(.up),
            height: (fraction.height * CGFloat(height)).rounded(.up)
        ).integral.intersection(full)
        guard visible.width >= 1, visible.height >= 1 else { return }

        var density = max(1, Int(visible.width) / max(1, screenPixelWidth))
        density = max(
            density,
            (Int(width) + Self.maxTextureDimension - 1) / Self.maxTextureDimension,
            (Int(height) + Self.maxTextureDimension - 1) / Self.maxTextureDimension
        )
        density = min(Self.maxSamplingScale, density)
        if displayScale != UInt16(density) {
            displayScale = UInt16(density)
            scaledWidth = (Int(width) + density - 1) / density
            scaledHeight = (Int(height) + density - 1) / density
            logger.info(
                "viewport sampling 1/\(density) (\(self.scaledWidth)x\(self.scaledHeight))"
            )
        }

        let margin = max(64, Int(visible.width) / 12)
        let target = CGRect(
            x: visible.minX - CGFloat(margin),
            y: visible.minY - CGFloat(margin),
            width: visible.width + CGFloat(margin * 2),
            height: visible.height + CGFloat(margin * 2)
        ).integral.intersection(full)

        do {
            try await session.setViewport(
                x: UInt16(target.minX),
                y: UInt16(target.minY),
                width: UInt16(target.width),
                height: UInt16(target.height)
            )
        } catch {
            logger.warning("set viewport failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - File upload

    /// Announces dropped files to the server. The upload itself starts when
    /// the server answers with an `.uploadRequest` carrying the destination.
    public func uploadFiles(_ urls: [URL]) async {
        guard let session, !finished else { return }
        let files = urls.filter(Self.isUploadable)
        guard !files.isEmpty else {
            continuation.yield(.failure(NSLocalizedString(
                "Only regular files can be sent to the remote computer.",
                comment: "Upload error"
            )))
            continuation.yield(.transferFinished(name: nil))
            return
        }

        let handle = session.nextTransferHandle()
        pendingUploads[handle] = files
        uploadFileNames[handle] = files[0].lastPathComponent
        do {
            try await session.announceUpload(
                handle: handle,
                fileUrls: files.map(\.absoluteString)
            )
        } catch {
            pendingUploads[handle] = nil
            uploadFileNames[handle] = nil
            logger.error(
                "upload announce failed: \(error.localizedDescription, privacy: .public)"
            )
            continuation.yield(.failure(String(
                format: NSLocalizedString("Could not send files: %@", comment: "Upload error"),
                error.localizedDescription
            )))
            continuation.yield(.transferFinished(name: nil))
        }
    }

    private static func isUploadable(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile != false && values?.isSymbolicLink != true
    }

    /// Uploads one announcement's files through the handle the server picked.
    private func performUpload(
        handle: UInt32,
        destination: String,
        urls: [URL],
        session: OpenScreensCore.RemoteSession
    ) async {
        let files = urls.compactMap(Self.describeUpload)
        guard !files.isEmpty else {
            try? await session.cancelTransfer(handle: handle)
            continuation.yield(.failure(NSLocalizedString(
                "The dropped items could not be read.",
                comment: "Upload error"
            )))
            continuation.yield(.transferFinished(name: nil))
            return
        }

        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.size }
        var sentBytes: UInt64 = 0
        do {
            try await session.uploadDestination(handle: handle, folder: destination)
            try await session.uploadSummary(
                handle: handle,
                totalBytes: totalBytes,
                files: UInt32(files.count),
                directories: 0
            )

            for file in files {
                continuation.yield(.transferProgress(name: file.name, fraction: nil))
                try await session.uploadEntry(handle: handle, entry: file.entry)

                // iOS hands out security-scoped URLs; macOS grants dragged
                // files directly and this is a no-op returning false.
                let accessing = file.url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { file.url.stopAccessingSecurityScopedResource() }
                }
                let source = try FileHandle(forReadingFrom: file.url)
                defer { try? source.close() }

                while let chunk = try source.read(upToCount: Self.uploadChunkSize),
                      !chunk.isEmpty {
                    try await session.uploadData(handle: handle, chunk: chunk)
                    sentBytes += UInt64(chunk.count)
                    if totalBytes > 0 {
                        continuation.yield(.transferProgress(
                            name: file.name,
                            fraction: min(1, Double(sentBytes) / Double(totalBytes))
                        ))
                    }
                }
            }

            try await session.uploadComplete(handle: handle)
            logger.info(
                "uploaded \(files.count) file(s), \(sentBytes) bytes to \(destination, privacy: .public)"
            )
            continuation.yield(.transferFinished(name: files.last?.name))
        } catch {
            logger.error("upload failed: \(error.localizedDescription, privacy: .public)")
            try? await session.cancelTransfer(handle: handle)
            continuation.yield(.failure(String(
                format: NSLocalizedString("File transfer failed: %@", comment: "Upload error"),
                error.localizedDescription
            )))
            continuation.yield(.transferFinished(name: nil))
        }
        uploadFileNames.removeValue(forKey: handle)
    }

    private static func describeUpload(_ url: URL) -> UploadFile? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value
            ?? values?.fileSize.map({ UInt64($0) })
        else { return nil }

        let modified = attributes?[.modificationDate] as? Date ?? Date()
        let created = attributes?[.creationDate] as? Date ?? modified
        let name = url.lastPathComponent.isEmpty
            ? NSLocalizedString("file", comment: "Fallback file name")
            : url.lastPathComponent
        let stamp = appleTimestamp(modified)

        return UploadFile(
            url: url,
            name: name,
            size: size,
            entry: OpenScreensCore.TransferEntry(
                kind: .file,
                name: name,
                dataSize: size,
                resourceSize: 0,
                mode: uploadFileMode,
                nesting: 0,
                created: appleTimestamp(created),
                accessed: stamp,
                changed: stamp,
                modified: stamp,
                finderInfo: Data(count: 32),
                linkTarget: nil
            )
        )
    }

    /// Apple file transfer timestamps count seconds since 1904-01-01.
    private static func appleTimestamp(_ date: Date) -> UInt32 {
        let unix = UInt64(max(0, date.timeIntervalSince1970))
        return UInt32(truncatingIfNeeded: unix &+ epoch1904Offset)
    }

    // MARK: - File download

    /// Asks the server for a remote POSIX path and stores what it sends below
    /// the local Downloads directory (or Documents when that is unavailable).
    public func download(remotePath: String) async {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            yieldDownloadFailure(NSLocalizedString("Enter a remote path to download.", comment: "Download error"))
            return
        }
        guard let session, !finished else {
            yieldDownloadFailure(NSLocalizedString("The session is not connected.", comment: "Download error"))
            return
        }
        guard let root = downloadRootDirectory() else {
            yieldDownloadFailure(NSLocalizedString("No local folder is available for downloads.", comment: "Download error"))
            return
        }

        let handle = session.nextTransferHandle()
        // Store the destination before starting so a fast completion can find it.
        downloadRoots[handle] = root.path
        do {
            try await session.startDownload(handle: handle, path: path, root: root.path)
            logger.info(
                "download started handle=\(handle) path=\(path, privacy: .public) root=\(root.path, privacy: .public)"
            )
        } catch {
            downloadRoots.removeValue(forKey: handle)
            let message = error.localizedDescription
            logger.error("download failed: \(message, privacy: .public)")
            continuation.yield(.failure(String(
                format: NSLocalizedString("Could not download “%@”: %@", comment: "Download error"),
                path,
                message
            )))
            // Also closes the in-flight status in the UI.
            continuation.yield(.downloadComplete(savedPath: nil, error: message))
        }
    }

    // MARK: - Drag out

    /// Sends Apple message 0x0E and waits for the 0x20 drag info. The server
    /// answers with the file URLs on its current drag pasteboard.
    public func beginDragOut() async -> [OpenScreensUI.RemoteFile] {
        guard let session, !finished else { return [] }
        do {
            let handle = try await session.beginDragOut(handle: nil)
            return await withCheckedContinuation { continuation in
                dragOutWaiters[handle] = continuation
                dragOutTimeouts[handle]?.cancel()
                dragOutTimeouts[handle] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.resolveDragOut(handle: handle, files: [])
                }
            }
        } catch {
            logger.error("drag-out start failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func resolveDragOut(handle: UInt32, files: [OpenScreensUI.RemoteFile]) {
        dragOutTimeouts.removeValue(forKey: handle)?.cancel()
        dragOutWaiters.removeValue(forKey: handle)?.resume(returning: files)
    }

    /// Downloads one remote drag item into a private temporary folder and
    /// returns the local item. File promises call this only after a drop.
    public func download(remotePath: String, toDirectory directory: URL) async throws -> URL {
        guard let session, !finished else {
            throw RemoteTransferError.notConnected
        }
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw RemoteTransferError.missingDownloadedFile(remotePath)
        }

        let handle = session.nextTransferHandle()
        let name = Self.fileName(inRemotePath: path)
        let root = directory.appendingPathComponent(
            ".openscreens-\(handle)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        downloadNames[handle] = name
        downloadRoots[handle] = root.path
        return try await withCheckedThrowingContinuation { continuation in
            downloadWaiters[handle] = continuation
            Task {
                do {
                    try await session.startDownload(handle: handle, path: path, root: root.path)
                } catch {
                    await self.failDownload(handle: handle, error: error)
                }
            }
        }
    }

    private static func fileName(inRemotePath path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func failDownload(handle: UInt32, error: Error) {
        guard let waiter = downloadWaiters.removeValue(forKey: handle) else { return }
        if let root = downloadRoots.removeValue(forKey: handle) {
            try? FileManager.default.removeItem(atPath: root)
        }
        downloadNames.removeValue(forKey: handle)
        waiter.resume(throwing: error)
    }

    /// Resolves a file-promise download from the engine's completion event.
    private func resolveDownload(handle: UInt32, error: String?) {
        guard let waiter = downloadWaiters.removeValue(forKey: handle) else { return }
        let rootPath = downloadRoots.removeValue(forKey: handle)
        let name = downloadNames.removeValue(forKey: handle)
        if let error {
            if let rootPath {
                try? FileManager.default.removeItem(atPath: rootPath)
            }
            waiter.resume(throwing: NSError(
                domain: "app.openscreens",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]
            ))
            return
        }
        guard let rootPath else {
            waiter.resume(throwing: RemoteTransferError.missingDownloadedFile(name ?? ""))
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let expected = name.map { root.appendingPathComponent($0) }
        let local = expected.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? Self.firstItem(in: root)
        if let local {
            waiter.resume(returning: local)
        } else {
            waiter.resume(throwing: RemoteTransferError.missingDownloadedFile(name ?? ""))
        }
    }

    private static func firstItem(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Reports a download that could not start and clears any UI progress.
    private func yieldDownloadFailure(_ message: String) {
        continuation.yield(.failure(message))
        continuation.yield(.downloadComplete(savedPath: nil, error: message))
    }

    /// The first usable local folder: Downloads, then Documents. The folder is
    /// created on demand because iOS does not ship a Downloads directory.
    private func downloadRootDirectory() -> URL? {
        let manager = FileManager.default
        let candidates = [
            manager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            manager.urls(for: .documentDirectory, in: .userDomainMask).first,
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            do {
                try manager.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            } catch {
                logger.error(
                    "could not create \(candidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return nil
    }

    private func handleFileTransfer(subtype: UInt16, handle: UInt32, payload: Data) {
        switch subtype {
        case Self.transferProgressSubtype:
            guard let progress = OpenScreensCore.parseTransferProgress(payload: payload)
            else { return }
            switch progress {
            case .ratio(let value):
                continuation.yield(.transferProgress(
                    name: uploadFileNames[handle],
                    fraction: min(max(value, 0), 1)
                ))
            case .name(let name):
                uploadFileNames[handle] = name
                continuation.yield(.transferProgress(name: name, fraction: nil))
            }
        case Self.transferAckSubtype:
            if let ack = OpenScreensCore.parseTransferAck(payload: payload), !ack.isEmpty {
                logger.info("file transfer ack: \(ack, privacy: .public)")
            }
            continuation.yield(.transferFinished(name: uploadFileNames.removeValue(forKey: handle)))
        default:
            break
        }
    }

    private func startEventPump(_ session: OpenScreensCore.RemoteSession) {
        eventTask = Task { [weak self] in
            while let event = await session.nextEvent() {
                await self?.handle(event, session: session)
            }
            await self?.finish(reason: nil)
        }
    }

    private func handle(
        _ event: OpenScreensCore.SessionEvent,
        session: OpenScreensCore.RemoteSession
    ) {
        switch event {
        case .connected(let width, let height, let name):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.displays([
                RemoteDisplay(id: 0, name: name, width: Int(width), height: Int(height)),
            ]))
            continuation.yield(.state(.connected))

        case .frame(_, let rects):
            guard width > 0, height > 0, displayScale > 0 else { return }
            let scale = Int(displayScale)
            for rect in rects where rect.width > 0 && rect.height > 0 {
                guard let data = session.copyRegionScaled(rect: rect, scale: displayScale)
                else { continue }
                // The renderer only allocates its texture from a full frame, so a
                // rect that covers the whole framebuffer must clear `region`.
                let coversFrame = rect.x == 0 && rect.y == 0
                    && Int(rect.width) == Int(width) && Int(rect.height) == Int(height)
                let region: RemoteRegion?
                if coversFrame {
                    region = nil
                } else {
                    let left = Int(rect.x) / scale
                    let top = Int(rect.y) / scale
                    let right = (Int(rect.x) + Int(rect.width) - 1) / scale
                    let bottom = (Int(rect.y) + Int(rect.height) - 1) / scale
                    region = RemoteRegion(
                        x: left,
                        y: top,
                        width: right - left + 1,
                        height: bottom - top + 1
                    )
                }
                continuation.yield(.frame(RemoteFrame(
                    width: scaledWidth,
                    height: scaledHeight,
                    region: region,
                    data: data
                )))
            }

        case .resized(let width, let height):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.displays([
                RemoteDisplay(
                    id: 0,
                    name: NSLocalizedString("Display", comment: "Fallback display name"),
                    width: Int(width),
                    height: Int(height)
                ),
            ]))

        case .desktopLayout(let width, let height, let screens):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.displays(screens.map { screen in
                RemoteDisplay(
                    id: Int(screen.id),
                    name: String(
                        format: NSLocalizedString("Display %lld", comment: "Fallback display name with index"),
                        Int64(screen.id)
                    ),
                    width: Int(screen.width),
                    height: Int(screen.height)
                )
            }))

        case .clipboard(let text):
            lastRemoteClipboard = text
            continuation.yield(.clipboard(text))

        case .clipboardRequest:
            handleClipboardRequest()

        case .bell:
            continuation.yield(.bell)

        case .cursor(let hotspotX, let hotspotY, let width, let height, let pixels):
            let shape = scaledCursor(
                hotspotX: hotspotX,
                hotspotY: hotspotY,
                width: width,
                height: height,
                pixels: pixels
            )
            continuation.yield(.cursor(shape))

        case .pointerPosition(let x, let y):
            guard width > 0, height > 0 else { return }
            continuation.yield(.pointerPosition(
                x: Double(x) / Double(width),
                y: Double(y) / Double(height)
            ))

        case .uploadRequest(let handle, let path):
            guard let urls = pendingUploads.removeValue(forKey: handle) else { return }
            Task {
                await self.performUpload(
                    handle: handle,
                    destination: path,
                    urls: urls,
                    session: session
                )
            }

        case .dragOutInfo(let handle, let files):
            resolveDragOut(
                handle: handle,
                files: files.map {
                    OpenScreensUI.RemoteFile(url: $0.url, path: $0.path, name: $0.name)
                }
            )

        case .fileTransfer(let subtype, let handle, let payload):
            handleFileTransfer(subtype: subtype, handle: handle, payload: payload)

        case .downloadProgress(let handle, let name, let bytes, let total):
            guard downloadRoots[handle] != nil else { return }
            continuation.yield(.downloadProgress(
                name: name,
                received: Int64(clamping: bytes),
                total: Int64(clamping: total)
            ))

        case .downloadComplete(let handle, let files, let directories, let bytes, let error):
            // A file promise consumes the result directly instead of showing
            // the "saved to Downloads" completion alert.
            if downloadWaiters[handle] != nil {
                resolveDownload(handle: handle, error: error)
                return
            }
            guard let root = downloadRoots.removeValue(forKey: handle) else { return }
            if let error {
                logger.error("download \(handle) failed: \(error, privacy: .public)")
                continuation.yield(.failure(String(
                    format: NSLocalizedString("Download failed: %@", comment: "Download error"),
                    error
                )))
                continuation.yield(.downloadComplete(savedPath: nil, error: error))
            } else {
                logger.info(
                    "downloaded \(files) file(s), \(directories) folder(s), \(bytes) bytes to \(root, privacy: .public)"
                )
                continuation.yield(.downloadComplete(savedPath: root, error: nil))
            }

        case .disconnected(let kind, let reason):
            finish(reason: reason, kind: kind.remoteKind)
        }
    }

    private func startInputPump(_ session: OpenScreensCore.RemoteSession) {
        let stream = inputStream
        inputTask = Task {
            for await command in stream {
                do {
                    switch command {
                    case .pointer(let mask, let x, let y):
                        try await session.sendPointer(mask: mask, x: x, y: y)
                    case .scroll(let x, let y, let stepsX, let stepsY):
                        try await session.sendScroll(x: x, y: y, stepsX: stepsX, stepsY: stepsY)
                    case .key(let down, let keysym):
                        try await session.sendKey(down: down, keysym: keysym)
                    case .clipboard(let text):
                        try await session.sendClipboard(text: text)
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func finish(reason: String?, kind: RemoteFailureKind = .unknown) {
        guard !finished else { return }
        finished = true
        pendingUploads.removeAll()
        uploadFileNames.removeAll()
        downloadRoots.removeAll()
        for task in dragOutTimeouts.values {
            task.cancel()
        }
        dragOutTimeouts.removeAll()
        for (_, waiter) in dragOutWaiters {
            waiter.resume(returning: [])
        }
        dragOutWaiters.removeAll()
        for (_, waiter) in downloadWaiters {
            waiter.resume(throwing: RemoteTransferError.notConnected)
        }
        downloadWaiters.removeAll()
        downloadNames.removeAll()
        continuation.yield(.state(.disconnected(reason: reason, kind: kind)))
        continuation.finish()
        eventTask?.cancel()
        eventTask = nil
        inputTask?.cancel()
        inputTask = nil
        inputContinuation.finish()
        session = nil
    }

    private func updateSize(_ size: OpenScreensCore.SessionSize?) {
        guard let size else { return }
        width = size.width
        height = size.height
        updateDisplayScale()
    }

    private func updateDisplayScale() {
        guard width > 0, height > 0 else {
            displayScale = 1
            scaledWidth = 0
            scaledHeight = 0
            return
        }
        var scale = max(1, min(8, Int(width) / Self.displayTargetWidth))
        scale = max(
            scale,
            (Int(width) + Self.maxTextureDimension - 1) / Self.maxTextureDimension,
            (Int(height) + Self.maxTextureDimension - 1) / Self.maxTextureDimension
        )
        scale = min(Self.maxSamplingScale, scale)
        displayScale = UInt16(scale)
        scaledWidth = (Int(width) + scale - 1) / scale
        scaledHeight = (Int(height) + scale - 1) / scale
        logger.info(
            "display sampling 1/\(scale) (\(self.scaledWidth)x\(self.scaledHeight)) for \(self.width)x\(self.height)"
        )
    }

    private func scaledCursor(
        hotspotX: UInt16,
        hotspotY: UInt16,
        width: UInt16,
        height: UInt16,
        pixels: Data
    ) -> RemoteCursorShape {
        let scale = Int(displayScale)
        let sourceWidth = Int(width)
        let sourceHeight = Int(height)
        guard scale > 1, sourceWidth > 0, sourceHeight > 0,
              pixels.count >= sourceWidth * sourceHeight * 4
        else {
            return RemoteCursorShape(
                hotspotX: Int(hotspotX),
                hotspotY: Int(hotspotY),
                width: sourceWidth,
                height: sourceHeight,
                bgraPixels: pixels
            )
        }

        let destWidth = (sourceWidth + scale - 1) / scale
        let destHeight = (sourceHeight + scale - 1) / scale
        let source = [UInt8](pixels)
        var output = [UInt8](repeating: 0, count: destWidth * destHeight * 4)
        for y in 0..<destHeight {
            let sourceY = y * scale
            guard sourceY < sourceHeight else { continue }
            for x in 0..<destWidth {
                let sourceX = x * scale
                guard sourceX < sourceWidth else { continue }
                let s = (sourceY * sourceWidth + sourceX) * 4
                let d = (y * destWidth + x) * 4
                output[d] = source[s]
                output[d + 1] = source[s + 1]
                output[d + 2] = source[s + 2]
                output[d + 3] = source[s + 3]
            }
        }
        return RemoteCursorShape(
            hotspotX: Int(hotspotX) / scale,
            hotspotY: Int(hotspotY) / scale,
            width: destWidth,
            height: destHeight,
            bgraPixels: Data(output)
        )
    }

    private static func bit(for button: PointerButton) -> UInt8 {
        switch button {
        case .left: 1 << 0
        case .middle: 1 << 1
        case .right: 1 << 2
        }
    }

    private func debugPassword() -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["OPENSCREENS_PASSWORD"]
        #else
        return nil
        #endif
    }
}
