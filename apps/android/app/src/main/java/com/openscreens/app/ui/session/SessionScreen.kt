package com.openscreens.app.ui.session

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.session.RemoteSession
import com.openscreens.app.session.SessionEvent
import com.openscreens.app.session.SessionProvider
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.theme.SystemBarIconAppearance
import com.openscreens.app.ui.theme.findActivity
import kotlinx.coroutines.launch
import kotlin.math.min
import kotlin.math.roundToInt

private val SessionBackdrop = Color(0xFF060808)
private val FramebufferBackground = Color(0xFF000000)

private enum class SessionStatus { Connecting, Connected, Disconnected, Failed }

@Composable
fun SessionScreen(
    connection: Connection,
    quality: QualityPreset,
    onQualityChange: (QualityPreset) -> Unit,
    onConnected: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    val session: RemoteSession = remember(connection.id) {
        SessionProvider.create(connection, quality)
    }

    var status by remember { mutableStateOf(SessionStatus.Connecting) }
    var remoteWidth by remember { mutableIntStateOf(1920) }
    var remoteHeight by remember { mutableIntStateOf(1200) }
    var frame by remember { mutableStateOf<SessionEvent.Frame?>(null) }
    var lastAction by remember { mutableStateOf<String?>(null) }
    var showKeyboardDialog by rememberSaveable { mutableStateOf(false) }
    var showClipboardDialog by rememberSaveable { mutableStateOf(false) }
    var qualityMenuExpanded by remember { mutableStateOf(false) }
    var isFullscreen by rememberSaveable { mutableStateOf(true) }
    var isExiting by remember { mutableStateOf(false) }

    val exitSession: () -> Unit = {
        if (!isExiting) {
            isExiting = true
            scope.launch {
                session.disconnect()
                onExit()
            }
        }
    }

    BackHandler { exitSession() }

    DisposableEffect(isFullscreen) {
        val controller = view.context.findActivity()?.window?.let {
            WindowCompat.getInsetsController(it, view)
        }
        controller?.apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (isFullscreen) {
                hide(WindowInsetsCompat.Type.systemBars())
            } else {
                show(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose {
            controller?.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    // The canvas stays dark in both app themes, so system bar icons stay light.
    SystemBarIconAppearance(darkIcons = false)

    LaunchedEffect(session) {
        session.events.collect { event ->
            when (event) {
                SessionEvent.Connecting -> status = SessionStatus.Connecting
                is SessionEvent.Connected -> {
                    status = SessionStatus.Connected
                    remoteWidth = event.width
                    remoteHeight = event.height
                    onConnected()
                }
                is SessionEvent.Resized -> {
                    remoteWidth = event.width
                    remoteHeight = event.height
                }
                is SessionEvent.Frame -> {
                    status = SessionStatus.Connected
                    frame = event
                }
                SessionEvent.Disconnected -> {
                    status = SessionStatus.Disconnected
                    if (!isExiting) {
                        scope.launch {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.session_status_disconnected),
                            )
                        }
                    }
                }
                is SessionEvent.Failed -> {
                    status = SessionStatus.Failed
                    scope.launch { snackbarHostState.showSnackbar(event.reason) }
                }
            }
        }
    }

    LaunchedEffect(session) {
        session.connect()
    }

    val statusText = stringResource(
        when (status) {
            SessionStatus.Connecting -> R.string.session_status_connecting
            SessionStatus.Connected -> R.string.session_status_connected
            SessionStatus.Disconnected -> R.string.session_status_disconnected
            SessionStatus.Failed -> R.string.session_status_error
        },
    )

    val recordPointer: (Int, Int) -> Unit = { x, y ->
        lastAction = context.getString(
            R.string.session_action_prefix,
            context.getString(R.string.session_pointer_sent, x, y),
        )
    }

    val selectQuality: (QualityPreset) -> Unit = { preset ->
        qualityMenuExpanded = false
        onQualityChange(preset)
        session.setQuality(preset)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(SessionBackdrop),
    ) {
        val aspect = (remoteWidth.toFloat() / remoteHeight.toFloat()).coerceAtLeast(0.1f)
        val canvasWidth = min(maxWidth.value, maxHeight.value * aspect).dp

        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .width(canvasWidth)
                .aspectRatio(aspect)
                .clip(RoundedCornerShape(16.dp))
                .background(FramebufferBackground)
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                .pointerInput(session, remoteWidth, remoteHeight) {
                    detectTapGestures(
                        onTap = { offset ->
                            val (x, y) = remotePoint(offset, size, remoteWidth, remoteHeight)
                            session.sendPointer(x, y, 0)
                            recordPointer(x, y)
                        },
                        onLongPress = { offset ->
                            val (x, y) = remotePoint(offset, size, remoteWidth, remoteHeight)
                            scope.launch {
                                val regionWidth = min(192, remoteWidth - x).coerceAtLeast(1)
                                val regionHeight = min(120, remoteHeight - y).coerceAtLeast(1)
                                val bytes = session.copyRegion(x, y, regionWidth, regionHeight)
                                val message = context.resources.getQuantityString(
                                    R.plurals.session_region_copied,
                                    bytes.size,
                                    bytes.size,
                                )
                                lastAction = context.getString(
                                    R.string.session_action_prefix,
                                    message,
                                )
                                snackbarHostState.showSnackbar(message)
                            }
                        },
                    )
                }
                .pointerInput(session, remoteWidth, remoteHeight) {
                    var lastX = 0
                    var lastY = 0
                    detectDragGestures(
                        onDragStart = { offset ->
                            val (x, y) = remotePoint(offset, size, remoteWidth, remoteHeight)
                            lastX = x
                            lastY = y
                            session.sendPointer(x, y, 1)
                            recordPointer(x, y)
                        },
                        onDrag = { change, _ ->
                            change.consume()
                            val (x, y) = remotePoint(change.position, size, remoteWidth, remoteHeight)
                            lastX = x
                            lastY = y
                            session.sendPointer(x, y, 1)
                        },
                        onDragEnd = { session.sendPointer(lastX, lastY, 0) },
                        onDragCancel = { session.sendPointer(lastX, lastY, 0) },
                    )
                },
        ) {
            val live = frame
            if (live != null) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    drawImage(
                        image = live.bitmap.asImageBitmap(),
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(live.bitmap.width, live.bitmap.height),
                        dstOffset = IntOffset.Zero,
                        dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
                        filterQuality = FilterQuality.Low,
                    )
                }
            } else {
                RemoteCanvasPlaceholder(
                    remoteWidth = remoteWidth,
                    remoteHeight = remoteHeight,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
            lastAction?.let { action ->
                InputBadge(
                    text = action,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(12.dp),
                )
            }
        }

        SessionTopBar(
            serverName = connection.name,
            statusText = statusText,
            statusColor = statusColor(status),
            onDisconnect = exitSession,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )

        SessionToolbar(
            quality = quality,
            qualityMenuExpanded = qualityMenuExpanded,
            onQualityMenuChange = { qualityMenuExpanded = it },
            onQualitySelected = selectQuality,
            isFullscreen = isFullscreen,
            onKeyboard = { showKeyboardDialog = true },
            onClipboard = { showClipboardDialog = true },
            onToggleFullscreen = { isFullscreen = !isFullscreen },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )

        SnackbarHost(
            hostState = snackbarHostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(start = 16.dp, end = 16.dp, bottom = 76.dp),
        )
    }

    if (showKeyboardDialog) {
        KeystrokeDialog(
            onDismiss = { showKeyboardDialog = false },
            onSend = { key ->
                val keysym = x11Keysym(key.first())
                session.sendKey(keysym, true)
                session.sendKey(keysym, false)
                lastAction = context.getString(
                    R.string.session_action_prefix,
                    context.getString(R.string.session_key_sent, key),
                )
                showKeyboardDialog = false
            },
        )
    }

    if (showClipboardDialog) {
        ClipboardDialog(
            onDismiss = { showClipboardDialog = false },
            onSend = { text ->
                session.sendClipboard(text)
                lastAction = context.getString(
                    R.string.session_action_prefix,
                    context.resources.getQuantityString(
                        R.plurals.session_clipboard_sent,
                        text.length,
                        text.length,
                    ),
                )
                showClipboardDialog = false
            },
        )
    }
}

@Composable
private fun RemoteCanvasPlaceholder(
    remoteWidth: Int,
    remoteHeight: Int,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.06f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Monitor,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.8f),
                modifier = Modifier.size(26.dp),
            )
        }
        Spacer(Modifier.height(12.dp))
        Text(
            text = stringResource(R.string.session_waiting_title),
            style = MaterialTheme.typography.titleMedium,
            color = Color.White.copy(alpha = 0.9f),
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = stringResource(R.string.session_waiting_body),
            style = MaterialTheme.typography.bodySmall,
            color = Color.White.copy(alpha = 0.55f),
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 300.dp),
        )
        Spacer(Modifier.height(12.dp))
        Surface(
            color = Color.White.copy(alpha = 0.08f),
            contentColor = Color.White.copy(alpha = 0.8f),
            shape = RoundedCornerShape(50),
        ) {
            Text(
                text = stringResource(R.string.session_resolution, remoteWidth, remoteHeight),
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = FontFamily.Monospace,
                    letterSpacing = 0.5.sp,
                ),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp),
            )
        }
    }
}

@Composable
private fun InputBadge(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.widthIn(max = 320.dp),
        color = Color.Black.copy(alpha = 0.55f),
        contentColor = Color.White.copy(alpha = 0.85f),
        shape = RoundedCornerShape(50),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun SessionTopBar(
    serverName: String,
    statusText: String,
    statusColor: Color,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(20.dp)),
        shape = RoundedCornerShape(20.dp),
        color = Color.Black.copy(alpha = 0.55f),
        contentColor = Color.White,
    ) {
        Row(
            modifier = Modifier.padding(start = 16.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(statusColor),
            )
            Spacer(Modifier.width(10.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                Text(
                    text = serverName,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White.copy(alpha = 0.65f),
                )
            }
            IconButton(onClick = onDisconnect) {
                Icon(
                    imageVector = Icons.Outlined.PowerSettingsNew,
                    contentDescription = stringResource(R.string.session_disconnect),
                )
            }
        }
    }
}

@Composable
private fun SessionToolbar(
    quality: QualityPreset,
    qualityMenuExpanded: Boolean,
    onQualityMenuChange: (Boolean) -> Unit,
    onQualitySelected: (QualityPreset) -> Unit,
    isFullscreen: Boolean,
    onKeyboard: () -> Unit,
    onClipboard: () -> Unit,
    onToggleFullscreen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.border(
            width = 1.dp,
            color = Color.White.copy(alpha = 0.1f),
            shape = RoundedCornerShape(28.dp),
        ),
        shape = RoundedCornerShape(28.dp),
        color = Color.Black.copy(alpha = 0.6f),
        contentColor = Color.White,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            ToolbarButton(
                icon = Icons.Outlined.Keyboard,
                label = stringResource(R.string.session_keyboard),
                onClick = onKeyboard,
            )
            ToolbarButton(
                icon = Icons.Outlined.ContentPaste,
                label = stringResource(R.string.session_clipboard),
                onClick = onClipboard,
            )
            Box {
                ToolbarButton(
                    icon = Icons.Outlined.Tune,
                    label = stringResource(R.string.session_quality),
                    onClick = { onQualityMenuChange(true) },
                )
                DropdownMenu(
                    expanded = qualityMenuExpanded,
                    onDismissRequest = { onQualityMenuChange(false) },
                ) {
                    QualityPreset.entries.forEach { preset ->
                        DropdownMenuItem(
                            text = { Text(preset.label()) },
                            onClick = { onQualitySelected(preset) },
                            trailingIcon = {
                                if (preset == quality) {
                                    Icon(
                                        imageVector = Icons.Outlined.Check,
                                        contentDescription = null,
                                    )
                                }
                            },
                        )
                    }
                }
            }
            ToolbarButton(
                icon = if (isFullscreen) Icons.Outlined.FullscreenExit else Icons.Outlined.Fullscreen,
                label = stringResource(
                    if (isFullscreen) {
                        R.string.session_exit_fullscreen
                    } else {
                        R.string.session_enter_fullscreen
                    },
                ),
                onClick = onToggleFullscreen,
            )
        }
    }
}

@Composable
private fun ToolbarButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
    ) {
        Icon(imageVector = icon, contentDescription = label)
    }
}

@Composable
private fun KeystrokeDialog(
    onDismiss: () -> Unit,
    onSend: (String) -> Unit,
) {
    var key by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.session_keyboard)) },
        text = {
            OutlinedTextField(
                value = key,
                onValueChange = { if (it.length <= 1) key = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.session_keyboard_hint)) },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onSend(key) },
                enabled = key.isNotEmpty(),
            ) {
                Text(stringResource(R.string.session_keyboard_action))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.editor_cancel))
            }
        },
    )
}

@Composable
private fun ClipboardDialog(
    onDismiss: () -> Unit,
    onSend: (String) -> Unit,
) {
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.session_clipboard)) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.session_clipboard_hint)) },
                minLines = 3,
                maxLines = 5,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onSend(text) },
                enabled = text.isNotEmpty(),
            ) {
                Text(stringResource(R.string.session_clipboard_action))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.editor_cancel))
            }
        },
    )
}

private fun remotePoint(
    offset: Offset,
    size: IntSize,
    remoteWidth: Int,
    remoteHeight: Int,
): Pair<Int, Int> {
    if (size.width == 0 || size.height == 0) return 0 to 0
    val x = (offset.x / size.width * remoteWidth).roundToInt().coerceIn(0, remoteWidth - 1)
    val y = (offset.y / size.height * remoteHeight).roundToInt().coerceIn(0, remoteHeight - 1)
    return x to y
}

/**
 * Maps a character to an X11 keysym. Printable Latin-1 keeps its code point; everything
 * else uses the Unicode keysym range, matching how RFB servers translate KeyEvents.
 */
private fun x11Keysym(char: Char): Int {
    val code = char.code
    return if (code in 0x20..0x7E || code in 0xA0..0xFF) {
        code
    } else {
        0x0100_0000 or code
    }
}

private fun statusColor(status: SessionStatus): Color = when (status) {
    SessionStatus.Connecting -> Color(0xFFF2C14E)
    SessionStatus.Connected -> Color(0xFF6FDD9B)
    SessionStatus.Disconnected -> Color(0xFFBFC8C8)
    SessionStatus.Failed -> Color(0xFFFFB4AB)
}
