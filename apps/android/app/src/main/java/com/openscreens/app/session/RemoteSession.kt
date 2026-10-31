package com.openscreens.app.session

import android.graphics.Bitmap
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SshKey
import kotlinx.coroutines.flow.Flow

/**
 * Everything the UI needs from a remote session. Implementations may be fakes while
 * the Rust core is under construction; the UI only depends on this contract.
 *
 * Pointer coordinates are remote framebuffer pixels. The button mask follows RFB:
 * bit 0 is the primary button, bit 1 secondary, bit 2 middle. Keys use X11 keysyms.
 */
interface RemoteSession {
    val events: Flow<SessionEvent>

    suspend fun connect()

    suspend fun disconnect()

    fun sendPointer(x: Int, y: Int, buttonMask: Int)

    fun sendKey(keysym: Int, pressed: Boolean)

    fun sendClipboard(text: String)

    suspend fun copyRegion(x: Int, y: Int, width: Int, height: Int): ByteArray

    fun setQuality(quality: QualityPreset)
}

sealed interface SessionEvent {
    data object Connecting : SessionEvent
    data class Connected(val width: Int, val height: Int) : SessionEvent
    data class Resized(val width: Int, val height: Int) : SessionEvent

    /**
     * A completed framebuffer update. [sequence] increases with every update so Compose
     * recomposes even though [bitmap] is reused between frames; treat the pixels as
     * read-only, the session may be drawing the next frame into a different buffer.
     */
    data class Frame(val sequence: Long, val bitmap: Bitmap) : SessionEvent

    data object Disconnected : SessionEvent
    data class Failed(val reason: String) : SessionEvent
}

/**
 * The single seam between Compose and the native layer. No screen code depends on
 * how frames are produced, only on [RemoteSession].
 */
object SessionProvider {
    fun create(
        connection: Connection,
        quality: QualityPreset,
        sshKey: SshKey? = null,
    ): RemoteSession = UniFfiRemoteSession(connection, quality, sshKey)
}
