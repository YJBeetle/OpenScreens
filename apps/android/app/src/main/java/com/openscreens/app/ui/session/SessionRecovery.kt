package com.openscreens.app.ui.session

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** A single foreground recovery sequence. A short-lived successful handshake
 * keeps its retry count so a flapping server cannot reconnect indefinitely. */
internal class SessionRecovery {
    class Failure(val message: String, val retryable: Boolean)
    var failure by mutableStateOf<Failure?>(null)
        private set
    private var attempts = 0

    val nextDelayMillis: Long?
        get() = if (failure?.retryable == true && attempts < 3) 1000L shl attempts else null

    fun failed(message: String, retryable: Boolean) {
        failure = Failure(message, retryable)
    }

    fun takeRetry(manual: Boolean): Boolean {
        if (failure == null || (!manual && nextDelayMillis == null)) return false
        attempts = if (manual) 0 else attempts + 1
        failure = null
        return true
    }

    fun stable() {
        attempts = 0
    }
}
