package com.openscreens.app.session

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openscreens.app.data.Connection
import com.openscreens.app.data.ConnectionPreviewStore
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SettingsStore
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConnectionPreviewTransportTest {
    @Test
    fun partialFrameRetainsPreviousImageAndDisconnectCommitsTheLastValidViewport() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val fixtureId = UUID.randomUUID().toString()
        val directory = File(context.noBackupFilesDir, "preview-test-$fixtureId")
        val store = ConnectionPreviewStore(directory, initiallyEnabled = true) { it == fixtureId }
        val lastBlackHalf = CompletableDeferred<Unit>()
        val sendRed = CompletableDeferred<Unit>()
        try {
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { listener ->
                listener.soTimeout = 15_000
                val peer = async(Dispatchers.IO) { streamSyntheticDesktop(listener, lastBlackHalf, sendRed) }
                val session = UniFfiRemoteSession(
                    context,
                    Connection(id = fixtureId, name = "Preview fixture", host = listener.inetAddress.hostAddress!!, port = listener.localPort),
                    QualityPreset.Balanced,
                    sshKey = null,
                    startInObserveMode = false,
                    previews = store,
                )
                val events = Channel<SessionEvent>(Channel.UNLIMITED)
                val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                    session.events.collect { events.send(it) }
                }
                suspend fun nextFrame() {
                    while (true) {
                        when (val event = events.receive()) {
                            is SessionEvent.Frame -> return
                            is SessionEvent.Failed -> error(event.reason)
                            is SessionEvent.Disconnected -> error("Fixture ended early")
                            else -> Unit
                        }
                    }
                }
                try {
                    withTimeout(15_000) {
                        val previous = Bitmap.createBitmap(32, 18, Bitmap.Config.ARGB_8888)
                        previous.eraseColor(Color.BLUE)
                        store.writeAsync(store.beginCapture(fixtureId)!!, previous).join()
                        val firstVersion = store.state.value.version(fixtureId)!!
                        val saved = requireNotNull(store.read(fixtureId, firstVersion))
                        session.connect()
                        nextFrame()
                        assertArrayEquals(saved, store.read(fixtureId, firstVersion))

                        lastBlackHalf.complete(Unit)
                        nextFrame()
                        val blackVersion = store.state.first { it.version(fixtureId) != firstVersion }.version(fixtureId)!!
                        val black = requireNotNull(store.read(fixtureId, blackVersion))
                        val bitmap = BitmapFactory.decodeByteArray(black, 0, black.size)
                        assertEquals(Color.BLACK, bitmap.getPixel(0, 0))

                        sendRed.complete(Unit)
                        nextFrame()
                        session.disconnect()

                        val reopened = ConnectionPreviewStore(directory, initiallyEnabled = true) { it == fixtureId }
                        val last = requireNotNull(reopened.read(fixtureId, reopened.state.value.version(fixtureId)!!))
                        val red = BitmapFactory.decodeByteArray(last, 0, last.size).getPixel(0, 0)
                        assertTrue(Color.red(red) > 230 && Color.green(red) < 10)
                    }
                } finally {
                    session.disconnect()
                    collector.cancel()
                    lastBlackHalf.complete(Unit)
                    sendRed.complete(Unit)
                }
                peer.await()
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun defaultOnAndPreferenceSurvivesOpeningASecondSettingsStore() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "preview-setting-test-${UUID.randomUUID()}"
        val context = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(ignored: String?, mode: Int): SharedPreferences =
                base.getSharedPreferences(name, mode)
        }
        try {
            val first = SettingsStore(context)
            assertTrue(first.load().showSessionPreviews)
            first.save(first.load().copy(showSessionPreviews = false))
            val reopened = SettingsStore(context)
            assertFalse(reopened.load().showSessionPreviews)
            reopened.save(reopened.load().copy(showSessionPreviews = true))
            assertTrue(SettingsStore(context).load().showSessionPreviews)
        } finally {
            base.deleteSharedPreferences(name)
        }
    }

    private suspend fun streamSyntheticDesktop(
        listener: ServerSocket,
        lastBlackHalf: CompletableDeferred<Unit>,
        sendRed: CompletableDeferred<Unit>,
    ) {
        listener.accept().use { socket ->
            socket.soTimeout = 15_000
            val input = DataInputStream(socket.getInputStream())
            val out = DataOutputStream(socket.getOutputStream())
            fun read(n: Int) = ByteArray(n).also(input::readFully)
            fun readRefresh() {
                assertEquals(3, input.readUnsignedByte())
                read(9)
            }
            fun paint(y: Int, rows: Int, red: Boolean) {
                out.writeShort(0) // FramebufferUpdate and padding
                out.writeShort(1)
                out.writeShort(0)
                out.writeShort(y)
                out.writeShort(32)
                out.writeShort(rows)
                out.writeInt(0) // Raw
                val pixels = ByteArray(32 * rows * 4)
                if (red) for (index in 2 until pixels.size step 4) pixels[index] = 0xff.toByte()
                out.write(pixels)
                out.flush()
            }
            val version = "RFB 003.008\n".toByteArray()
            out.write(version)
            assertArrayEquals(version, read(version.size))
            out.write(byteArrayOf(1, 1))
            assertEquals(1, input.readUnsignedByte())
            out.writeInt(0)
            input.readUnsignedByte()
            out.writeShort(32)
            out.writeShort(18)
            out.write(byteArrayOf(32, 24, 0, 1, 0, -1, 0, -1, 0, -1, 16, 8, 0, 0, 0, 0))
            out.writeInt(0) // Empty desktop name
            read(20) // SetPixelFormat
            read(2)
            read(input.readUnsignedShort() * 4) // SetEncodings
            readRefresh()
            paint(0, 9, red = false)
            readRefresh()
            lastBlackHalf.await()
            paint(9, 9, red = false)
            readRefresh()
            sendRed.await()
            paint(0, 18, red = true)
            while (input.read() != -1) {
                // A final incremental request may be in flight before disconnect.
            }
        }
    }
}
