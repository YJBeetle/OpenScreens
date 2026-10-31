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

    /**
     * Restarts the transport after it went stale, e.g. when the app returns from
     * the background. Implementations must keep the same instance and event flow.
     */
    suspend fun reconnect()

    suspend fun disconnect()

    /** Releases the transport for good; the instance is not reusable afterwards. */
    fun close()

    fun sendPointer(x: Int, y: Int, buttonMask: Int)

    fun sendKey(keysym: Int, pressed: Boolean)

    fun sendClipboard(text: String)

    suspend fun copyRegion(x: Int, y: Int, width: Int, height: Int): ByteArray

    fun setQuality(quality: QualityPreset)

    /**
     * Restricts server updates to the visible framebuffer region (server
     * pixels) and sizes the stored bitmap for an on-screen width of
     * [screenPixelWidth] pixels.
     */
    suspend fun setViewport(x: Int, y: Int, width: Int, height: Int, screenPixelWidth: Int)

    fun nextTransferHandle(): Int

    suspend fun announceUpload(handle: Int, fileUrls: List<String>)

    suspend fun uploadDestination(handle: Int, folder: String)

    suspend fun uploadSummary(handle: Int, totalBytes: Long, files: Int, directories: Int)

    suspend fun uploadEntry(handle: Int, entry: TransferEntry)

    suspend fun uploadData(handle: Int, chunk: ByteArray)

    suspend fun uploadComplete(handle: Int)

    suspend fun cancelTransfer(handle: Int)

    suspend fun startDragOut(handle: Int)

    suspend fun requestDownload(handle: Int, path: String)

    suspend fun startDownload(handle: Int, path: String, root: String)

    suspend fun selectDisplay(displayId: Int?)
}

data class DisplayScreen(
    val id: Int,
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
    val flags: Int,
)

enum class TransferEntryKind { File, Directory, Symlink }

/** Metadata for one file, directory or symlink in an Apple file transfer. */
data class TransferEntry(
    val kind: TransferEntryKind,
    val name: String,
    val dataSize: Long,
    val resourceSize: Long,
    val mode: Int,
    val nesting: Int,
    val created: Long,
    val accessed: Long,
    val changed: Long,
    val modified: Long,
    val finderInfo: ByteArray,
    val linkTarget: String?,
)

sealed interface SessionEvent {
    data object Connecting : SessionEvent
    data class Connected(val width: Int, val height: Int) : SessionEvent
    data class Resized(val width: Int, val height: Int) : SessionEvent

    data class DesktopLayout(
        val width: Int,
        val height: Int,
        val screens: List<DisplayScreen>,
    ) : SessionEvent

    /**
     * A completed framebuffer update. [sequence] increases with every update so Compose
     * recomposes even though [bitmap] is reused between frames; treat the pixels as
     * read-only, the session may be drawing the next frame into a different buffer.
     */
    data class Frame(val sequence: Long, val bitmap: Bitmap) : SessionEvent

    /** A client-side cursor bitmap supplied through the Cursor pseudo-encoding. */
    data class Cursor(val bitmap: Bitmap, val hotspotX: Int, val hotspotY: Int) : SessionEvent

    /** The framebuffer region currently stored in [Frame] bitmaps, in server
     * pixels. Frames outside this region are not delivered. */
    data class Viewport(
        val x: Int,
        val y: Int,
        val width: Int,
        val height: Int,
        val scale: Int,
    ) : SessionEvent

    /** The server asks the client to upload into [path] (Apple drag-in). */
    data class UploadRequest(val handle: Int, val path: String) : SessionEvent

    /** The server offered its pasteboard for a drag-out. */
    data class DragInfo(val handle: Int, val fileUrls: List<String>) : SessionEvent

    data class TransferProgress(
        val handle: Int,
        val ratio: Double?,
        val name: String?,
    ) : SessionEvent

    data class TransferComplete(val handle: Int, val message: String) : SessionEvent

    /** Text copied on the remote machine, to mirror into the local clipboard. */
    data class RemoteClipboard(val text: String) : SessionEvent

    data class DownloadProgress(
        val handle: Int,
        val name: String?,
        val bytes: Long,
        val total: Long,
    ) : SessionEvent

    data class DownloadComplete(
        val handle: Int,
        val files: Int,
        val directories: Int,
        val bytes: Long,
        val error: String?,
    ) : SessionEvent

    /** A raw Apple transfer container, kept for the download flow. */
    class FileTransfer(
        val handle: Int,
        val subtype: Int,
        val payload: ByteArray,
    ) : SessionEvent

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
