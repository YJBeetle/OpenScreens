package com.openscreens.app.ui.session

import androidx.annotation.StringRes
import com.openscreens.app.R
import com.openscreens.app.data.RemotePlatform

internal data class DesktopCommand(@StringRes val title: Int, val keysym: Int, val modifiers: List<Int>)

private fun command(@StringRes title: Int, key: Int, vararg modifiers: Int) =
    DesktopCommand(title, key, modifiers.toList())

internal val lockMac = command(R.string.command_lock, 'q'.code, KEY_CONTROL, KEY_SUPER)
internal val lockWindows = command(R.string.command_lock, 'l'.code, KEY_SUPER)
internal val ctrlAltDelete = command(R.string.command_ctrl_alt_delete, 0xFFFF, KEY_CONTROL, KEY_ALT)

internal fun desktopCommands(platform: RemotePlatform): List<DesktopCommand> = when (platform) {
    RemotePlatform.MacOS -> listOf(
        command(R.string.command_mission_control, KEY_UP, KEY_CONTROL),
        command(R.string.command_app_windows, KEY_DOWN, KEY_CONTROL),
        command(R.string.command_left_space, KEY_LEFT, KEY_CONTROL),
        command(R.string.command_right_space, KEY_RIGHT, KEY_CONTROL),
        command(R.string.command_desktop, 0xFFC8), // F11
        command(R.string.command_switch_apps, KEY_TAB, KEY_SUPER),
        command(R.string.command_spotlight, ' '.code, KEY_SUPER),
        command(R.string.command_force_quit, KEY_ESCAPE, KEY_ALT, KEY_SUPER),
        lockMac,
    )
    RemotePlatform.Windows -> listOf(
        ctrlAltDelete,
        command(R.string.command_task_manager, KEY_ESCAPE, KEY_SHIFT, KEY_CONTROL),
        command(R.string.command_desktop, 'd'.code, KEY_SUPER),
        command(R.string.command_switch_apps, KEY_TAB, KEY_ALT),
        lockWindows,
    )
    RemotePlatform.Linux, RemotePlatform.Unix -> listOf(
        command(R.string.command_switch_apps, KEY_TAB, KEY_ALT),
        command(R.string.command_insert, 0xFF63),
    )
    RemotePlatform.Other -> listOf(
        command(R.string.session_key_esc, KEY_ESCAPE),
        command(R.string.command_insert, 0xFF63),
    )
}
