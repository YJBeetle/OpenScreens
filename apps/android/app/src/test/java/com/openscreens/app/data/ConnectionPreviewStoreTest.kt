package com.openscreens.app.data

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ConnectionPreviewStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun independentWritersRefreshReadersAndThumbnailsSurviveReopen() {
        val directory = temporary.newFolder()
        val saved = setOf("server-a", "server-b", "older-record")
        val store = ConnectionPreviewStore(directory, initiallyEnabled = true, isSaved = saved::contains)
        val black = image(0, 0, 0)
        val red = image(255, 0, 0)
        val originalVersion = store.state.value.version("server-a")!!
        assertNull(store.read("server-a", originalVersion))

        assertTrue(store.write(store.beginCapture("server-a")!!, black))
        assertTrue(store.write(store.beginCapture("server-b")!!, red))
        assertNull(store.read("server-a", originalVersion))
        assertArrayEquals(black, store.read("server-a", store.state.value.version("server-a")!!))

        val reopened = ConnectionPreviewStore(directory, initiallyEnabled = true, isSaved = saved::contains)
        val preview = reopened.read("server-a", reopened.state.value.version("server-a")!!)
        assertArrayEquals(black, preview)
        assertArrayEquals(red, reopened.read("server-b", reopened.state.value.version("server-b")!!))
        assertNull(reopened.read("older-record", reopened.state.value.version("older-record")!!))
    }

    @Test
    fun disabledBlocksReadsAndInFlightWritesAcrossDisableAndReenable() {
        val directory = temporary.newFolder()
        val store = ConnectionPreviewStore(directory, initiallyEnabled = true) { true }
        val original = image(0, 0, 255)
        val replacement = image(0, 255, 0)
        assertTrue(store.write(store.beginCapture("server")!!, original))
        val oldVersion = store.state.value.version("server")!!
        val pending = store.beginCapture("server")!!

        store.setEnabled(false)
        assertNull(store.state.value.version("server"))
        assertNull(store.read("server", oldVersion))
        assertNull(store.beginCapture("server"))
        assertFalse(store.write(pending, replacement))

        val reopenedDisabled = ConnectionPreviewStore(directory, initiallyEnabled = false) { true }
        assertNull(reopenedDisabled.state.value.version("server"))
        assertNull(reopenedDisabled.beginCapture("server"))
        reopenedDisabled.setEnabled(true)
        assertArrayEquals(original, reopenedDisabled.read("server", reopenedDisabled.state.value.version("server")!!))

        store.setEnabled(true)
        assertFalse(store.write(pending, replacement))
        assertArrayEquals(original, store.read("server", store.state.value.version("server")!!))
    }

    @Test
    fun lateWritesCannotReplaceNewerPicturesOrRecreateADeletedConnection() {
        val saved = mutableSetOf("a", "b")
        val directory = temporary.newFolder()
        val store = ConnectionPreviewStore(directory, initiallyEnabled = true, isSaved = saved::contains)
        val older = store.beginCapture("a")!!
        val newer = store.beginCapture("a")!!
        val blue = image(0, 0, 255)
        val red = image(255, 0, 0)
        assertTrue(store.write(newer, blue))
        assertFalse(store.write(older, red))
        assertArrayEquals(blue, store.read("a", store.state.value.version("a")!!))
        assertTrue(store.write(store.beginCapture("b")!!, red))

        val inFlight = store.beginCapture("a")!!
        saved.remove("a")
        store.delete("a")
        assertFalse(store.write(inFlight, blue))
        assertNull(store.beginCapture("a"))
        assertArrayEquals(red, store.read("b", store.state.value.version("b")!!))
        assertTrue(directory.listFiles().orEmpty().size == 1)
    }

    @Test
    fun emptyOrFailedCaptureLeavesTheStoredPreview() {
        val store = ConnectionPreviewStore(temporary.newFolder(), initiallyEnabled = true) { true }
        val original = image(255, 0, 255)
        assertTrue(store.write(store.beginCapture("server")!!, original))
        assertFalse(store.write(store.beginCapture("server")!!, byteArrayOf()))
        assertArrayEquals(original, store.read("server", store.state.value.version("server")!!))
    }

    // Tiny synthetic PPM fixtures exercise persistence independent of Android's encoder.
    private fun image(red: Int, green: Int, blue: Int): ByteArray =
        ByteArrayOutputStream().use { bytes ->
            bytes.write("P6\n32 18\n255\n".toByteArray())
            repeat(32 * 18) {
                bytes.write(red)
                bytes.write(green)
                bytes.write(blue)
            }
            bytes.toByteArray()
        }
}
