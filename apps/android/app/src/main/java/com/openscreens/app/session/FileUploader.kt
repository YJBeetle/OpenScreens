package com.openscreens.app.session

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

private const val CHUNK_SIZE = 64 * 1024
private const val EPOCH_1904_OFFSET = 2_082_844_800L
private const val FILE_MODE = 0x81A4 // 0100644

private data class PickedFile(val uri: Uri, val name: String, val size: Long, val temp: File? = null)

/**
 * Uploads the picked documents through the Apple file transfer messages. The
 * caller must have announced the drag-in first; [destination] comes from the
 * server's upload request.
 */
suspend fun uploadPickedFiles(
    session: RemoteSession,
    handle: Int,
    destination: String,
    uris: List<Uri>,
    resolver: ContentResolver,
    cacheDir: File,
    onProgress: (String) -> Unit,
): List<String> = withContext(Dispatchers.IO) {
    val files = mutableListOf<PickedFile>()
    try {
        for (uri in uris) {
            files += describe(resolver, uri, cacheDir)
        }
        if (files.isEmpty()) throw IOException("Unable to read the selected files")
        session.uploadDestination(handle, destination)
        session.uploadSummary(handle, files.sumOf { it.size }, files.size, 0)
        val stamp = ((System.currentTimeMillis() / 1000) + EPOCH_1904_OFFSET) and 0xFFFFFFFFL
        for (file in files) {
            withContext(Dispatchers.Main.immediate) { onProgress(file.name) }
            session.uploadEntry(
                handle,
                TransferEntry(
                    kind = TransferEntryKind.File,
                    name = file.name,
                    dataSize = file.size,
                    resourceSize = 0,
                    mode = FILE_MODE,
                    nesting = 0,
                    created = stamp,
                    accessed = stamp,
                    changed = stamp,
                    modified = stamp,
                    finderInfo = ByteArray(32),
                    linkTarget = null,
                ),
            )
            val input = file.temp?.inputStream() ?: resolver.openInputStream(file.uri)
                ?: throw IOException("cannot open ${file.name}")
            input.use { stream ->
                val buffer = ByteArray(CHUNK_SIZE)
                while (true) {
                    val read = stream.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    session.uploadData(handle, if (read == buffer.size) buffer.copyOf() else buffer.copyOf(read))
                }
            }
        }
        session.uploadComplete(handle)
        files.map { it.name }
    } finally {
        files.forEach { file -> file.temp?.delete() }
    }
}

private fun describe(resolver: ContentResolver, uri: Uri, cacheDir: File): PickedFile {
    var name = "file"
    var size = -1L
    resolver.query(
        uri,
        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
        null,
        null,
        null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                name = cursor.getString(nameIndex)
            }
            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                size = cursor.getLong(sizeIndex)
            }
        }
    }
    if (size >= 0) return PickedFile(uri, name, size)

    // Some providers do not report a size; cache the stream so the summary and
    // the entry description carry the exact byte count.
    val temp = File.createTempFile("openscreens-upload-", null, cacheDir)
    try {
        val input = resolver.openInputStream(uri) ?: throw IOException("cannot open $name")
        input.use { source -> temp.outputStream().use { output -> source.copyTo(output) } }
    } catch (error: Exception) {
        temp.delete()
        throw error
    }
    return PickedFile(Uri.fromFile(temp), name, temp.length(), temp)
}
