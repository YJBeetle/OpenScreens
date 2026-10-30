package com.openscreens.app.session

import android.util.Log
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Stand-in for the Rust core. It simulates a successful connection and logs every
 * input message so the session screen can be exercised end to end.
 */
class FakeRemoteSession(
    private val connection: Connection,
    initialQuality: QualityPreset,
) : RemoteSession {

    private val _events = MutableSharedFlow<SessionEvent>(
        replay = 1,
        extraBufferCapacity = 8,
    )
    override val events: Flow<SessionEvent> = _events.asSharedFlow()

    private var quality: QualityPreset = initialQuality

    override suspend fun connect() {
        _events.emit(SessionEvent.Connecting)
        Log.i(TAG, "Connecting to ${connection.address} (fake)")
        delay(CONNECT_DELAY_MS)
        _events.emit(SessionEvent.Connected(width = 1920, height = 1200))
        Log.i(TAG, "Connected to ${connection.address} at ${quality.name} quality (fake)")
    }

    override suspend fun disconnect() {
        _events.emit(SessionEvent.Disconnected)
        Log.i(TAG, "Disconnected from ${connection.address} (fake)")
    }

    override fun sendPointer(x: Int, y: Int, buttonMask: Int) {
        Log.d(TAG, "sendPointer x=$x y=$y mask=$buttonMask")
    }

    override fun sendKey(keysym: Int, pressed: Boolean) {
        Log.d(TAG, "sendKey keysym=$keysym pressed=$pressed")
    }

    override fun sendClipboard(text: String) {
        Log.d(TAG, "sendClipboard ${text.length} characters")
    }

    override suspend fun copyRegion(x: Int, y: Int, width: Int, height: Int): ByteArray {
        delay(COPY_DELAY_MS)
        Log.d(TAG, "copyRegion x=$x y=$y ${width}x$height")
        return ByteArray(width * height / 2)
    }

    override fun setQuality(quality: QualityPreset) {
        this.quality = quality
        Log.d(TAG, "setQuality ${quality.name}")
    }

    private companion object {
        const val TAG = "FakeRemoteSession"
        const val CONNECT_DELAY_MS = 700L
        const val COPY_DELAY_MS = 120L
    }
}
