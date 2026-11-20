package com.openscreens.app.data

import android.graphics.Bitmap
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

internal class ConnectionPreviewStore(
    private val directory: File,
    initiallyEnabled: Boolean,
    private val isSaved: (String) -> Boolean,
) {
    data class State(
        val enabled: Boolean,
        val generation: Long = 0,
        val revisions: Map<String, Long> = emptyMap(),
    ) {
        fun version(id: String): Version? =
            if (enabled) Version(generation, revisions[id] ?: 0) else null
    }

    data class Version(val generation: Long, val revision: Long)
    data class Capture(val id: String, val generation: Long, val revision: Long)

    private val _state = MutableStateFlow(State(initiallyEnabled))
    val state = _state.asStateFlow()
    private val writer = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sequence = 0L

    @Synchronized
    fun setEnabled(enabled: Boolean) {
        val old = _state.value
        if (old.enabled != enabled) {
            _state.value = old.copy(enabled = enabled, generation = old.generation + 1)
        }
    }

    @Synchronized
    fun beginCapture(id: String): Capture? {
        val current = _state.value
        if (!current.enabled || !isSaved(id)) return null
        return Capture(id, current.generation, ++sequence)
    }

    fun writeAsync(capture: Capture, bitmap: Bitmap): Job = writer.launch {
        if (!isCurrent(capture)) return@launch
        try {
            val encoded = ByteArrayOutputStream()
            if (bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, encoded)) {
                write(capture, encoded.toByteArray())
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not store a connection preview", error)
        }
    }

    @Synchronized
    private fun isCurrent(capture: Capture): Boolean {
        val current = _state.value
        return current.enabled && capture.generation == current.generation &&
            capture.revision > (current.revisions[capture.id] ?: 0) && isSaved(capture.id)
    }

    fun write(capture: Capture, encoded: ByteArray): Boolean {
        if (encoded.isEmpty() || !isCurrent(capture)) return false
        val dest = file(capture.id)
        directory.mkdirs()
        val pending = File.createTempFile("${dest.name}.", ".pending", directory)
        try {
            FileOutputStream(pending).use { stream ->
                stream.write(encoded)
                stream.fd.sync()
            }
            return replace(capture, pending, dest)
        } finally {
            pending.delete()
        }
    }

    @Synchronized
    private fun replace(capture: Capture, pending: File, dest: File): Boolean {
        if (!isCurrent(capture)) return false
        Files.move(
            pending.toPath(),
            dest.toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
        val current = _state.value
        _state.value = current.copy(revisions = current.revisions + (capture.id to capture.revision))
        return true
    }

    @Synchronized
    private fun isReadable(id: String, version: Version): Boolean =
        _state.value.version(id) == version && isSaved(id)

    fun read(id: String, version: Version): ByteArray? {
        if (!isReadable(id, version)) return null
        val path = file(id)
        val bytes = if (path.isFile) path.readBytes() else return null
        return bytes.takeIf { isReadable(id, version) }
    }

    @Synchronized
    fun delete(id: String) {
        val dest = file(id)
        directory.listFiles { _, name -> name.startsWith("${dest.name}.") && name.endsWith(".pending") }
            ?.forEach { it.delete() }
        dest.delete()
        val current = _state.value
        _state.value = current.copy(revisions = current.revisions + (id to ++sequence))
    }

    private fun file(id: String): File {
        val key = MessageDigest.getInstance("SHA-256").digest(id.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(directory, "$key.jpg")
    }

    private companion object {
        const val TAG = "ConnectionPreviewStore"
        const val JPEG_QUALITY = 82
    }
}
