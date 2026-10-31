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
import uniffi.rfb_ffi.SessionEvent as NativeEvent
import uniffi.rfb_ffi.RemoteSession as NativeSession

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

    private var pollJob: Job? = null

    // Rotating framebuffer pair. Written only by the poller; handed to the UI as
    // immutable-by-contract [SessionEvent.Frame] snapshots. Bitmaps use the
    // downscaled display size, not the server framebuffer size.
    private var front: Bitmap? = null
    private var back: Bitmap? = null

    // Reused conversion buffer so partial updates do not allocate per rectangle.
    private var scratch = IntArray(0)

    // Server framebuffer size and the sampled size Android keeps in memory.
    private var serverWidth = 0
    private var serverHeight = 0
    private var displayWidth = 0
    private var displayHeight = 0
    private var displayScale = 1

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

        val serverWidth = size.width.toInt()
        val serverHeight = size.height.toInt()
        val scale = displayScaleFor(serverWidth, serverHeight)
        if (!prepareFramebuffer(serverWidth, serverHeight, scale)) {
            connected.close()
            _events.emit(
                SessionEvent.Failed(
                    "Not enough memory to display ${serverWidth}×$serverHeight.",
                ),
            )
            return
        }

        session = connected
        _events.emit(SessionEvent.Connected(displayWidth, displayHeight))
        Log.i(
            TAG,
            "connected to ${connection.address} (${connected.serverName()}) at " +
                "$serverWidth x $serverHeight, showing $displayWidth x $displayHeight (1/$scale)",
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
        // The UI works in downscaled display pixels; the server expects pixels
        // of its own framebuffer.
        val serverX = displayToServer(x, displayScale, serverWidth)
        val serverY = displayToServer(y, displayScale, serverHeight)
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

    private suspend fun poll(connected: NativeSession) {
        try {
            while (true) {
                val event = connected.nextEvent() ?: break
                when (event) {
                    is NativeEvent.Connected -> applySize(event.width.toInt(), event.height.toInt())
                    is NativeEvent.Frame -> renderFrame(connected, event)
                    is NativeEvent.Resized -> applySize(event.width.toInt(), event.height.toInt())
                    is NativeEvent.Clipboard -> Log.d(TAG, "remote clipboard: ${event.text.length} chars")
                    NativeEvent.Bell -> Log.d(TAG, "remote bell")
                    is NativeEvent.Cursor -> renderCursor(event)
                    is NativeEvent.PointerPosition -> Unit
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

    private suspend fun renderCursor(event: NativeEvent.Cursor) {
        val scale = displayScale.coerceAtLeast(1)
        val sourceWidth = event.width.toInt()
        val sourceHeight = event.height.toInt()
        val pixels = event.pixels
        if (sourceWidth <= 0 || sourceHeight <= 0 ||
            pixels.size < sourceWidth * sourceHeight * 4
        ) {
            return
        }

        val width = ceilDiv(sourceWidth, scale)
        val height = ceilDiv(sourceHeight, scale)
        val bitmap = withContext(Dispatchers.Default) {
            val argb = IntArray(width * height)
            val buffer = ByteBuffer.wrap(pixels).order(ByteOrder.LITTLE_ENDIAN)
            val sourcePixels = sourceWidth * sourceHeight
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val source = (y * scale) * sourceWidth + x * scale
                    if (source >= sourcePixels) continue
                    buffer.position(source * 4)
                    val bgra = buffer.getInt()
                    val blue = bgra and 0xFF
                    val green = (bgra ushr 8) and 0xFF
                    val red = (bgra ushr 16) and 0xFF
                    val alpha = (bgra ushr 24) and 0xFF
                    argb[y * width + x] =
                        (alpha shl 24) or (red shl 16) or (green shl 8) or blue
                }
            }
            Bitmap.createBitmap(argb, width, height, Bitmap.Config.ARGB_8888)
                .apply { setHasAlpha(true) }
        }
        _events.emit(
            SessionEvent.Cursor(
                bitmap = bitmap,
                hotspotX = event.hotspotX.toInt() / scale,
                hotspotY = event.hotspotY.toInt() / scale,
            ),
        )
    }

    private suspend fun applySize(width: Int, height: Int) {
        if (width == serverWidth && height == serverHeight && front != null) return
        val scale = displayScaleFor(width, height)
        if (!prepareFramebuffer(width, height, scale)) {
            _events.emit(
                SessionEvent.Failed("Not enough memory to display ${width}×$height."),
            )
            return
        }
        _events.emit(SessionEvent.Resized(displayWidth, displayHeight))
    }

    private suspend fun prepareFramebuffer(
        serverWidth: Int,
        serverHeight: Int,
        scale: Int,
    ): Boolean {
        val displayWidth = ceilDiv(serverWidth, scale)
        val displayHeight = ceilDiv(serverHeight, scale)
        val allocated = withContext(Dispatchers.Default) {
            runCatching { allocate(displayWidth, displayHeight) }.isSuccess
        }
        if (!allocated) {
            Log.w(TAG, "unable to allocate $displayWidth x $displayHeight bitmaps")
            return false
        }
        this.serverWidth = serverWidth
        this.serverHeight = serverHeight
        this.displayWidth = displayWidth
        this.displayHeight = displayHeight
        this.displayScale = scale
        return true
    }

    private suspend fun renderFrame(connected: NativeSession, event: NativeEvent.Frame) {
        val target = back ?: front ?: return
        val scale = displayScale.coerceAtLeast(1)
        // The poller rotates buffers, so the target starts as the previous frame;
        // otherwise incremental updates would be painted on a stale (often black)
        // bitmap. A full-frame update overwrites everything and skips the copy.
        val coversFrame = event.rects.any { rect ->
            rect.x == 0.toUShort() && rect.y == 0.toUShort() &&
                rect.width.toInt() == serverWidth && rect.height.toInt() == serverHeight
        }
        if (!coversFrame) {
            front?.let { copyInto(target, it) }
        }

        for (rect in event.rects) {
            val rectWidth = rect.width.toInt()
            val rectHeight = rect.height.toInt()
            if (rectWidth == 0 || rectHeight == 0) continue

            val left = rect.x.toInt()
            val top = rect.y.toInt()
            if (left + rectWidth > serverWidth || top + rectHeight > serverHeight) continue

            val destLeft = left / scale
            val destTop = top / scale
            val destWidth = (left + rectWidth - 1) / scale - destLeft + 1
            val destHeight = (top + rectHeight - 1) / scale - destTop + 1
            val count = destWidth * destHeight
            if (count <= 0) continue

            val pixels = connected.copyRegionScaled(rect, scale.toUShort()) ?: continue
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

    private fun displayToServer(value: Int, scale: Int, limit: Int): Int {
        if (limit <= 1) return 0
        val step = scale.coerceAtLeast(1)
        val mapped = value.toLong() * step + step / 2
        return mapped.coerceIn(0L, (limit - 1).toLong()).toInt()
    }

    private fun displayScaleFor(width: Int, height: Int): Int {
        var scale = 1
        while (scale < MAX_DISPLAY_SCALE) {
            val w = ceilDiv(width, scale)
            val h = ceilDiv(height, scale)
            val fits = w.toLong() * h <= MAX_DISPLAY_PIXELS &&
                w <= MAX_DISPLAY_DIM && h <= MAX_DISPLAY_DIM
            if (fits) break
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

        // Bounded at roughly a 2560x1440 ARGB frame (16 MB per bitmap) so a
        // 6K Retina Mac cannot exhaust the Android heap.
        const val MAX_DISPLAY_PIXELS = 4_000_000L
        const val MAX_DISPLAY_DIM = 4096
        const val MAX_DISPLAY_SCALE = 16
    }
}
