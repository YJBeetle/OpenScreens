package com.openscreens.app.session

import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import java.nio.ByteBuffer
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
import kotlinx.coroutines.withContext
import uniffi.rfb_ffi.Rect
import uniffi.rfb_ffi.SessionConfig
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

    private var pollJob: Job? = null

    // Rotating framebuffer pair. Written only by the poller; handed to the UI as
    // immutable-by-contract [SessionEvent.Frame] snapshots.
    private var front: Bitmap? = null
    private var back: Bitmap? = null

    // Reused conversion buffer so partial updates do not allocate per rectangle.
    private var scratch = IntArray(0)

    // Reused buffer for carrying the previous frame into the back buffer.
    private var copyBuffer: ByteBuffer? = null

    override suspend fun connect() {
        closed.set(false)
        _events.emit(SessionEvent.Connecting)

        val config = SessionConfig(
            host = connection.host,
            port = connection.port.toUShort(),
            username = connection.username.ifBlank { null },
            password = connection.vncPassword.ifBlank { null },
            shared = true,
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
        withContext(Dispatchers.Default) { allocate(width, height) }

        session = connected
        _events.emit(SessionEvent.Connected(width, height))
        Log.i(TAG, "connected to ${connection.address} (${connected.serverName()}) at $width x $height")
        pollJob = scope.launch { poll(connected) }
    }

    override suspend fun disconnect() {
        closed.set(true)
        val job = pollJob
        pollJob = null
        job?.cancelAndJoin()

        val current = session
        session = null
        current?.let { runCatching { it.close() }.onFailure { error -> Log.w(TAG, "close failed", error) } }

        _events.emit(SessionEvent.Disconnected)
        scope.cancel()
    }

    override fun sendPointer(x: Int, y: Int, buttonMask: Int) {
        val current = session ?: return
        scope.launch(inputDispatcher) {
            runCatching {
                current.sendPointer(
                    mask = buttonMask.toUByte(),
                    x = x.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
                    y = y.coerceIn(0, UShort.MAX_VALUE.toInt()).toUShort(),
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

    private suspend fun applySize(width: Int, height: Int) {
        if (width == front?.width && height == front?.height) return
        withContext(Dispatchers.Default) { allocate(width, height) }
        _events.emit(SessionEvent.Resized(width, height))
    }

    private suspend fun renderFrame(connected: NativeSession, event: NativeEvent.Frame) {
        val target = back ?: front ?: return
        // The poller rotates buffers, so the target starts as the previous frame;
        // otherwise incremental updates would be painted on a stale (often black)
        // bitmap. A full-frame update overwrites everything and skips the copy.
        val coversFrame = event.rects.any { rect ->
            rect.x == 0.toUShort() && rect.y == 0.toUShort() &&
                rect.width.toInt() == target.width && rect.height.toInt() == target.height
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
            if (left + rectWidth > target.width || top + rectHeight > target.height) continue

            val pixels = connected.copyRegion(rect) ?: continue
            val count = rectWidth * rectHeight
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
            target.setPixels(argb, 0, rectWidth, left, top, rectWidth, rectHeight)
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
        val needed = source.byteCount
        val buffer = copyBuffer?.takeIf { it.capacity() >= needed }
            ?: ByteBuffer.allocateDirect(needed).also { copyBuffer = it }
        buffer.clear()
        source.copyPixelsToBuffer(buffer)
        buffer.rewind()
        target.copyPixelsFromBuffer(buffer)
    }

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
    }
}
