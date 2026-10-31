package com.openscreens.app.session

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.util.Log
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SshAuthMode
import com.openscreens.app.data.SshKey
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.rfb_ffi.Rect
import uniffi.rfb_ffi.SessionConfig
import uniffi.rfb_ffi.SshAuthConfig
import uniffi.rfb_ffi.DisplayScreen as NativeDisplayScreen
import uniffi.rfb_ffi.SessionEvent as NativeEvent
import uniffi.rfb_ffi.RemoteSession as NativeSession
import uniffi.rfb_ffi.TransferEntry as NativeTransferEntry
import uniffi.rfb_ffi.TransferEntryKind as NativeKind
import uniffi.rfb_ffi.TransferProgress as NativeProgress
import uniffi.rfb_ffi.parsePasteboardFileUrls
import uniffi.rfb_ffi.parseTransferAck
import uniffi.rfb_ffi.parseTransferProgress

/**
 * [RemoteSession] backed by the Rust core through the generated UniFFI bindings.
 *
 * The core hands out tightly packed BGRA8888 rectangles. They are repacked into
 * ARGB_8888 ints and written into a software bitmap. Two bitmaps are rotated so the
 * UI can keep drawing one while the poller fills the other.
 */
class UniFfiRemoteSession(
    private val connection: Connection,
    private var quality: QualityPreset,
    private val sshKey: SshKey?,
) : RemoteSession {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Input events must reach the server in the order they were produced: a pointer
    // press before its release, and a modifier before the key it modifies.
    private val inputDispatcher = Dispatchers.IO.limitedParallelism(1)

    private val _events = MutableSharedFlow<SessionEvent>(
        replay = 1,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    override val events: Flow<SessionEvent> = _events.asSharedFlow()

    @Volatile
    private var session: NativeSession? = null

    private val closed = AtomicBoolean(false)
    private val disposed = AtomicBoolean(false)
    private val openMutex = Mutex()
    // Serializes viewport reallocation against frame rendering: the UI may
    // change the crop while the poller is painting the previous buffer.
    private val frameMutex = Mutex()

    private var pollJob: Job? = null

    // Rotating framebuffer pair. Written only by the poller; handed to the UI as
    // immutable-by-contract [SessionEvent.Frame] snapshots. Bitmaps use the
    // downscaled display size, not the server framebuffer size.
    private var front: Bitmap? = null
    private var back: Bitmap? = null

    // Reused conversion buffer so partial updates do not allocate per rectangle.
    private var scratch = IntArray(0)

    // Server framebuffer size and the visible crop Android keeps in memory.
    private var serverWidth = 0
    private var serverHeight = 0
    private var viewportX = 0
    private var viewportY = 0
    private var viewportWidth = 0
    private var viewportHeight = 0
    private var displayScale = 1
    // False while the UI still knows the previous crop; the new geometry is
    // published together with the first frame that fills it.
    private var viewportEmitted = true

    override suspend fun connect() = open()

    override suspend fun reconnect() {
        if (disposed.get()) return
        open()
    }

    private suspend fun open() = openMutex.withLock {
        detach()
        closed.set(false)
        _events.emit(SessionEvent.Connecting)

        val ssh = connection.ssh
        val sshAuth = when {
            ssh == null -> null
            ssh.authMode == SshAuthMode.PrivateKey -> {
                val key = sshKey
                if (key == null) {
                    _events.emit(SessionEvent.Failed("SSH key not found for this connection"))
                    return
                }
                SshAuthConfig.PrivateKey(
                    pem = key.privateKeyPem,
                    passphrase = key.passphrase.ifBlank { null },
                )
            }
            else -> SshAuthConfig.Password(password = ssh.password)
        }
        val config = SessionConfig(
            host = connection.host,
            port = connection.port.toUShort(),
            username = connection.username.ifBlank { null },
            password = connection.vncPassword.ifBlank { null },
            shared = true,
            localCursor = true,
            quality = when (quality) {
                QualityPreset.Low -> 3u
                QualityPreset.Balanced -> 6u
                QualityPreset.High -> 9u
            },
            frameIntervalMs = 16u,
            wireguardConfig = null,
            wireguardDnsFallback = true,
            sshHost = ssh?.let { it.host.ifBlank { connection.host } },
            sshPort = ssh?.let { it.port.toUShort() },
            sshUsername = ssh?.username?.ifBlank { null },
            sshAuth = sshAuth,
            sshHostKeyFingerprint = ssh?.hostKeyFingerprint?.ifBlank { null },
        )

        val connected = try {
            NativeSession.connect(config)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "connect to ${connection.address} failed", error)
            _events.emit(SessionEvent.Failed(describe(error)))
            return
        }

        val size = connected.size()
        if (size == null) {
            connected.close()
            _events.emit(SessionEvent.Failed("Session reported no framebuffer size"))
            return
        }

        val width = size.width.toInt()
        val height = size.height.toInt()
        val scale = initialDisplayScale(width, height)
        if (!installViewport(width, height, 0, 0, width, height, scale)) {
            connected.close()
            _events.emit(
                SessionEvent.Failed("Not enough memory to display ${width}×$height."),
            )
            return
        }
        viewportEmitted = true

        session = connected
        _events.emit(SessionEvent.Connected(width, height))
        Log.i(
            TAG,
            "connected to ${connection.address} (${connected.serverName()}) at " +
                "$width x $height, sampling 1/$scale",
        )
        pollJob = scope.launch { poll(connected) }
    }

    override suspend fun disconnect() {
        if (disposed.get()) return
        closed.set(true)
        detach()
        _events.emit(SessionEvent.Disconnected)
        close()
    }

    override fun close() {
        if (!disposed.compareAndSet(false, true)) return
        closed.set(true)

        val job = pollJob
        pollJob = null
        job?.cancel()

        val current = session
        session = null
        current?.let { runCatching { it.close() }.onFailure { error -> Log.w(TAG, "close failed", error) } }

        scope.cancel()
    }

    private suspend fun detach() {
        val job = pollJob
        pollJob = null
        job?.cancelAndJoin()

        val current = session
        session = null
        current?.let { runCatching { it.close() }.onFailure { error -> Log.w(TAG, "close failed", error) } }
    }

    override fun sendPointer(x: Int, y: Int, buttonMask: Int) {
        val current = session ?: return
        // The UI maps touches against the full server framebuffer.
        val serverX = x.coerceIn(0, (serverWidth - 1).coerceAtLeast(0))
        val serverY = y.coerceIn(0, (serverHeight - 1).coerceAtLeast(0))
        scope.launch(inputDispatcher) {
            runCatching {
                current.sendPointer(
                    mask = buttonMask.toUByte(),
                    x = serverX.toUShort(),
                    y = serverY.toUShort(),
                )
            }.onFailure { error -> Log.w(TAG, "sendPointer failed", error) }
        }
    }

    override fun sendKey(keysym: Int, pressed: Boolean) {
        val current = session ?: return
        scope.launch(inputDispatcher) {
            runCatching { current.sendKey(down = pressed, keysym = keysym.toUInt()) }
                .onFailure { error -> Log.w(TAG, "sendKey failed", error) }
        }
    }

    override fun sendClipboard(text: String) {
        val current = session ?: return
        scope.launch(inputDispatcher) {
            runCatching { current.sendClipboard(text) }
                .onFailure { error -> Log.w(TAG, "sendClipboard failed", error) }
        }
    }

    override fun nextTransferHandle(): Int =
        session?.nextTransferHandle()?.toInt() ?: 0

    override suspend fun announceUpload(handle: Int, fileUrls: List<String>) {
        session?.announceUpload(handle.toUInt(), fileUrls)
    }

    override suspend fun uploadDestination(handle: Int, folder: String) {
        session?.uploadDestination(handle.toUInt(), folder)
    }

    override suspend fun uploadSummary(
        handle: Int,
        totalBytes: Long,
        files: Int,
        directories: Int,
    ) {
        session?.uploadSummary(
            handle.toUInt(),
            totalBytes.toULong(),
            files.toUInt(),
            directories.toUInt(),
        )
    }

    override suspend fun uploadEntry(handle: Int, entry: TransferEntry) {
        val current = session ?: return
        val kind = when (entry.kind) {
            TransferEntryKind.File -> NativeKind.FILE
            TransferEntryKind.Directory -> NativeKind.DIRECTORY
            TransferEntryKind.Symlink -> NativeKind.SYMLINK
        }
        current.uploadEntry(
            handle.toUInt(),
            NativeTransferEntry(
                kind = kind,
                name = entry.name,
                dataSize = entry.dataSize.toULong(),
                resourceSize = entry.resourceSize.toULong(),
                mode = entry.mode.toUShort(),
                nesting = entry.nesting.toUShort(),
                created = entry.created.toUInt(),
                accessed = entry.accessed.toUInt(),
                changed = entry.changed.toUInt(),
                modified = entry.modified.toUInt(),
                finderInfo = entry.finderInfo,
                linkTarget = entry.linkTarget,
            ),
        )
    }

    override suspend fun uploadData(handle: Int, chunk: ByteArray) {
        session?.uploadData(handle.toUInt(), chunk)
    }

    override suspend fun uploadComplete(handle: Int) {
        session?.uploadComplete(handle.toUInt())
    }

    override suspend fun cancelTransfer(handle: Int) {
        session?.cancelTransfer(handle.toUInt())
    }

    override suspend fun startDragOut(handle: Int) {
        session?.startDragOut(handle.toUInt())
    }

    override suspend fun requestDownload(handle: Int, path: String) {
        session?.requestDownload(handle.toUInt(), path)
    }

    override suspend fun selectDisplay(displayId: Int?) {
        session?.selectDisplay(displayId?.toUInt())
    }

    override suspend fun copyRegion(x: Int, y: Int, width: Int, height: Int): ByteArray {
        val current = session ?: return ByteArray(0)
        return withContext(Dispatchers.IO) {
            current.copyRegion(rect(x, y, width, height)) ?: ByteArray(0)
        }
    }

    /**
     * The Rust core picks encodings when the session is established; renegotiating
     * quality mid-session is not exposed yet, so this only records the preference.
     */
    override fun setQuality(quality: QualityPreset) {
        this.quality = quality
        Log.d(TAG, "setQuality ${quality.name} (takes effect on the next connection)")
    }

    override suspend fun setViewport(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        screenPixelWidth: Int,
    ) {
        val current = session ?: return
        if (serverWidth <= 0 || serverHeight <= 0) return

        val left = x.coerceIn(0, serverWidth - 1)
        val top = y.coerceIn(0, serverHeight - 1)
        val right = (x + width.coerceAtLeast(1)).coerceIn(left + 1, serverWidth)
        val bottom = (y + height.coerceAtLeast(1)).coerceIn(top + 1, serverHeight)
        val visibleWidth = right - left
        val visibleHeight = bottom - top
        // One stored pixel per screen pixel keeps zoomed content sharp; the
        // budget guard coarsens only when a single viewport would be too large.
        var scale = (visibleWidth / screenPixelWidth.coerceAtLeast(1)).coerceAtLeast(1)
        // Keep a little slack around the visible area for panning, then align
        // outward to the sampling grid so server rectangles map without gaps.
        val margin = maxOf(64, visibleWidth / 12)
        val expandedLeft = (left - margin).coerceAtLeast(0)
        val expandedTop = (top - margin).coerceAtLeast(0)
        val expandedRight = (right + margin).coerceAtMost(serverWidth)
        val expandedBottom = (bottom + margin).coerceAtMost(serverHeight)
        while (scale < MAX_DISPLAY_SCALE &&
            ceilDiv(expandedRight - expandedLeft, scale).toLong() *
            ceilDiv(expandedBottom - expandedTop, scale) > MAX_VIEWPORT_PIXELS
        ) {
            scale++
        }
        val alignedLeft = (expandedLeft / scale) * scale
        val alignedTop = (expandedTop / scale) * scale
        val alignedRight = minOf(serverWidth, ceilDiv(expandedRight, scale) * scale)
        val alignedBottom = minOf(serverHeight, ceilDiv(expandedBottom, scale) * scale)
        val alignedWidth = alignedRight - alignedLeft
        val alignedHeight = alignedBottom - alignedTop

        val request = frameMutex.withLock {
            if (alignedLeft == viewportX && alignedTop == viewportY &&
                alignedWidth == viewportWidth && alignedHeight == viewportHeight &&
                scale == displayScale && front != null
            ) {
                return
            }

            if (!installViewport(
                    serverWidth,
                    serverHeight,
                    alignedLeft,
                    alignedTop,
                    alignedWidth,
                    alignedHeight,
                    scale,
                )
            ) {
                _events.emit(
                    SessionEvent.Failed("Not enough memory for the visible screen area."),
                )
                return
            }
            viewportEmitted = false
            Log.d(
                TAG,
                "viewport ${alignedLeft},${alignedTop} ${alignedWidth}x$alignedHeight " +
                    "sampling 1/$scale",
            )
            intArrayOf(alignedLeft, alignedTop, alignedWidth, alignedHeight)
        }

        runCatching {
            current.setViewport(
                x = request[0].toUShort(),
                y = request[1].toUShort(),
                width = request[2].toUShort(),
                height = request[3].toUShort(),
            )
        }.onFailure { Log.w(TAG, "setViewport failed", it) }
    }

    private suspend fun poll(connected: NativeSession) {
        try {
            while (true) {
                val event = connected.nextEvent() ?: break
                when (event) {
                    is NativeEvent.Connected -> applySize(event.width.toInt(), event.height.toInt())
                    is NativeEvent.Frame -> renderFrame(connected, event)
                    is NativeEvent.Resized -> applySize(event.width.toInt(), event.height.toInt())
                    is NativeEvent.DesktopLayout -> {
                        applySize(event.width.toInt(), event.height.toInt())
                        _events.emit(
                            SessionEvent.DesktopLayout(
                                width = event.width.toInt(),
                                height = event.height.toInt(),
                                screens = event.screens.map { screen ->
                                    DisplayScreen(
                                        id = screen.id.toInt(),
                                        x = screen.x.toInt(),
                                        y = screen.y.toInt(),
                                        width = screen.width.toInt(),
                                        height = screen.height.toInt(),
                                        flags = screen.flags.toInt(),
                                    )
                                },
                            ),
                        )
                    }
                    is NativeEvent.Clipboard -> Log.d(TAG, "remote clipboard: ${event.text.length} chars")
                    NativeEvent.Bell -> Log.d(TAG, "remote bell")
                    is NativeEvent.Cursor -> renderCursor(event)
                    is NativeEvent.PointerPosition -> Unit
                    is NativeEvent.UploadRequest ->
                        _events.emit(
                            SessionEvent.UploadRequest(event.handle.toInt(), event.path),
                        )
                    is NativeEvent.DragInfo ->
                        _events.emit(
                            SessionEvent.DragInfo(
                                event.handle.toInt(),
                                parsePasteboardFileUrls(event.pasteboard),
                            ),
                        )
                    is NativeEvent.FileTransfer -> handleFileTransfer(event)
                    is NativeEvent.DownloadProgress,
                    is NativeEvent.DownloadComplete,
                    -> Unit
                    is NativeEvent.Disconnected -> {
                        Log.i(TAG, "remote closed the session: ${event.reason}")
                        break
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "session poll failed", error)
            if (!closed.get()) _events.emit(SessionEvent.Failed(describe(error)))
            return
        }
        if (!closed.get()) _events.emit(SessionEvent.Disconnected)
    }

    private suspend fun handleFileTransfer(event: NativeEvent.FileTransfer) {
        val handle = event.handle.toInt()
        when (event.subtype.toInt()) {
            0xC8 -> when (val progress = parseTransferProgress(event.payload)) {
                is NativeProgress.Ratio ->
                    _events.emit(SessionEvent.TransferProgress(handle, progress.value, null))
                is NativeProgress.Name ->
                    _events.emit(SessionEvent.TransferProgress(handle, null, progress.name))
                null -> Unit
            }
            0x12C -> parseTransferAck(event.payload)?.let { message ->
                _events.emit(SessionEvent.TransferComplete(handle, message))
            }
            else -> _events.emit(
                SessionEvent.FileTransfer(handle, event.subtype.toInt(), event.payload),
            )
        }
    }

    private suspend fun renderCursor(event: NativeEvent.Cursor) {
        val width = event.width.toInt()
        val height = event.height.toInt()
        val pixels = event.pixels
        if (width <= 0 || height <= 0 || pixels.size < width * height * 4) return

        // Cursors stay at server resolution: the UI draws them in framebuffer
        // coordinates, so they scale with the view automatically.
        val bitmap = withContext(Dispatchers.Default) {
            val argb = IntArray(width * height)
            val buffer = ByteBuffer.wrap(pixels).order(ByteOrder.LITTLE_ENDIAN)
            for (index in argb.indices) {
                val bgra = buffer.getInt()
                val blue = bgra and 0xFF
                val green = (bgra ushr 8) and 0xFF
                val red = (bgra ushr 16) and 0xFF
                val alpha = (bgra ushr 24) and 0xFF
                argb[index] = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
            }
            Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
                .apply { setHasAlpha(true) }
        }
        _events.emit(
            SessionEvent.Cursor(
                bitmap = bitmap,
                hotspotX = event.hotspotX.toInt(),
                hotspotY = event.hotspotY.toInt(),
            ),
        )
    }

    private suspend fun applySize(width: Int, height: Int) {
        frameMutex.withLock { applySizeLocked(width, height) }
    }

    private suspend fun applySizeLocked(width: Int, height: Int) {
        if (width == serverWidth && height == serverHeight && front != null) return
        val scale = initialDisplayScale(width, height)
        if (!installViewport(width, height, 0, 0, width, height, scale)) {
            _events.emit(
                SessionEvent.Failed("Not enough memory to display ${width}×$height."),
            )
            return
        }
        // The UI resets its crop to the whole framebuffer on resize.
        viewportEmitted = true
        _events.emit(SessionEvent.Resized(width, height))
    }

    private suspend fun installViewport(
        serverWidth: Int,
        serverHeight: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        scale: Int,
    ): Boolean {
        val bitmapWidth = ceilDiv(width, scale)
        val bitmapHeight = ceilDiv(height, scale)
        val allocated = withContext(Dispatchers.Default) {
            runCatching { allocate(bitmapWidth, bitmapHeight) }.isSuccess
        }
        if (!allocated) {
            Log.w(TAG, "unable to allocate $bitmapWidth x $bitmapHeight bitmaps")
            return false
        }
        this.serverWidth = serverWidth
        this.serverHeight = serverHeight
        this.viewportX = x
        this.viewportY = y
        this.viewportWidth = width
        this.viewportHeight = height
        this.displayScale = scale
        return true
    }

    private suspend fun renderFrame(connected: NativeSession, event: NativeEvent.Frame) {
        frameMutex.withLock { renderFrameLocked(connected, event) }
    }

    private suspend fun renderFrameLocked(connected: NativeSession, event: NativeEvent.Frame) {
        val target = back ?: front ?: return
        val scale = displayScale.coerceAtLeast(1)
        // The poller rotates buffers, so the target starts as the previous frame;
        // otherwise incremental updates would be painted on a stale (often black)
        // bitmap. An update that covers the whole viewport, or the first paint of
        // a new viewport, skips the copy.
        val coversViewport = event.rects.any { rect ->
            rect.x.toInt() <= viewportX && rect.y.toInt() <= viewportY &&
                rect.x.toInt() + rect.width.toInt() >= viewportX + viewportWidth &&
                rect.y.toInt() + rect.height.toInt() >= viewportY + viewportHeight
        }
        // A freshly installed viewport starts black; keep showing the previous
        // complete frame until the server has painted the whole new region,
        // otherwise the UI briefly maps a partially filled crop.
        if (!viewportEmitted && !coversViewport) {
            return
        }
        if (!coversViewport && viewportEmitted) {
            front?.let { copyInto(target, it) }
        }

        var wrote = false
        for (rect in event.rects) {
            val left = maxOf(rect.x.toInt(), viewportX)
            val top = maxOf(rect.y.toInt(), viewportY)
            val right = minOf(rect.x.toInt() + rect.width.toInt(), viewportX + viewportWidth)
            val bottom = minOf(rect.y.toInt() + rect.height.toInt(), viewportY + viewportHeight)
            if (right <= left || bottom <= top) continue

            val destLeft = left / scale - viewportX / scale
            val destTop = top / scale - viewportY / scale
            val destWidth = (right - 1) / scale - left / scale + 1
            val destHeight = (bottom - 1) / scale - top / scale + 1
            val count = destWidth * destHeight
            if (count <= 0) continue

            val pixels = connected.copyRegionScaled(
                rect = rect(left, top, right - left, bottom - top),
                scale = scale.toUShort(),
            ) ?: continue
            if (pixels.size < count * 4) continue

            val argb = scratchFor(count)
            var offset = 0
            for (index in 0 until count) {
                val blue = pixels[offset].toInt() and 0xFF
                val green = pixels[offset + 1].toInt() and 0xFF
                val red = pixels[offset + 2].toInt() and 0xFF
                val alpha = pixels[offset + 3].toInt() and 0xFF
                argb[index] = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
                offset += 4
            }
            target.setPixels(argb, 0, destWidth, destLeft, destTop, destWidth, destHeight)
            wrote = true
        }
        if (!wrote) return

        val firstPaint = !viewportEmitted
        val previous = front
        front = target
        back = previous ?: target
        if (firstPaint) {
            viewportEmitted = true
            _events.emit(
                SessionEvent.Viewport(
                    x = viewportX,
                    y = viewportY,
                    width = viewportWidth,
                    height = viewportHeight,
                    scale = scale,
                ),
            )
        }
        _events.emit(SessionEvent.Frame(event.sequence.toLong(), target))
    }

    private fun scratchFor(size: Int): IntArray {
        if (scratch.size < size) scratch = IntArray(size)
        return scratch
    }

    private fun copyInto(target: Bitmap, source: Bitmap) {
        Canvas(target).drawBitmap(source, 0f, 0f, null)
    }

    private fun initialDisplayScale(width: Int, height: Int): Int {
        var scale = (width / INITIAL_TARGET_WIDTH).coerceAtLeast(1)
        while (scale < MAX_DISPLAY_SCALE &&
            ceilDiv(width, scale).toLong() * ceilDiv(height, scale) >
            MAX_VIEWPORT_PIXELS
        ) {
            scale++
        }
        return scale
    }

    private fun ceilDiv(value: Int, divisor: Int): Int =
        (value + divisor - 1) / divisor

    private fun allocate(width: Int, height: Int) {
        val a = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.BLACK)
        }
        val b = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            eraseColor(Color.BLACK)
        }
        front = a
        back = b
    }

    private fun rect(x: Int, y: Int, width: Int, height: Int) = Rect(
        x = x.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
        y = y.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
        width = width.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
        height = height.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
    )

    private fun describe(error: Exception): String =
        error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName

    private companion object {
        const val TAG = "UniFfiRemoteSession"

        // The first paint assumes a phone-width target; the UI then sends its
        // exact pixel width through setViewport. The budget keeps a viewport
        // bitmap under ~16 MB.
        const val INITIAL_TARGET_WIDTH = 1080
        const val MAX_VIEWPORT_PIXELS = 6_000_000L
        const val MAX_DISPLAY_SCALE = 16
    }
}
