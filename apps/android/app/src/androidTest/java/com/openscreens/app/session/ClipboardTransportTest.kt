package com.openscreens.app.session

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ClipboardTransportTest {
    @Test fun standardCutText() = exercise(apple = false)
    @Test fun applePasteboard() = exercise(apple = true)

    private fun exercise(apple: Boolean) = runBlocking {
        val original = if (apple) "世界🙂\r\ne\u0301" else "Café\r\n£"
        val expected = if (apple) original else "Café\n£"
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { listener ->
            listener.soTimeout = 60000 // First use loads the native library on the device.
            val peer = async(Dispatchers.IO) { serve(listener, apple, expected) }
            val session = UniFfiRemoteSession(
                InstrumentationRegistry.getInstrumentation().targetContext,
                Connection(name = "Fixture", host = "127.0.0.1", port = listener.localPort, sharedClipboard = false),
                QualityPreset.Balanced, null, startInObserveMode = false,
            )
            var local = original
            val clipboard = SessionClipboard(false, { local }, { local = it })
            val events = Channel<SessionEvent>(Channel.UNLIMITED)
            val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                session.events.collect { events.send(it) }
            }
            suspend fun nextText(): String {
                while (true) {
                    when (val event = events.receive()) {
                        is SessionEvent.RemoteClipboard -> return event.text
                        is SessionEvent.Failed -> error(event.reason)
                        is SessionEvent.Disconnected -> error("Unexpected disconnect")
                        SessionEvent.ClipboardRequest -> error("Unexpected clipboard request")
                        else -> Unit
                    }
                }
            }
            try {
                withTimeout(60000) {
                    session.connect()
                    session.sendClipboard(original)
                    local = "unchanged"
                    val requested = session.requestClipboard()
                    assertEquals(apple, requested)
                    clipboard.receive(nextText(), focused = true, requested = requested)
                    if (!apple) {
                        assertEquals("unchanged", local)
                        assertTrue(clipboard.copyLatest())
                        assertTrue(runCatching { session.sendClipboard("世界🙂") }.exceptionOrNull() is ClipboardEncodingException)
                    }
                    assertEquals(expected, local)
                    session.setClipboardSharing(true)
                    clipboard.shared = true
                    if (apple) assertSame(SessionEvent.ClipboardRequest, events.receive())
                    local = "sync"
                    session.sendClipboard(clipboard.reply(true)!!, automatic = true)
                    clipboard.receive(nextText(), focused = true)
                    session.sendClipboard(clipboard.reply(true)!!, automatic = true)
                    // Peer sees only the explicit send after its echo.
                    session.sendClipboard("done")
                    session.setObserveMode(true)
                    assertTrue(runCatching { session.sendClipboard("blocked") }.isFailure)
                    assertTrue(runCatching { session.sendClipboard("blocked", automatic = true) }.isFailure)
                    // Apple sends a clipboard request before this last push.
                    // Observing may still receive the push but must hide the request.
                    assertEquals("done", nextText())
                }
            } finally {
                session.disconnect()
                collector.cancel()
            }
            peer.await()
        }
    }

    private fun serve(listener: ServerSocket, apple: Boolean, expected: String) {
        listener.accept().use { socket ->
            socket.soTimeout = 30000
            val input = DataInputStream(socket.getInputStream())
            val out = socket.getOutputStream()
            fun read(n: Int) = ByteArray(n).also(input::readFully)
            fun send(vararg bytes: Int) = out.write(ByteArray(bytes.size) { bytes[it].toByte() })
            fun config(on: Boolean) {
                if (apple) assertArrayEquals(byteArrayOf(0x15, 0, 0, if (on) 1 else 2, 0, 0, 0, 0), read(8))
            }
            fun outgoing(): ByteArray {
                val header = read(if (apple) 16 else 8)
                assertEquals(if (apple) 31 else 6, header[0].toInt())
                val size = ByteBuffer.wrap(header).getInt(header.size - 4)
                require(size in 0..4096)
                return header + read(size)
            }
            fun reflect(message: ByteArray) {
                if (!apple) message[0] = 3
                out.write(message)
            }
            val version = (if (apple) "RFB 003.889\n" else "RFB 003.008\n").toByteArray()
            out.write(version)
            assertArrayEquals(version, read(12))
            send(1, 1)
            assertEquals(1, input.read())
            send(0, 0, 0, 0)
            read(1)
            send(0, 1, 0, 1, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0)
            if (apple) {
                send(0, 0, 0, 23)
                val name = ByteArray(23)
                ByteBuffer.wrap(name).putLong(6, (1L shl 32) or (1L shl 41))
                name[22] = 65
                out.write(name)
                assertEquals(33, read(66)[0].toInt())
            } else send(0, 0, 0, 0)
            read(20)
            read(2)
            read(4 * input.readUnsignedShort())
            read(10)
            config(false)
            val initial = outgoing()
            if (apple) {
                assertEquals(11, read(8)[0].toInt())
            } else assertArrayEquals(expected.toByteArray(Charsets.ISO_8859_1), initial.copyOfRange(8, initial.size))
            reflect(initial)
            config(true)
            if (apple) send(0x14, 0, 4, 0, 4, 0, 1, 2)
            reflect(outgoing())
            val done = outgoing()
            config(false)
            if (apple) send(0x14, 0, 4, 0, 4, 0, 1, 2)
            reflect(done)
            assertEquals("Unexpected outbound clipboard data", -1, input.read())
        }
    }
}
