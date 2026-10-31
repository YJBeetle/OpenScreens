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

public struct UniFfiSessionService: OpenScreensUI.RemoteSessionService {
    public init() {}

    public func makeSession() -> any OpenScreensUI.RemoteSessionProtocol {
        UniFfiRemoteSession()
    }
}

private enum InputCommand: Sendable {
    case pointer(mask: UInt8, x: UInt16, y: UInt16)
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

    /// Files announced to the server, keyed by their transfer handle. The
    /// server answers a drag-in with `.uploadRequest(handle:path:)`.
    private var pendingUploads: [UInt32: [URL]] = [:]
    /// Last file name seen for an upload, so a bare ack can clear the UI.
    private var uploadFileNames: [UInt32: String] = [:]
    /// Local destination folder for each download, keyed by transfer handle.
    private var downloadRoots: [UInt32: String] = [:]

    private let logger = Logger(subsystem: "app.openscreens", category: "Session")
    private static let displayTargetWidth = 2560
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
                    "SSH and WireGuard cannot be used together. Choose one.",
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
        inputContinuation.yield(.clipboard(text))
    }

    public func requestClipboard() async {}

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
            continuation.yield(.clipboard(text))

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

        case .dragInfo:
            // Drags out of the remote desktop are not exposed by the UI yet.
            break

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

        case .disconnected(let reason):
            finish(reason: reason)
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

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        pendingUploads.removeAll()
        uploadFileNames.removeAll()
        downloadRoots.removeAll()
        continuation.yield(.state(.disconnected(reason: reason)))
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
        let scale = max(1, min(8, Int(width) / Self.displayTargetWidth))
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
