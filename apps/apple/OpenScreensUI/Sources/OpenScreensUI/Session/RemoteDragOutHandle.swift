#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small draggable control that starts an Apple drag-out sequence. Dragging
/// it to Finder (or any drop target) offers the remote file URLs as file
/// promises; each promise downloads its file through the session engine only
/// when the drop is accepted.
public struct RemoteDragOutHandle: NSViewRepresentable {
    private let model: SessionViewModel

    public init(model: SessionViewModel) {
        self.model = model
    }

    public func makeNSView(context: Context) -> RemoteDragOutSourceView {
        let view = RemoteDragOutSourceView()
        view.onRequestFiles = { @MainActor [weak model] in
            guard let model else { return [] }
            return await model.beginDragOut()
        }
        view.onDownload = { @MainActor [weak model] file, directory in
            guard let model else { throw RemoteTransferError.notConnected }
            return try await model.downloadRemoteFile(file, toDirectory: directory)
        }
        return view
    }

    public func updateNSView(_ nsView: RemoteDragOutSourceView, context: Context) {}
}

/// The AppKit drag source. A mouse-down asks the server for its drag
/// pasteboard; when the file list arrives (normally within a few hundred
/// milliseconds) the pending mouse-down starts a native dragging session.
@MainActor
final class RemoteDragOutSourceView: NSView, NSDraggingSource {
    typealias FileRequest = @MainActor () async -> [RemoteFile]
    typealias FileDownload = @MainActor @Sendable (RemoteFile, URL) async throws -> URL

    var onRequestFiles: FileRequest?
    var onDownload: FileDownload?

    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("Drag Out", comment: "Drag-out handle"))
    private let iconView = NSImageView()
    private var requestTask: Task<Void, Never>?
    private var mouseDownEvent: NSEvent?
    private var mouseIsDown = false
    private var preparing = false
    private var promiseDelegates: [RemoteFilePromise] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

        iconView.image = NSImage(
            systemSymbolName: "hand.draw",
            accessibilityDescription: NSLocalizedString("Drag remote files", comment: "Drag-out handle")
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.stringValue = NSLocalizedString("Drag Out", comment: "Drag-out handle")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)

        setAccessibilityRole(.button)
        setAccessibilityLabel(NSLocalizedString("Drag remote files out", comment: "Drag-out handle"))
        setAccessibilityHelp(NSLocalizedString(
            "Drag to Finder to copy files from the remote computer.",
            comment: "Drag-out handle help"
        ))
        toolTip = NSLocalizedString(
            "Drag to Finder to copy files from the remote computer.",
            comment: "Drag-out handle help"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RemoteDragOutSourceView is only created programmatically")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 112, height: 38)
    }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 18
        iconView.frame = NSRect(
            x: 12,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(
            x: iconView.frame.maxX + 7,
            y: (bounds.height - titleLabel.frame.height) / 2,
            width: bounds.width - iconView.frame.maxX - 19,
            height: titleLabel.frame.height
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard !preparing else { return }
        mouseDownEvent = event
        mouseIsDown = true
        preparing = true
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let files = await self.onRequestFiles?() ?? []
            self.preparing = false
            guard self.mouseIsDown, let event = self.mouseDownEvent else { return }
            guard !files.isEmpty else {
                NSSound.beep()
                self.setAccessibilityValue(NSLocalizedString("No remote files", comment: "Drag-out handle"))
                return
            }
            self.beginDrag(files: files, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseIsDown = false
        mouseDownEvent = nil
        preparing = false
    }

    private func beginDrag(files: [RemoteFile], event: NSEvent) {
        mouseIsDown = false
        mouseDownEvent = nil

        let delegates = files.map { RemoteFilePromise(file: $0, download: onDownload) }
        var items: [NSDraggingItem] = []
        items.reserveCapacity(delegates.count)
        for delegate in delegates {
            let provider = NSFilePromiseProvider(
                fileType: Self.fileType(for: delegate.file.name).identifier,
                delegate: delegate
            )
            delegate.provider = provider
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(bounds, contents: Self.dragImage(count: files.count))
            items.append(item)
        }
        promiseDelegates = delegates
        beginDraggingSession(with: items, event: event, source: self)
    }

    private static func fileType(for name: String) -> UTType {
        let pathExtension = (name as NSString).pathExtension
        if !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) {
            return type
        }
        return .data
    }

    private static func dragImage(count: Int) -> NSImage {
        let size = NSSize(width: 44, height: 44)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 9, yRadius: 9).fill()
            let symbol = NSImage(
                systemSymbolName: count > 1 ? "doc.on.doc.fill" : "doc.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            symbol?.draw(
                in: NSRect(x: 10, y: 11, width: 24, height: 22),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Nothing was dropped: no promise was requested, so no engine download
        // has started. In-flight promise writes finish on their own.
        if operation.isEmpty {
            setAccessibilityValue(NSLocalizedString("Drag out cancelled", comment: "Drag-out handle"))
        } else {
            setAccessibilityValue(NSLocalizedString("Files copied", comment: "Drag-out handle"))
        }
    }
}

/// Writes one promised remote file by downloading it on demand.
@MainActor
final class RemoteFilePromise: NSObject, NSFilePromiseProviderDelegate {
    nonisolated let file: RemoteFile
    nonisolated let download: RemoteDragOutSourceView.FileDownload?
    weak var provider: NSFilePromiseProvider?

    init(file: RemoteFile, download: RemoteDragOutSourceView.FileDownload?) {
        self.file = file
        self.download = download
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        file.name
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let file = self.file
        let download = self.download
        let completion = CompletionBox(handler: completionHandler)
        Task { @MainActor in
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenScreensPromise-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: temporary,
                    withIntermediateDirectories: true
                )
                guard let download else { throw RemoteTransferError.unsupported }
                let local = try await download(file, temporary)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: local, to: url)
                try? FileManager.default.removeItem(at: temporary)
                completion.handler(nil)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                completion.handler(error)
            }
        }
    }
}

/// Carries AppKit's completion block across the MainActor hop.
private final class CompletionBox: @unchecked Sendable {
    let handler: (Error?) -> Void

    init(handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }
}
#endif
