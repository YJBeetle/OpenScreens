package com.openscreens.app.ui.editor

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import com.openscreens.app.R
import com.openscreens.app.data.RemotePlatform

@Composable
private fun RemotePlatform.label(): String = when (this) {
    RemotePlatform.MacOS -> "macOS"
    RemotePlatform.Windows -> "Windows"
    RemotePlatform.Linux -> "Linux"
    RemotePlatform.Unix -> "Unix"
    RemotePlatform.Other -> stringResource(R.string.remote_platform_other)
}

@Composable
internal fun RemotePlatformPicker(selected: RemotePlatform, onSelect: (RemotePlatform) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }) {
            Text(stringResource(R.string.remote_platform, selected.label()))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            RemotePlatform.entries.forEach { platform ->
                DropdownMenuItem(text = { Text(platform.label()) }, onClick = {
                    expanded = false
                    onSelect(platform)
                })
            }
        }
    }
}
