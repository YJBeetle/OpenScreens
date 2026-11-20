package com.openscreens.app.ui.session

import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.placeCursorAtEnd
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.first

private const val SENTINEL = "\u200B"

internal class RemoteKeyboardBuffer {
    val field = TextFieldState(SENTINEL)

    fun handleBackspace(send: () -> Unit) = InputTransformation {
        if (length == 0 && originalText.startsWith(SENTINEL)) {
            replace(0, 0, SENTINEL)
            placeCursorAtEnd()
            send()
        }
    }

    suspend fun forward(send: (Char) -> Unit) {
        while (true) {
            snapshotFlow { field.composition == null && !SENTINEL.contentEquals(field.text) }.first { it }
            // Consume from the editor itself. Pending edits can accumulate before a
            // frame, and the next edit must see the same reset as the remote sender.
            val typed = field.text.toString().removePrefix(SENTINEL)
            field.edit {
                replace(0, length, SENTINEL)
                placeCursorAtEnd()
            }
            typed.forEach(send)
        }
    }
}
