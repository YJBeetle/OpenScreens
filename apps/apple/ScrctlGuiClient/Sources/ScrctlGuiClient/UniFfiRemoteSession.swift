import CoreGraphics
import Foundation
import ScrctlGuiCanvas
import ScrctlGuiCore
import ScrctlGuiUI
import os

/// The production transport: drives the Rust RFB engine through UniFFI.
private struct SessionSetupError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private extension ScrctlGuiCore.SessionFailureKind {
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
        case .macSessionChoiceRequired: .macSessionChoiceRequired
        case .macCredentialsRequired: .macCredentialsRequired
        case .macGuestRequestFailed: .macGuestRequestFailed
        }
    }
}

public struct UniFfiSessionService: ScrctlGuiUI.RemoteSessionService {
    public init() {}

    public func makeSession() -> any ScrctlGuiUI.RemoteSessionProtocol {
        UniFfiRemoteSession()
    }
}

private enum InputCommand: Sendable {
    case pointer(mask: UInt8, x: UInt16, y: UInt16)
    case scroll(x: UInt16, y: UInt16, stepsX: Int32, stepsY: Int32)
    case key(down: Bool, keysym: UInt32)
}

/// A regular file described for the Apple drag-and-drop upload protocol.
private struct UploadFile: Sendable {
    let url: URL
    let name: String
    let size: UInt64
    let entry: ScrctlGuiCore.TransferEntry
}

public actor UniFfiRemoteSession: ScrctlGuiUI.RemoteSessionProtocol {
    public nonisolated let events: AsyncStream<ScrctlGuiUI.RemoteSessionEvent>

    private let continuation: AsyncStream<ScrctlGuiUI.RemoteSessionEvent>.Continuation
    private nonisolated let inputContinuation: AsyncStream<InputCommand>.Continuation
    private let inputStream: AsyncStream<InputCommand>

    private var session: ScrctlGuiCore.RemoteSession?
    private var eventTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

    private var width: UInt16 = 0
    private var height: UInt16 = 0
    // Frames delivered before the first viewport are sampled down so a 6K host
    // does not allocate a full-resolution texture per frame. Once a viewport is
    // active the renderer only holds the visible crop.
    private var displayScale: UInt16 = 1
    private var scaledWidth = 0
    private var scaledHeight = 0
    /// Crop retained in the render texture.
    private var viewport: ScrctlGuiUI.RemoteViewport?
    private var needsViewportBaseline = false
    #if DEBUG
    private var receivedDesktopLayout = false
    #endif
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var buttonMask: UInt8 = 0
    private var observing = false
    private var connecting: ScrctlGuiCore.ConnectionAttempt?
    private var finished = false
    private var sharedClipboard = true
    /// Callers waiting for the 0x20 drag info that answers a 0x0E drag-out.
    private var dragOutWaiters: [UInt32: CheckedContinuation<[ScrctlGuiUI.RemoteFile], Never>] = [:]
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
    private static let maxViewportPixels = 6_000_000
    private static let uploadChunkSize = 64 * 1024
    /// POSIX 0100644: a plain file owned by the uploading user.
    private static let uploadFileMode: UInt16 = 0o100644
    private static let epoch1904Offset: UInt64 = 2_082_844_800
    private static let transferProgressSubtype: UInt16 = 0x00C8
    private static let transferAckSubtype: UInt16 = 0x012C

    private let downloadDirectory: URL?

    public init() {
        self.init(downloadDirectory: nil)
    }

    init(downloadDirectory: URL?) {
        self.downloadDirectory = downloadDirectory
        let (stream, continuation) = AsyncStream.makeStream(
            of: ScrctlGuiUI.RemoteSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation

        let (input, inputContinuation) = AsyncStream.makeStream(of: InputCommand.self)
        self.inputStream = input
        self.inputContinuation = inputContinuation
    }

    public func connect(profile: ConnectionProfile, password: String?, macSessionChoice: MacSessionChoice?) async throws {
        guard session == nil, connecting == nil, !finished else { return }
        observing = profile.controls.startInObserveMode
        sharedClipboard = profile.controls.sharedClipboard
        cursor = CGPoint(x: 0.5, y: 0.5)
        buttonMask = 0
        viewport = nil
        needsViewportBaseline = false
        continuation.yield(.state(.connecting))

        let sessionPassword: String?
        if macSessionChoice == .guest {
            sessionPassword = nil
        } else if let password {
            sessionPassword = password
        } else if profile.authentication == .none {
            sessionPassword = nil
        } else {
            sessionPassword = OpenScreensCredentials.password(for: profile.id) ?? debugPassword()
        }
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)

        var sshHost: String?
        var sshPort: UInt16?
        var sshUsername: String?
        var sshAuth: ScrctlGuiCore.SshAuthConfig?
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

        let config = ScrctlGuiCore.SessionConfig(
            host: profile.trimmedHost,
            port: UInt16(clamping: profile.port),
            username: username.isEmpty ? nil : username,
            password: (sessionPassword?.isEmpty == false) ? sessionPassword : nil,
            shared: true,
            localCursor: true,
            quality: profile.initialQuality.jpegLevel,
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

        let target: MacSessionTarget?
        if macSessionChoice == .guest {
            target = .guest
        } else if macSessionChoice == .personal {
            target = .personal
        } else if macSessionChoice == .share {
            target = .shared
        } else {
            target = nil
        }
        let attempt = ScrctlGuiCore.ConnectionAttempt()
        connecting = attempt
        defer { connecting = nil }
        do {
            let session = try await withTaskCancellationHandler {
                try await attempt.connect(config: config, target: target)
            } onCancel: {
                attempt.cancel()
            }
            guard !finished, !Task.isCancelled else { throw CancellationError() }
            try await session.setClipboardSharing(enabled: sharedClipboard && !observing)
            guard !finished, !Task.isCancelled else { throw CancellationError() }
            self.session = session
            continuation.yield(.curtainModeSupport(session.supportsCurtainMode()))
            continuation.yield(.serverFeatures(
                appleRemote: session.isAppleRemote(),
                fileUpload: session.supportsFileUpload(),
                fileDownload: session.supportsFileDownload()
            ))
            updateSize(session.size())
            continuation.yield(.framebufferSize(width: Int(width), height: Int(height)))
            continuation.yield(.state(.connected))
            startEventPump(session)
            startInputPump(session)
        } catch {
            if Task.isCancelled || finished { throw CancellationError() }
            logger.error("connect failed: \(error.localizedDescription, privacy: .public)")
            if case let ScrctlGuiCore.SessionFailure.Session(kind, reason) = error {
                throw RemoteSessionFailure(kind: kind.remoteKind, reason: reason)
            }
            throw error
        }
    }

    public func disconnect() async {
        connecting?.cancel()
        let reason = NSLocalizedString("Connection closed", comment: "Session disconnect reason")
        guard let native = session else {
            finish(reason: reason)
            return
        }
        // Drain accepted button/key releases. If the peer has stopped reading,
        // close the native writer to unblock a send waiting for queue capacity.
        inputContinuation.finish()
        let drainDeadline = Task {
            try await Task.sleep(for: .seconds(1))
            await native.disconnect()
        }
        await inputTask?.value
        drainDeadline.cancel()
        // Stop observing transport events while the reader shuts down, then
        // discard incomplete downloads after the transport stops writing.
        eventTask?.cancel()
        await native.disconnect()
        finish(reason: reason)
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
        if buttonMask == 0 {
            inputContinuation.yield(.scroll(x: x, y: y, stepsX: stepsX, stepsY: stepsY))
        } else {
            // The plain wheel helper releases to mask zero. During a drag each
            // wheel pulse must instead restore all physically held buttons.
            for (steps, negative, positive): (Int32, UInt8, UInt8) in [(stepsY, 8, 16), (stepsX, 32, 64)] {
                for _ in 0..<min(steps.magnitude, 32) {
                    inputContinuation.yield(.pointer(mask: buttonMask | (steps < 0 ? negative : positive), x: x, y: y))
                    inputContinuation.yield(.pointer(mask: buttonMask, x: x, y: y))
                }
            }
        }
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

    public func setClipboardSharing(_ enabled: Bool) async throws {
        sharedClipboard = enabled
        try await session?.setClipboardSharing(enabled: enabled && !observing)
    }

    public func sendClipboard(_ text: String, automatic: Bool) async throws {
        guard let session, !finished, !observing else { throw RemoteTransferError.notConnected }
        guard !automatic || sharedClipboard else { return }
        do {
            try await session.sendClipboard(text: text, automatic: automatic)
        } catch ScrctlGuiCore.SessionFailure.Session(let kind, let reason) {
            throw RemoteSessionFailure(kind: kind.remoteKind, reason: reason)
        }
    }

    public func requestClipboard() async throws -> Bool {
        guard let session, !finished else { throw RemoteTransferError.notConnected }
        return try await session.requestClipboard()
    }

    public func setObserveMode(_ observing: Bool) async {
        self.observing = observing
        try? await session?.setClipboardSharing(enabled: sharedClipboard && !observing)
    }

    public func setQuality(_ quality: ConnectionQuality) async throws {
        guard let session else { throw RemoteSessionFailure(kind: .closed, reason: "The session is closed.") }
        try await session.setQuality(level: quality.jpegLevel)
    }

    public func requestCurtainMode(_ enabled: Bool) async {
        guard let session, !observing, !finished else { return }
        do {
            try await session.requestCurtainMode(enabled: enabled)
        } catch {
            continuation.yield(.failure(error.localizedDescription))
        }
    }

    public func selectDisplay(_ id: Int?) async throws {
        guard let session, !finished else { throw CancellationError() }
        let displayID = id.flatMap { UInt32(exactly: $0) }
        guard id == nil || displayID != nil else {
            throw SessionSetupError(NSLocalizedString("Invalid display ID.", comment: "Display switch error"))
        }
        try await session.selectDisplay(displayId: displayID)
    }

    public func requestRefresh() async throws {
        guard let session, !finished else { throw CancellationError() }
        try await session.requestRefresh()
    }

    /// Samples the visible region into a bounded render texture. The wire
    /// subscription stays full-frame so desktop damage continues while zoomed.
    public func setViewport(_ normalizedRect: CGRect?, screenPixelWidth: Int) async {
        guard let session, !finished, width > 0, height > 0 else { return }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let fraction = (normalizedRect ?? unit).intersection(unit)
        guard fraction.width > 0, fraction.height > 0 else { return }

        let fullWidth = Int(width)
        let fullHeight = Int(height)
        let visible = CGRect(
            x: (fraction.minX * CGFloat(fullWidth)).rounded(.down),
            y: (fraction.minY * CGFloat(fullHeight)).rounded(.down),
            width: (fraction.width * CGFloat(fullWidth)).rounded(.up),
            height: (fraction.height * CGFloat(fullHeight)).rounded(.up)
        ).integral.intersection(CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        guard visible.width >= 1, visible.height >= 1 else { return }

        // Keep a little slack around the visible area for panning.
        let margin = max(64, Int(visible.width) / 12)
        let expandedLeft = max(0, Int(visible.minX) - margin)
        let expandedTop = max(0, Int(visible.minY) - margin)
        let expandedRight = min(fullWidth, Int(visible.maxX) + margin)
        let expandedBottom = min(fullHeight, Int(visible.maxY) + margin)
        guard expandedRight > expandedLeft, expandedBottom > expandedTop else { return }

        var scale = max(1, Int(visible.width) / max(1, screenPixelWidth))
        scale = max(
            scale,
            (fullWidth + Self.maxTextureDimension - 1) / Self.maxTextureDimension,
            (fullHeight + Self.maxTextureDimension - 1) / Self.maxTextureDimension
        )
        scale = min(Self.maxSamplingScale, scale)
        func bufferPixels(_ divisor: Int) -> Int {
            let w = (expandedRight - expandedLeft + divisor - 1) / divisor
            let h = (expandedBottom - expandedTop + divisor - 1) / divisor
            return w * h
        }
        while scale < Self.maxSamplingScale && bufferPixels(scale) > Self.maxViewportPixels {
            scale += 1
        }

        // Align outward to the sampling grid so server rects map to the crop
        // without gaps.
        let alignedLeft = (expandedLeft / scale) * scale
        let alignedTop = (expandedTop / scale) * scale
        let alignedRight = min(fullWidth, ((expandedRight + scale - 1) / scale) * scale)
        let alignedBottom = min(fullHeight, ((expandedBottom + scale - 1) / scale) * scale)
        let alignedWidth = alignedRight - alignedLeft
        let alignedHeight = alignedBottom - alignedTop
        guard alignedWidth > 0, alignedHeight > 0 else { return }

        let next = ScrctlGuiUI.RemoteViewport(
            x: alignedLeft,
            y: alignedTop,
            width: alignedWidth,
            height: alignedHeight,
            scale: scale,
            bufferWidth: (alignedWidth + scale - 1) / scale,
            bufferHeight: (alignedHeight + scale - 1) / scale,
            framebufferWidth: fullWidth,
            framebufferHeight: fullHeight
        )
        guard next != viewport else { return }
        viewport = next
        needsViewportBaseline = true
        logger.info(
            "viewport \(next.x),\(next.y) \(next.width)x\(next.height) sampling 1/\(next.scale)"
        )

        do {
            // A crop change needs an initial refresh, then incremental updates
            // must cover the whole desktop. Some servers stop delivering damage
            // after the first response to a cropped subscription.
            try await session.setViewport(x: 0, y: 0, width: 0, height: 0)
        } catch {
            logger.warning("set viewport failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - File upload

    /// Announces dropped files to the server. The upload itself starts when
    /// the server answers with an `.uploadRequest` carrying the destination.
    public func uploadFiles(_ urls: [URL]) async {
        guard let session, !observing, !finished else { return }
        let files = urls.filter(Self.isUploadable)
        guard !files.isEmpty else {
            continuation.yield(.failure(NSLocalizedString(
                "Only regular files can be sent to the remote computer.",
                comment: "Upload error"
            )))
            continuation.yield(.transferFinished(names: [], destination: ""))
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
            continuation.yield(.transferFinished(names: [], destination: ""))
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
        session: ScrctlGuiCore.RemoteSession
    ) async {
        defer { uploadFileNames.removeValue(forKey: handle) }
        let files = urls.compactMap(Self.describeUpload)
        guard !files.isEmpty else {
            try? await session.cancelTransfer(handle: handle)
            continuation.yield(.failure(NSLocalizedString(
                "The dropped items could not be read.",
                comment: "Upload error"
            )))
            continuation.yield(.transferFinished(names: [], destination: ""))
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
            guard !finished else { return }
            logger.info(
                "uploaded \(files.count) file(s), \(sentBytes) bytes to \(destination, privacy: .public)"
            )
            continuation.yield(.transferFinished(names: files.map(\.name), destination: destination))
        } catch {
            logger.error("upload failed: \(error.localizedDescription, privacy: .public)")
            try? await session.cancelTransfer(handle: handle)
            continuation.yield(.failure(String(
                format: NSLocalizedString("File transfer failed: %@", comment: "Upload error"),
                error.localizedDescription
            )))
            continuation.yield(.transferFinished(names: [], destination: ""))
        }
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
            entry: ScrctlGuiCore.TransferEntry(
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
        guard let directory = downloadDirectory ?? downloadRootDirectory() else {
            yieldDownloadFailure(NSLocalizedString("No local folder is available for downloads.", comment: "Download error"))
            return
        }

        let handle = session.nextTransferHandle()
        // A fresh directory lets completion identify exactly what this request saved.
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            downloadRoots[handle] = root.path
            try await session.startDownload(handle: handle, path: path, root: root.path)
            logger.info(
                "download started handle=\(handle) path=\(path, privacy: .public) root=\(root.path, privacy: .public)"
            )
        } catch {
            if downloadRoots.removeValue(forKey: handle) != nil {
                try? FileManager.default.removeItem(at: root)
            }
            let message = error.localizedDescription
            logger.error("download failed: \(message, privacy: .public)")
            continuation.yield(.failure(String(
                format: NSLocalizedString("Could not download “%@”: %@", comment: "Download error"),
                path,
                message
            )))
            // Also closes the in-flight status in the UI.
            continuation.yield(.downloadComplete(items: [], error: message))
        }
    }

    // MARK: - Drag out

    /// Sends Apple message 0x0E and waits for the 0x20 drag info. The server
    /// answers with the file URLs on its current drag pasteboard.
    public func beginDragOut() async -> [ScrctlGuiUI.RemoteFile] {
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

    private func resolveDragOut(handle: UInt32, files: [ScrctlGuiUI.RemoteFile]) {
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
        continuation.yield(.downloadComplete(items: [], error: message))
    }

    private func downloadRootDirectory() -> URL? {
        let manager = FileManager.default
        #if os(iOS)
        // Files exposes the app's Documents directory under On My iPhone/iPad.
        return manager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downloads", isDirectory: true)
        #else
        return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenScreens", isDirectory: true)
        #endif
    }

    private func handleFileTransfer(subtype: UInt16, handle: UInt32, payload: Data) {
        switch subtype {
        case Self.transferProgressSubtype:
            guard uploadFileNames[handle] != nil,
                  let progress = ScrctlGuiCore.parseTransferProgress(payload: payload)
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
            if let ack = ScrctlGuiCore.parseTransferAck(payload: payload), !ack.isEmpty {
                logger.info("file transfer ack: \(ack, privacy: .public)")
            }
        default:
            break
        }
    }

    private func startEventPump(_ session: ScrctlGuiCore.RemoteSession) {
        eventTask = Task { [weak self] in
            while !Task.isCancelled, let event = await session.nextEvent() {
                guard !Task.isCancelled, let self else { return }
                await self.handle(event, session: session)
            }
            if !Task.isCancelled { await self?.finish(reason: nil) }
        }
    }

    private func handle(
        _ event: ScrctlGuiCore.SessionEvent,
        session: ScrctlGuiCore.RemoteSession
    ) {
        switch event {
        case .connected(let width, let height, _):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.framebufferSize(width: Int(width), height: Int(height)))
            continuation.yield(.state(.connected))

        case .frame(let sequence, let rects):
            #if DEBUG
            if CanvasPresentation.isEnabled, sequence == 1 {
                logger.info("Received first RFB pixel update with \(rects.count) damage rectangles")
            }
            #endif
            guard width > 0, height > 0 else { return }
            if let viewport {
                if needsViewportBaseline {
                    // A server can split the refresh into several rectangles. Build
                    // the complete crop before replacing the texture and its geometry.
                    guard !rects.isEmpty, let data = session.copyRegionScaled(
                        rect: ScrctlGuiCore.Rect(
                            x: UInt16(viewport.x), y: UInt16(viewport.y),
                            width: UInt16(viewport.width), height: UInt16(viewport.height)
                        ),
                        scale: UInt16(viewport.scale)
                    ) else { return }
                    needsViewportBaseline = false
                    continuation.yield(.frame(RemoteFrame(
                        width: viewport.bufferWidth, height: viewport.bufferHeight,
                        data: data, sequence: sequence, viewport: viewport
                    )))
                    return
                }
                let scale = viewport.scale
                for rect in rects where rect.width > 0 && rect.height > 0 {
                    let left = max(Int(rect.x), viewport.x)
                    let top = max(Int(rect.y), viewport.y)
                    let right = min(Int(rect.x) + Int(rect.width), viewport.x + viewport.width)
                    let bottom = min(Int(rect.y) + Int(rect.height), viewport.y + viewport.height)
                    guard right > left, bottom > top else { continue }

                    let destLeft = left / scale - viewport.x / scale
                    let destTop = top / scale - viewport.y / scale
                    let destRight = (right - 1) / scale - viewport.x / scale
                    let destBottom = (bottom - 1) / scale - viewport.y / scale
                    let destWidth = destRight - destLeft + 1
                    let destHeight = destBottom - destTop + 1
                    guard destWidth > 0, destHeight > 0 else { continue }

                    guard let data = session.copyRegionScaled(
                        rect: ScrctlGuiCore.Rect(
                            x: UInt16(left),
                            y: UInt16(top),
                            width: UInt16(right - left),
                            height: UInt16(bottom - top)
                        ),
                        scale: UInt16(scale)
                    ) else { continue }

                    let coversViewport = left <= viewport.x && top <= viewport.y
                        && right >= viewport.x + viewport.width
                        && bottom >= viewport.y + viewport.height
                    let region: RemoteRegion? = coversViewport ? nil : RemoteRegion(
                        x: destLeft,
                        y: destTop,
                        width: destWidth,
                        height: destHeight
                    )
                    continuation.yield(.frame(RemoteFrame(
                        width: viewport.bufferWidth,
                        height: viewport.bufferHeight,
                        region: region,
                        data: data,
                        sequence: sequence,
                        viewport: viewport
                    )))
                }
                return
            }

            guard displayScale > 0 else { return }
            let scale = Int(displayScale)
            for rect in rects where rect.width > 0 && rect.height > 0 {
                guard let data = session.copyRegionScaled(rect: rect, scale: displayScale)
                else { continue }
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
                    data: data,
                    sequence: sequence
                )))
            }

        case .resized(let width, let height):
            self.width = width
            self.height = height
            viewport = nil
            needsViewportBaseline = false
            updateDisplayScale()
            continuation.yield(.framebufferSize(width: Int(width), height: Int(height)))

        case .desktopLayout(let width, let height, let screens):
            #if DEBUG
            if CanvasPresentation.isEnabled, !receivedDesktopLayout {
                logger.info("Received first desktop layout: \(width)x\(height), \(screens.count) displays")
                receivedDesktopLayout = true
            }
            #endif
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.framebufferSize(width: Int(width), height: Int(height)))
            continuation.yield(.displays(screens.map { screen in
                RemoteDisplay(
                    id: Int(screen.id),
                    name: String(
                        format: NSLocalizedString("Display %lld", comment: "Fallback display name with index"),
                        Int64(screen.id)
                    ),
                    width: Int(screen.width),
                    height: Int(screen.height),
                    origin: CGPoint(x: Int(screen.x), y: Int(screen.y))
                )
            }))

        case .clipboard(let text):
            continuation.yield(.clipboard(text))

        case .clipboardRequest:
            guard sharedClipboard, !observing else { return }
            continuation.yield(.clipboardRequest)

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
                    ScrctlGuiUI.RemoteFile(url: $0.url, path: $0.path, name: $0.name)
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
                try? FileManager.default.removeItem(atPath: root)
                logger.error("download \(handle) failed: \(error, privacy: .public)")
                continuation.yield(.failure(String(
                    format: NSLocalizedString("Download failed: %@", comment: "Download error"),
                    error
                )))
                continuation.yield(.downloadComplete(items: [], error: error))
            } else {
                logger.info(
                    "downloaded \(files) file(s), \(directories) folder(s), \(bytes) bytes to \(root, privacy: .public)"
                )
                do {
                    let directory = URL(fileURLWithPath: root, isDirectory: true)
                    let items = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                    ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    guard !items.isEmpty else {
                        try? FileManager.default.removeItem(at: directory)
                        yieldDownloadFailure(NSLocalizedString("No items were saved.", comment: "Download error"))
                        return
                    }
                    continuation.yield(.downloadComplete(items: items, error: nil))
                } catch {
                    yieldDownloadFailure(error.localizedDescription)
                }
            }

        case .disconnected(let kind, let reason):
            finish(reason: reason, kind: kind.remoteKind)
        }
    }

    private func startInputPump(_ session: ScrctlGuiCore.RemoteSession) {
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
        viewport = nil
        needsViewportBaseline = false
        pendingUploads.removeAll()
        uploadFileNames.removeAll()
        for root in downloadRoots.values {
            try? FileManager.default.removeItem(atPath: root)
        }
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

    private func updateSize(_ size: ScrctlGuiCore.SessionSize?) {
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
        #if os(macOS)
        let scale = Int(displayScale)
        #else
        // Mobile cursors are drawn at a fixed UI size, independent of framebuffer sampling.
        let scale = 1
        #endif
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
