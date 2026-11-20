package com.openscreens.app.ui.session

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.ExitToApp
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.KeyboardCommandKey
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Mouse
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.RemotePlatform
import com.openscreens.app.session.DisplayScreen
import com.openscreens.app.ui.common.label

private val ActionSize = 48.dp

// A partially visible icon is not an action slot. Reserve a full slot for
// overflow whenever any of the available actions would otherwise be clipped.
internal fun sessionToolbarInlineCount(actionCount: Int, widthPx: Int, actionWidthPx: Int): Int {
    val slots = widthPx / actionWidthPx
    return if (actionCount <= slots) actionCount else (slots - 1).coerceAtLeast(0)
}

private data class SessionAction(
    val label: String,
    val icon: ImageVector? = null,
    val enabled: Boolean = true,
    val checked: Boolean? = null,
    val submenu: List<SessionAction> = emptyList(),
    val onClick: () -> Unit = {},
)

@Composable
internal fun SessionToolbar(
    platform: RemotePlatform,
    onCommand: (DesktopCommand) -> Unit,
    observing: Boolean,
    onObserveModeChange: (Boolean) -> Unit,
    trackpadMode: Boolean,
    onTogglePointerMode: () -> Unit,
    displays: List<DisplayScreen>,
    supportsCurtainMode: Boolean,
    onCurtainRequest: (Boolean) -> Unit,
    selectedDisplayId: Int?,
    onSelectDisplay: (Int?) -> Unit,
    quality: QualityPreset,
    onQualitySelected: (QualityPreset) -> Unit,
    isFullscreen: Boolean,
    onKeyboard: () -> Unit,
    connected: Boolean,
    onClipboard: () -> Unit,
    onUpload: () -> Unit,
    onDownload: () -> Unit,
    canUpload: Boolean,
    canDownload: Boolean,
    onShowFileTransfers: () -> Unit,
    onScreenshot: () -> Unit,
    onToggleFullscreen: () -> Unit,
    onHideChrome: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val disconnect = SessionAction(
        stringResource(R.string.session_disconnect),
        Icons.AutoMirrored.Outlined.ExitToApp,
        onClick = onDisconnect,
    )
    val actions = buildList {
        add(SessionAction(
            stringResource(R.string.session_observe_mode),
            Icons.Outlined.Visibility,
            checked = observing,
            onClick = { onObserveModeChange(!observing) },
        ))
        if (!observing) {
            add(SessionAction(stringResource(R.string.session_keyboard), Icons.Outlined.Keyboard, onClick = onKeyboard))
        }
        add(SessionAction(stringResource(R.string.session_screenshot), Icons.Outlined.PhotoCamera, onClick = onScreenshot))
        add(disconnect)
        if (!observing) {
            add(SessionAction(
                stringResource(if (trackpadMode) R.string.session_pointer_trackpad else R.string.session_pointer_direct),
                if (trackpadMode) Icons.Outlined.Mouse else Icons.Outlined.TouchApp,
                onClick = onTogglePointerMode,
            ))
        }
        if (displays.isNotEmpty() || (supportsCurtainMode && !observing)) {
            val displayActions = buildList {
                if (supportsCurtainMode && !observing) {
                    add(SessionAction(stringResource(R.string.session_enable_curtain), onClick = { onCurtainRequest(true) }))
                    add(SessionAction(stringResource(R.string.session_disable_curtain), onClick = { onCurtainRequest(false) }))
                }
                if (displays.isNotEmpty()) {
                    add(SessionAction(
                        stringResource(R.string.session_all_displays),
                        checked = selectedDisplayId == null,
                        onClick = { onSelectDisplay(null) },
                    ))
                }
                displays.forEachIndexed { index, screen ->
                    add(SessionAction(
                        stringResource(R.string.session_display_entry, index + 1, screen.width, screen.height),
                        checked = selectedDisplayId == screen.id,
                        onClick = { onSelectDisplay(screen.id) },
                    ))
                }
            }
            add(SessionAction(stringResource(R.string.session_displays), Icons.Outlined.Monitor, submenu = displayActions))
        }
        if (!observing) {
            add(SessionAction(
                stringResource(R.string.remote_commands),
                Icons.Outlined.KeyboardCommandKey,
                enabled = connected,
                submenu = desktopCommands(platform).map { command ->
                    SessionAction(stringResource(command.title), onClick = { onCommand(command) })
                },
            ))
            add(SessionAction(
                stringResource(R.string.session_clipboard),
                Icons.Outlined.ContentPaste,
                enabled = connected,
                onClick = onClipboard,
            ))
        }
        add(SessionAction(
            stringResource(R.string.session_file_transfers),
            Icons.Outlined.SwapVert,
            submenu = listOf(
                SessionAction(stringResource(R.string.session_send_file), Icons.Outlined.UploadFile, enabled = canUpload && !observing, onClick = onUpload),
                SessionAction(stringResource(R.string.session_download), Icons.Outlined.Download, enabled = canDownload, onClick = onDownload),
                SessionAction(stringResource(R.string.session_file_transfers), Icons.Outlined.SwapVert, onClick = onShowFileTransfers),
            ),
        ))
        add(SessionAction(
            stringResource(if (isFullscreen) R.string.session_exit_fullscreen else R.string.session_enter_fullscreen),
            if (isFullscreen) Icons.Outlined.FullscreenExit else Icons.Outlined.Fullscreen,
            onClick = onToggleFullscreen,
        ))
        add(SessionAction(
            stringResource(R.string.session_quality),
            Icons.Outlined.Tune,
            submenu = QualityPreset.entries.map { preset ->
                SessionAction(preset.label(), checked = preset == quality, onClick = { onQualitySelected(preset) })
            },
        ))
        add(SessionAction(stringResource(R.string.session_hide_controls), Icons.Outlined.VisibilityOff, onClick = onHideChrome))
    }

    BottomAppBar(
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = 4.dp),
        windowInsets = WindowInsets(0, 0, 0, 0),
    ) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val actionWidth = with(LocalDensity.current) { ActionSize.roundToPx() }
            val inlineCount = sessionToolbarInlineCount(actions.size, constraints.maxWidth, actionWidth)
            val inlineActions = actions.take(inlineCount)
            val overflow = actions.drop(inlineCount)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                inlineActions.forEach { action ->
                    if (action !== disconnect) {
                        key(action.label) { SessionActionButton(action) }
                    }
                }
                if (overflow.isNotEmpty()) {
                    SessionActionButton(SessionAction(
                        stringResource(R.string.session_more_actions),
                        Icons.Outlined.MoreVert,
                        submenu = overflow,
                    ))
                }
                if (inlineActions.any { it === disconnect }) {
                    SessionActionButton(disconnect)
                }
            }
        }
    }
}

@Composable
private fun SessionActionButton(action: SessionAction) {
    val icon = requireNotNull(action.icon)
    val size = Modifier.size(ActionSize)
    if (action.checked != null) {
        IconToggleButton(
            checked = action.checked,
            onCheckedChange = { action.onClick() },
            enabled = action.enabled,
            modifier = size,
            colors = IconButtonDefaults.iconToggleButtonColors(
                checkedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                checkedContainerColor = MaterialTheme.colorScheme.primaryContainer,
            ),
        ) {
            Icon(icon, contentDescription = action.label)
        }
    } else if (action.submenu.isEmpty()) {
        IconButton(enabled = action.enabled, modifier = size, onClick = action.onClick) {
            Icon(icon, contentDescription = action.label)
        }
    } else {
        var expanded by remember(action.enabled) { mutableStateOf(false) }
        Box {
            IconButton(enabled = action.enabled, modifier = size, onClick = { expanded = true }) {
                Icon(icon, contentDescription = action.label)
            }
            if (expanded) {
                SessionActionMenu(action) { expanded = false }
            }
        }
    }
}

@Composable
private fun SessionActionMenu(root: SessionAction, onDismiss: () -> Unit) {
    var submenuLabel by remember { mutableStateOf<String?>(null) }
    val submenu = root.submenu.firstOrNull { it.label == submenuLabel && it.enabled }
    val items = submenu?.submenu ?: root.submenu
    val scrollState = key(submenu?.label) { rememberScrollState() }
    DropdownMenu(expanded = true, onDismissRequest = onDismiss, scrollState = scrollState) {
        if (submenu != null) {
            DropdownMenuItem(
                text = { Text(root.label) },
                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = null) },
                onClick = { submenuLabel = null },
            )
        }
        items.forEach { item ->
            val leadingIcon: (@Composable () -> Unit)? = item.icon?.let { icon ->
                { Icon(icon, contentDescription = null) }
            }
            DropdownMenuItem(
                text = { Text(item.label) },
                leadingIcon = leadingIcon,
                enabled = item.enabled,
                modifier = item.checked?.let { checked -> Modifier.semantics { selected = checked } } ?: Modifier,
                trailingIcon = {
                    when {
                        item.submenu.isNotEmpty() -> Icon(Icons.AutoMirrored.Outlined.ArrowForward, contentDescription = null)
                        item.checked == true -> Icon(Icons.Outlined.Check, contentDescription = null)
                    }
                },
                onClick = {
                    if (item.submenu.isNotEmpty()) {
                        submenuLabel = item.label
                    } else {
                        onDismiss()
                        item.onClick()
                    }
                },
            )
        }
    }
}
