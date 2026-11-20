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
        val sent = mutableListOf<Int>()
        val forward = launch(start = CoroutineStart.UNDISPATCHED) { buffer.forward { sent.add(it) } }
        try {
            buffer.field.edit { insert(length, "Q") }
            buffer.field.edit { insert(length, "7") }
            Snapshot.sendApplyNotifications()
            yield()
            assertEquals("Q7".map(Char::code), sent)

            repeat(2) {
                buffer.field.edit { insert(length, "Q") }
                Snapshot.sendApplyNotifications()
                yield()
            }
            assertEquals("Q7QQ".map(Char::code), sent)

            buffer.field.edit { insert(length, "😀😀") }
            Snapshot.sendApplyNotifications()
            yield()
            assertEquals("Q7QQ".map(Char::code) + listOf(0x1F600, 0x1F600), sent)
        } finally {
            forward.cancelAndJoin()
        }
    }
}
