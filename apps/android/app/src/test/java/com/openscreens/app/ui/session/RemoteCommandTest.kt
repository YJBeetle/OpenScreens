package com.openscreens.app.ui.session

import com.openscreens.app.R
import com.openscreens.app.data.RemotePlatform
import com.openscreens.app.session.sendChord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RemoteCommandTest {
    @Test
    fun windowsAttentionChordReleasesInReverseOrder() {
        val cmd = desktopCommands(RemotePlatform.Windows).single { it.title == R.string.command_ctrl_alt_delete }
        val events = mutableListOf<Pair<Int, Boolean>>()
        sendChord(cmd.keysym, cmd.modifiers) { key, down -> events.add(key to down) }
        assertEquals(listOf(0xffe3 to true, 0xffe9 to true, 0xffff to true,
                            0xffff to false, 0xffe9 to false, 0xffe3 to false), events)
        assertFalse(desktopCommands(RemotePlatform.MacOS).any { it.title == cmd.title })
        assertFalse(desktopCommands(RemotePlatform.Other).any { it.title == R.string.command_lock })
    }

    @Test
    fun sameCommandUsesTheRemotePlatformModifiers() {
        fun lock(platform: RemotePlatform) = desktopCommands(platform).single { it.title == R.string.command_lock }
        val mac = lock(RemotePlatform.MacOS)
        val windows = lock(RemotePlatform.Windows)
        assertEquals('q'.code, mac.keysym)
        assertEquals(listOf(KEY_CONTROL, KEY_SUPER), mac.modifiers)
        assertEquals('l'.code, windows.keysym)
        assertEquals(listOf(KEY_SUPER), windows.modifiers)
    }
}
