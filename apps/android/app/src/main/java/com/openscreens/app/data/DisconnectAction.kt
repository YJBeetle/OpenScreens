package com.openscreens.app.data

import androidx.annotation.StringRes
import com.openscreens.app.R

enum class DisconnectAction(@StringRes val title: Int) {
    None(R.string.disconnect_action_none),
    Lock(R.string.command_lock),
    LogOut(R.string.disconnect_action_log_out),
    CtrlAltDelete(R.string.command_ctrl_alt_delete),
    TopLeft(R.string.disconnect_action_top_left),
    TopRight(R.string.disconnect_action_top_right),
    BottomLeft(R.string.disconnect_action_bottom_left),
    BottomRight(R.string.disconnect_action_bottom_right);

    companion object {
        fun options(platform: RemotePlatform): List<DisconnectAction> = when (platform) {
            RemotePlatform.MacOS -> listOf(None, Lock, LogOut, TopLeft, TopRight, BottomLeft, BottomRight)
            RemotePlatform.Windows -> listOf(None, Lock, CtrlAltDelete)
            else -> listOf(None)
        }

        fun fromStored(value: String): DisconnectAction = entries.firstOrNull { it.name == value } ?: None
    }
}
