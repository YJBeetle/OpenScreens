package com.openscreens.app.session

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.util.Log
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SshAuthMode
import com.openscreens.app.data.SshKey
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import uniffi.rfb_ffi.Rect
import uniffi.rfb_ffi.SessionConfig
import uniffi.rfb_ffi.SessionFailure
import uniffi.rfb_ffi.SessionFailureKind
import uniffi.rfb_ffi.SshAuthConfig
import uniffi.rfb_ffi.DisplayScreen as NativeDisplayScreen
import uniffi.rfb_ffi.SessionEvent as NativeEvent
import uniffi.rfb_ffi.RemoteSession as NativeSession
import uniffi.rfb_ffi.TransferEntry as NativeTransferEntry
import uniffi.rfb_ffi.TransferEntryKind as NativeKind
import uniffi.rfb_ffi.TransferProgress as NativeProgress
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
    private val context: Context,
    private val connection: Connection,
    private var quality: QualityPreset,
    private val sshKey: SshKey?,
    startInObserveMode: Boolean,
) : RemoteSession {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // A single consumer keeps FFI sends ordered even when a call suspends.
    private val inputQueue = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    @Volatile
    private var inputMode = InputMode(startInObserveMode)

    // Accessed only by the input consumer.
    private var inputTarget: NativeSession? = null
    private val heldKeys = mutableSetOf<Int>()
    private var heldPointer: Pair<Int, Int>? = null

    private class InputMode(val observing: Boolean)

    // Transfer requests and completion events must survive bursts of frame updates.
    private val _events = MutableSharedFlow<SessionEvent>(
        replay = 1,
        extraBufferCapacity = 8,
        // Preserve clipboard and lifecycle events even when the canvas is busy.
    )
    override val events: Flow<SessionEvent> = _events.asSharedFlow()

    @Volatile
    private var session: NativeSession? = null

    @Volatile private var clipboardSharing = connection.sharedClipboard
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

    // Coverage of the pending viewport, in COVERAGE_CELL-sized cells. Apple's
    // Adaptive DCT splits one update into many rectangles, so "first frame that
    // fills the viewport" has to be judged by the union of painted rectangles.
    private var coverage = ByteArray(0)
    private var coverageCols = 0
    private var coverageRows = 0
    private var coverageRemaining = 0

    init {
        scope.launch {
            for (command in inputQueue) {
                command()
            }
        }
    }

    private var selectedMacSession: MacSessionChoice? = null

    override suspend fun connect(macSessionChoice: MacSessionChoice?) {
        selectedMacSession = macSessionChoice
        open(macSessionChoice)
    }

    override suspend fun reconnect() {
        if (disposed.get()) return
        open(selectedMacSession)
    }

    private suspend fun open(macSessionChoice: MacSessionChoice? = null) = openMutex.withLock {
        if (disposed.get()) return@withLock
        detach()
        if (disposed.get()) return
        _events.emit(SessionEvent.Connecting)

        val ssh = connection.ssh
        val sshAuth = when {
            ssh == null -> null
            ssh.authMode == SshAuthMode.PrivateKey -> {
                val key = sshKey
                if (key == null) {
                    _events.emit(
                        SessionEvent.Failed(context.getString(R.string.session_error_ssh_key_missing)),
                    )
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
            password = connection.vncPassword.ifEmpty { null },
            shared = true,
            localCursor = true,
            quality = when (quality) {
                QualityPreset.Low -> 3u
                QualityPreset.Balanced -> 6u
                QualityPreset.High -> 9u
            },
            frameIntervalMs = 16u,
            wireguardConfig = connection.wireGuardConfig,
            wireguardDnsFallback = true,
            openvpnConfig = connection.openVpnConfig,
            sshHost = ssh?.let { it.host.ifBlank { connection.host } },
            sshPort = ssh?.let { it.port.toUShort() },
            sshUsername = ssh?.username?.ifBlank { null },
            sshAuth = sshAuth,
            sshHostKeyFingerprint = ssh?.hostKeyFingerprint?.ifBlank { null },
        )

        val connected = try {
            if (macSessionChoice == MacSessionChoice.Personal) {
                NativeSession.connectPersonalMacSession(config)
            } else if (macSessionChoice == MacSessionChoice.Share || connection.requestMacSharing) {
                NativeSession.connectRequestingMacSharing(config)
            } else {
                NativeSession.connect(config)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "connect to ${connection.address} failed", error)
            if (error is SessionFailure.Session && error.kind == SessionFailureKind.MAC_SESSION_CHOICE_REQUIRED) {
                _events.emit(SessionEvent.MacSessionChoiceRequired)
            } else {
                _events.emit(failureEvent(error))
            }
            return
        }

        try {
            if (disposed.get()) return
            val size = connected.size()
            if (size == null) {
                _events.emit(
                    SessionEvent.Failed(context.getString(R.string.session_error_no_framebuffer)),
                )
                return
            }

            val width = size.width.toInt()
            val height = size.height.toInt()
            val scale = initialDisplayScale(width, height)
            if (!installViewport(width, height, 0, 0, width, height, scale)) {
                _events.emit(
                    SessionEvent.Failed(
                        context.getString(R.string.session_error_out_of_memory, width, height),
                    ),
                )
                return
            }
            viewportEmitted = true

            try {
                connected.setClipboardSharing(clipboardSharing && !inputMode.observing)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                _events.emit(failureEvent(error))
                return
            }
            session = connected
            _events.emit(SessionEvent.Connected(width, height, connected.supportsCurtainMode()))
            Log.i(
                TAG,
                "connected to ${connection.address} (${connected.serverName()}) at " +
                    "$width x $height, sampling 1/$scale",
            )
            pollJob = scope.launch { poll(connected) }
        } finally {
            // Ownership transfers to the poller only after setup has completed.
            if (pollJob == null) {
                if (session === connected) detach()
                else withContext(NonCancellable) { closeTransport(connected) }
            }
        }
    }

    private val shutdown = scope.launch(start = CoroutineStart.LAZY) {
        try {
            openMutex.withLock { detach() }
        } finally {
            inputQueue.close()
            scope.cancel()
        }
    }

    override suspend fun disconnect() {
        val hadSession = session != null
        close()
        // A pending handshake releases its own transport when it returns.
        if (hadSession) shutdown.join()
        _events.emit(SessionEvent.Disconnected())
    }

    override fun close() {
        disposed.set(true)
        shutdown.start()
    }

    // openMutex serializes detach with publication of a newly connected session.
    private suspend fun detach() {
        val current = session ?: return
        withContext(NonCancellable) {
            val job = pollJob
            pollJob = null
            job?.cancel()
            val drained = CompletableDeferred<Unit>()
            inputQueue.send {
                try {
                    session = null
                    if (inputTarget === current) releaseHeldInput(current)
                } finally {
                    drained.complete(Unit)
                }
            }
            // Closing the Rust writer also wakes any send blocked on a stalled peer.
            if (withTimeoutOrNull(1_000L) { drained.await() } == null) {
                session = null
                current.disconnect()
                drained.await()
            }
            closeTransport(current)
            job?.join()
        }
    }

    private suspend fun closeTransport(current: NativeSession) {
        try {
            current.disconnect()
        } finally {
            current.close()
        }
    }

    @Synchronized
    override fun setObserveMode(enabled: Boolean) {
        if (inputMode.observing == enabled) return
        inputMode = InputMode(enabled)
        val current = session ?: return
        inputQueue.trySend {
            if (session === current) sendInput { current.setClipboardSharing(clipboardSharing && !inputMode.observing) }
        }
        if (!enabled) return

        // Drop old queued input, then release any buttons and keys already sent.
        inputQueue.trySend {
            if (session === current && inputTarget === current) {
                releaseHeldInput(current)
            }
        }
    }

    override fun releaseHeldInput() = enqueueInput { current -> releaseHeldInput(current) }

    private suspend fun releaseHeldInput(current: NativeSession) {
        heldPointer?.let { (x, y) ->
            sendInput { current.sendPointer(mask = 0u, x = x.toUShort(), y = y.toUShort()) }
        }
        for (keysym in heldKeys.reversed()) {
            sendInput { current.sendKey(down = false, keysym = keysym.toUInt()) }
        }
        heldPointer = null
        heldKeys.clear()
        inputTarget = null
    }

    override fun sendPointer(x: Int, y: Int, buttonMask: Int) {
        // The UI maps touches against the full server framebuffer.
        val serverX = x.coerceIn(0, (serverWidth - 1).coerceAtLeast(0))
        val serverY = y.coerceIn(0, (serverHeight - 1).coerceAtLeast(0))
        enqueueInput { current ->
            current.sendPointer(
                mask = buttonMask.toUByte(),
                x = serverX.toUShort(),
                y = serverY.toUShort(),
            )
            heldPointer = if (buttonMask == 0) null else serverX to serverY
        }
    }

    override fun sendKey(keysym: Int, pressed: Boolean) {
        enqueueInput { current ->
            current.sendKey(down = pressed, keysym = keysym.toUInt())
            if (pressed) heldKeys.add(keysym) else heldKeys.remove(keysym)
        }
    }

    override suspend fun sendClipboard(text: String, automatic: Boolean) {
        check(!inputMode.observing)
        if (automatic && !clipboardSharing) return
        checkNotNull(session).sendClipboard(text, automatic)
    }

    private fun enqueueInput(send: suspend (NativeSession) -> Unit) {
        val mode = inputMode
        if (mode.observing || disposed.get()) return
        val current = session ?: return

        inputQueue.trySend {
            // Compare the mode instance so input queued before a quick toggle
            // cannot be replayed when control is restored.
            if (inputMode === mode && session === current) {
                if (inputTarget !== current) {
                    inputTarget = current
                    heldKeys.clear()
                    heldPointer = null
                }
                sendInput { send(current) }
            }
        }
    }

    private suspend fun sendInput(send: suspend () -> Unit) {
        try {
            send()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "remote input failed", error)
        }
    }

    override suspend fun setClipboardSharing(enabled: Boolean) {
        clipboardSharing = enabled
        session?.setClipboardSharing(enabled && !inputMode.observing)
    }

    override suspend fun requestClipboard(): Boolean = checkNotNull(session).requestClipboard()

    override fun nextTransferHandle(): Int =
        session?.nextTransferHandle()?.toInt() ?: 0

    override suspend fun announceUpload(handle: Int, fileUrls: List<String>) {
        uploadSession().announceUpload(handle.toUInt(), fileUrls)
    }

    override suspend fun uploadDestination(handle: Int, folder: String) {
        uploadSession().uploadDestination(handle.toUInt(), folder)
    }

    override suspend fun uploadSummary(
        handle: Int,
        totalBytes: Long,
        files: Int,
        directories: Int,
    ) {
        uploadSession().uploadSummary(
            handle.toUInt(),
            totalBytes.toULong(),
            files.toUInt(),
            directories.toUInt(),
        )
    }

    override suspend fun uploadEntry(handle: Int, entry: TransferEntry) {
        val current = uploadSession()
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
        uploadSession().uploadData(handle.toUInt(), chunk)
    }

    override suspend fun uploadComplete(handle: Int) {
        uploadSession().uploadComplete(handle.toUInt())
    }

    private fun uploadSession(): NativeSession {
        check(!inputMode.observing) { context.getString(R.string.session_observe_mode) }
        return checkNotNull(session)
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

    override suspend fun startDownload(handle: Int, path: String, root: String) {
        Log.i(TAG, "startDownload handle=$handle path=$path root=$root")
        checkNotNull(session).startDownload(handle.toUInt(), path, root)
    }

    override suspend fun requestCurtainMode(enabled: Boolean) {
        check(!inputMode.observing)
        session?.requestCurtainMode(enabled)
    }

    override suspend fun selectDisplay(displayId: Int?) {
        val current = checkNotNull(session)
        current.selectDisplay(displayId?.toUInt())
        check(session === current && !disposed.get())
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
            val unchanged = alignedLeft == viewportX && alignedTop == viewportY &&
                alignedWidth == viewportWidth && alignedHeight == viewportHeight &&
                scale == displayScale && front != null
            if (!unchanged) {
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
                        SessionEvent.Failed(
                            context.getString(R.string.session_error_out_of_memory_viewport),
                        ),
                    )
                    return
                }
                viewportEmitted = false
                Log.d(
                    TAG,
                    "viewport ${alignedLeft},${alignedTop} ${alignedWidth}x$alignedHeight " +
                        "sampling 1/$scale",
                )
            }
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
        var terminal: SessionEvent = SessionEvent.Disconnected()
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
                    is NativeEvent.Clipboard -> _events.emit(SessionEvent.RemoteClipboard(event.text))
                    NativeEvent.Bell -> Log.d(TAG, "remote bell")
                    is NativeEvent.Cursor -> renderCursor(event)
                    is NativeEvent.PointerPosition -> Unit
                    is NativeEvent.UploadRequest ->
                        _events.emit(
                            SessionEvent.UploadRequest(event.handle.toInt(), event.path),
                        )
                    NativeEvent.ClipboardRequest -> if (clipboardSharing) {
                        _events.emit(SessionEvent.ClipboardRequest)
                    }
                    is NativeEvent.DragOutInfo -> Unit
                    is NativeEvent.FileTransfer -> handleFileTransfer(event)
                    is NativeEvent.DownloadProgress ->
                        _events.emit(
                            SessionEvent.DownloadProgress(
                                handle = event.handle.toInt(),
                                name = event.name,
                                bytes = event.bytes.toLong(),
                                total = event.total.toLong(),
                            ),
                        )
                    is NativeEvent.DownloadComplete ->
                        _events.emit(
                            SessionEvent.DownloadComplete(
                                handle = event.handle.toInt(),
                                files = event.files.toInt(),
                                directories = event.directories.toInt(),
                                bytes = event.bytes.toLong(),
                                error = event.error,
                            ),
                        )
                    is NativeEvent.Disconnected -> {
                        Log.i(TAG, "remote closed the session: ${event.reason}")
                        terminal = if (event.kind == SessionFailureKind.UNKNOWN || event.kind == SessionFailureKind.CLOSED) {
                            SessionEvent.Disconnected(failureText(event.kind, event.reason))
                        } else {
                            failureEvent(event.kind, failureText(event.kind, event.reason))
                        }
                        break
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Log.w(TAG, "session poll failed", error)
            if (!disposed.get()) _events.emit(failureEvent(error))
            return
        }
        if (!disposed.get()) _events.emit(terminal)
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
                SessionEvent.Failed(
                    context.getString(R.string.session_error_out_of_memory, width, height),
                ),
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
        resetCoverage()
        return true
    }

    private fun resetCoverage() {
        coverageCols = ceilDiv(viewportWidth, COVERAGE_CELL)
        coverageRows = ceilDiv(viewportHeight, COVERAGE_CELL)
        coverage = ByteArray(coverageCols * coverageRows)
        coverageRemaining = coverageCols * coverageRows
    }

    private fun markCovered(left: Int, top: Int, right: Int, bottom: Int) {
        if (coverageRemaining <= 0) return
        val clippedRight = minOf(right, viewportX + viewportWidth)
        val clippedBottom = minOf(bottom, viewportY + viewportHeight)
        if (clippedRight <= left || clippedBottom <= top) return
        val firstCol = ((left - viewportX) / COVERAGE_CELL).coerceIn(0, coverageCols - 1)
        val lastCol = ((clippedRight - 1 - viewportX) / COVERAGE_CELL).coerceIn(0, coverageCols - 1)
        val firstRow = ((top - viewportY) / COVERAGE_CELL).coerceIn(0, coverageRows - 1)
        val lastRow = ((clippedBottom - 1 - viewportY) / COVERAGE_CELL).coerceIn(0, coverageRows - 1)
        for (row in firstRow..lastRow) {
            for (col in firstCol..lastCol) {
                val index = row * coverageCols + col
                if (coverage[index].toInt() == 0) {
                    coverage[index] = 1
                    coverageRemaining--
                }
            }
        }
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
            val destWidth = (right - 1) / scale - left / scale + 1
            if (destWidth <= 0) continue

            // Convert in horizontal bands: a 6K framebuffer update can be tens
            // of megabytes, and converting it in one IntArray exceeds the
            // Android heap (the bitmap itself is downsampled).
            val rowsPerBand = maxOf(1, MAX_SCRATCH_PIXELS / destWidth)
            val bandSourceHeight = rowsPerBand * scale
            var bandTop = top
            var painted = false
            while (bandTop < bottom) {
                val bandBottom = minOf(bottom, bandTop + bandSourceHeight)
                val destTop = bandTop / scale - viewportY / scale
                val destHeight = (bandBottom - 1) / scale - bandTop / scale + 1
                val count = destWidth * destHeight
                if (destTop >= 0 && destLeft >= 0 &&
                    destTop + destHeight <= target.height &&
                    destLeft + destWidth <= target.width &&
                    count > 0
                ) {
                    val pixels = connected.copyRegionScaled(
                        rect = rect(left, bandTop, right - left, bandBottom - bandTop),
                        scale = scale.toUShort(),
                    )
                    if (pixels != null && pixels.size >= count * 4) {
                        val argb = scratchFor(count)
                        bgraBytesToArgb(pixels, count, argb)
                        target.setPixels(
                            argb,
                            0,
                            destWidth,
                            destLeft,
                            destTop,
                            destWidth,
                            destHeight,
                        )
                        painted = true
                        wrote = true
                    }
                }
                bandTop = bandBottom
            }
            if (painted && !viewportEmitted) {
                markCovered(left, top, right, bottom)
            }
        }
        if (!wrote) return

        if (!viewportEmitted) {
            if (coverageRemaining > 0) return
            viewportEmitted = true
            val previous = front
            front = target
            back = previous ?: target
            _events.emit(
                SessionEvent.Viewport(
                    x = viewportX,
                    y = viewportY,
                    width = viewportWidth,
                    height = viewportHeight,
                    scale = scale,
                ),
            )
            _events.emit(SessionEvent.Frame(event.sequence.toLong(), target))
            return
        }

        val previous = front
        front = target
        back = previous ?: target
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

    private fun failureEvent(error: Exception): SessionEvent.Failed = when (error) {
        is SessionFailure.Session -> failureEvent(error.kind, failureText(error.kind, error.reason))
        else -> SessionEvent.Failed(error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName)
    }

    private fun failureEvent(kind: SessionFailureKind, reason: String): SessionEvent.Failed {
        val challenge = when (kind) {
            SessionFailureKind.MISSING_USERNAME -> CredentialChallenge.MissingUsername
            SessionFailureKind.MISSING_PASSWORD -> CredentialChallenge.MissingPassword
            SessionFailureKind.AUTHENTICATION_FAILED -> CredentialChallenge.Rejected
            else -> null
        }
        val retryable = kind == SessionFailureKind.NETWORK || kind == SessionFailureKind.CONNECTION_REFUSED ||
            kind == SessionFailureKind.CLOSED
        return SessionEvent.Failed(reason, challenge, retryable)
    }

    private fun failureText(kind: SessionFailureKind, reason: String): String = when (kind) {
        SessionFailureKind.MAC_SESSION_CHOICE_REQUIRED -> context.getString(R.string.session_mac_choice_hint)
        SessionFailureKind.UNKNOWN -> reason
        SessionFailureKind.NETWORK -> context.getString(R.string.session_failure_network)
        SessionFailureKind.CONNECTION_REFUSED ->
            context.getString(R.string.session_failure_connection_refused)
        SessionFailureKind.MISSING_USERNAME ->
            context.getString(R.string.session_failure_missing_username)
        SessionFailureKind.MISSING_PASSWORD ->
            context.getString(R.string.session_failure_missing_password)
        SessionFailureKind.AUTHENTICATION_FAILED ->
            context.getString(R.string.session_failure_authentication)
        SessionFailureKind.UNSUPPORTED_VERSION ->
            context.getString(R.string.session_failure_unsupported_version)
        SessionFailureKind.UNSUPPORTED_SECURITY_TYPE ->
            context.getString(R.string.session_failure_unsupported_security)
        SessionFailureKind.PROTOCOL -> context.getString(R.string.session_failure_protocol)
        SessionFailureKind.DECODE -> context.getString(R.string.session_failure_decode)
        SessionFailureKind.TUNNEL -> context.getString(R.string.session_failure_tunnel)
        SessionFailureKind.SSH_TUNNEL -> context.getString(R.string.session_failure_ssh_tunnel)
        SessionFailureKind.CLOSED -> context.getString(R.string.session_failure_closed)
        SessionFailureKind.INVALID_INPUT ->
            context.getString(R.string.session_failure_invalid_input)
    }

    private companion object {
        const val TAG = "UniFfiRemoteSession"

        // The first paint assumes a phone-width target; the UI then sends its
        // exact pixel width through setViewport. The budget keeps a viewport
        // bitmap under ~16 MB.
        const val INITIAL_TARGET_WIDTH = 1080
        const val MAX_VIEWPORT_PIXELS = 6_000_000L
        const val MAX_DISPLAY_SCALE = 16
        const val MAX_SCRATCH_PIXELS = 1_000_000
        // Cell size (source pixels) for the first-paint coverage grid.
        const val COVERAGE_CELL = 64
    }
}

// BGRA bytes are ARGB_8888's little-endian memory layout, so one bulk
// IntBuffer copy replaces a per-pixel conversion loop.
internal fun bgraBytesToArgb(pixels: ByteArray, count: Int, out: IntArray) {
    ByteBuffer.wrap(pixels).order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(out, 0, count)
}
