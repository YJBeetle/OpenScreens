package com.openscreens.app.ui.session

import androidx.compose.foundation.text.input.insert
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteKeyboardBufferTest {
    @Test fun cumulativeEditsAndRepeatedCommitsAreEachConsumedOnce() = runBlocking {
        val buffer = RemoteKeyboardBuffer()
        val sent = StringBuilder()
        val forward = launch(start = CoroutineStart.UNDISPATCHED) { buffer.forward { sent.append(it) } }
        try {
            buffer.field.edit { insert(length, "Q") }
            buffer.field.edit { insert(length, "7") }
            Snapshot.sendApplyNotifications()
            yield()
            assertEquals("Q7", sent.toString())

            repeat(2) {
                buffer.field.edit { insert(length, "Q") }
                Snapshot.sendApplyNotifications()
                yield()
            }
            assertEquals("Q7QQ", sent.toString())
        } finally {
            forward.cancelAndJoin()
        }
    }
}
