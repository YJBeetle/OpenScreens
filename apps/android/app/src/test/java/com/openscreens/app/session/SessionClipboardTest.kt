package com.openscreens.app.session

import org.junit.Assert.*
import org.junit.Test

class SessionClipboardTest {
    @Test fun disabledBlocksAutomaticTransfersAndAllowsManualTransfers() {
        var local = "local"
        var reads = 0
        val clipboard = SessionClipboard(false, { reads++; local }, { local = it })
        clipboard.receive("private", focused = true)
        assertNull(clipboard.reply(focused = true))
        assertEquals(0, reads)
        assertEquals("local", clipboard.localText())
        assertTrue(clipboard.copyLatest())
        assertEquals("private", local)
        clipboard.receive("fresh", focused = true, requested = true)
        assertEquals("fresh", local)
    }

    @Test fun requestReadsLocalTextOnlyWhileFocused() {
        var local = "local"
        var reads = 0
        val clipboard = SessionClipboard(true, { reads++; local }, { local = it })
        assertNull(clipboard.reply(focused = false))
        assertEquals(0, reads)
        assertEquals("local", clipboard.reply(focused = true))
        clipboard.receive("remote", focused = true)
        assertEquals("remote", local)
        assertEquals("remote", clipboard.reply(focused = true))
        assertEquals("remote", clipboard.localText())
    }

    @Test fun pushOnlyCopyUsesTheLatestTextFromThisTransport() {
        var local = "unrelated"
        val clipboard = SessionClipboard(true, { local }, { local = it })
        assertFalse(clipboard.copyLatest())
        clipboard.receive("one", focused = false)
        clipboard.receive("two", focused = false)
        assertEquals("unrelated", local)
        assertTrue(clipboard.copyLatest())
        assertEquals("two", local)
        clipboard.reset()
        assertFalse(clipboard.copyLatest())
    }
}
