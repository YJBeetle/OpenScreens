package com.openscreens.app.ui.session

import com.openscreens.app.data.Connection
import com.openscreens.app.data.DisconnectAction
import com.openscreens.app.data.RemotePlatform
import org.junit.Assert.*
import org.junit.Test

class DisconnectRequestTest {
    private val mac = Connection(name = "Test", host = "test.invalid", platform = RemotePlatform.MacOS)
    private val windows = mac.copy(platform = RemotePlatform.Windows)

    private fun record(request: DisconnectRequest, profile: Connection, inControl: Boolean = true): List<String> {
        val events = mutableListOf<String>()
        request.sendConfirmedAction(profile, inControl, 100, 75, { events.add("release") },
            { x, y, mask -> events.add("pointer $x $y $mask") },
            { key, down -> events.add("${if (down) "down" else "up"} ${key.toString(16)}") })
        return events
    }

    @Test fun defaultUnsupportedAndObserveNeverSendAnAction() {
        assertEquals(DisconnectAction.None, DisconnectAction.fromStored(""))
        assertEquals(DisconnectAction.None, DisconnectAction.fromStored("unknown"))
        assertNull(DisconnectRequest.create(mac, true, false))
        val configured = windows.copy(disconnectAction = DisconnectAction.CtrlAltDelete)
        assertNull(DisconnectRequest.create(configured, false, false))
        assertNull(DisconnectRequest.create(configured.copy(platform = RemotePlatform.Linux), true, false))
        val transfer = requireNotNull(DisconnectRequest.create(configured, false, true))
        assertTrue(transfer.interruptsTransfers)
        assertTrue(record(transfer, configured).isEmpty())
        val normal = requireNotNull(DisconnectRequest.create(configured, true, false))
        assertTrue(record(normal, configured, false).isEmpty())
        assertTrue(record(normal, mac).isEmpty())
    }

    @Test fun confirmedChordsReleasePriorInputAndUnwindModifiersBeforeClose() {
        val configured = windows.copy(disconnectAction = DisconnectAction.CtrlAltDelete)
        val request = requireNotNull(DisconnectRequest.create(configured, true, true))
        assertTrue(request.interruptsTransfers)
        assertEquals(listOf("release", "down ffe3", "down ffe9", "down ffff", "up ffff", "up ffe9", "up ffe3"),
            record(request, configured))
        val logout = mac.copy(disconnectAction = DisconnectAction.LogOut)
        assertEquals(listOf("release", "down ffe1", "down ffe9", "down ffeb", "down 71", "up 71", "up ffeb", "up ffe9", "up ffe1"),
            record(requireNotNull(DisconnectRequest.create(logout, true, false)), logout))
    }

    @Test fun hotCornersUseTheLastPixelWithNoButtonsHeld() {
        for ((action, point) in listOf(DisconnectAction.TopLeft to "0 0", DisconnectAction.TopRight to "99 0",
                                      DisconnectAction.BottomLeft to "0 74", DisconnectAction.BottomRight to "99 74")) {
            val profile = mac.copy(disconnectAction = action)
            assertEquals(listOf("release", "pointer $point 0"),
                record(requireNotNull(DisconnectRequest.create(profile, true, false)), profile))
        }
    }
}
