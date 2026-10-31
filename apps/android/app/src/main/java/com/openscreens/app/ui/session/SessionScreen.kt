package com.openscreens.app.ui.session

import android.content.ClipData
import android.content.ClipboardManager
import android.net.Uri
import android.os.Environment
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.automirrored.outlined.KeyboardReturn
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.KeyboardHide
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.Mouse
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
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
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SshKey
import com.openscreens.app.session.RemoteSession
import com.openscreens.app.session.DisplayScreen
import com.openscreens.app.session.SessionEvent
import com.openscreens.app.session.uploadPickedFiles
import com.openscreens.app.session.SessionProvider
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.theme.SystemBarIconAppearance
import com.openscreens.app.ui.theme.findActivity
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private val SessionBackdrop = Color(0xFF060808)
private val FramebufferBackground = Color(0xFF000000)

private enum class SessionStatus { Connecting, Connected, Disconnected, Failed }

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SessionScreen(
    connection: Connection,
    sshKey: SshKey?,
    quality: QualityPreset,
    onQualityChange: (QualityPreset) -> Unit,
    onConnected: () -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val snackbarHostState = remember { SnackbarHostState() }

    val session: RemoteSession = remember(connection.id) {
        SessionProvider.create(context, connection, quality, sshKey)
    }

    var status by remember { mutableStateOf(SessionStatus.Connecting) }
    var remoteWidth by remember { mutableIntStateOf(0) }
    var remoteHeight by remember { mutableIntStateOf(0) }
    var frame by remember { mutableStateOf<SessionEvent.Frame?>(null) }
    var lastAction by remember { mutableStateOf<String?>(null) }
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var pressIndicator by remember { mutableStateOf<PressIndicator?>(null) }
    var showClipboardDialog by rememberSaveable { mutableStateOf(false) }
    var qualityMenuExpanded by remember { mutableStateOf(false) }
    var isFullscreen by rememberSaveable { mutableStateOf(true) }
    var isExiting by remember { mutableStateOf(false) }
    var chromeVisible by rememberSaveable { mutableStateOf(true) }
    var keyboardActive by remember { mutableStateOf(false) }
    var modifiers by remember { mutableIntStateOf(0) }
    var backgroundedAt by remember { mutableLongStateOf(0L) }
    var cursor by remember { mutableStateOf<SessionEvent.Cursor?>(null) }
    var cursorPosition by remember { mutableStateOf<IntOffset?>(null) }
    var viewport by remember { mutableStateOf<SessionEvent.Viewport?>(null) }
    var trackpadMode by rememberSaveable { mutableStateOf(false) }
    var desktopScreens by remember { mutableStateOf<List<DisplayScreen>>(emptyList()) }
    var displayMenuExpanded by remember { mutableStateOf(false) }
    var showDownloadDialog by remember { mutableStateOf(false) }
    var downloadRoot by remember { mutableStateOf<String?>(null) }
    var trackpadPointer by remember { mutableStateOf<IntOffset?>(null) }
    var pendingUpload by remember { mutableStateOf<PendingUpload?>(null) }
    var transferLabel by remember { mutableStateOf<String?>(null) }

    val sendFilePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val handle = session.nextTransferHandle()
            pendingUpload = PendingUpload(handle, uris)
            runCatching {
                session.announceUpload(
                    handle,
                    uris.indices.map { index -> "file:///android/$index" },
                )
            }.onFailure { error ->
                pendingUpload = null
                snackbarHostState.showSnackbar(
                    context.getString(R.string.session_upload_failed, error.message ?: ""),
                )
            }
        }
    }

    val focusRequester = remember { FocusRequester() }
    val pointerMemory = remember(session) { PointerMemory() }
    val taps = remember(session) { DeferredTapController() }
    val twoFingerTaps = remember(session) { DeferredTapController() }
    val trackPointer: (Int, Int) -> Unit = { x, y ->
        cursorPosition = IntOffset(x, y)
        pointerMemory.remember(x, y)
    }

    val togglePointerMode: () -> Unit = {
        val next = !trackpadMode
        trackpadMode = next
        if (next) {
            val region = viewport
            val pointer = trackpadPointer ?: if (region != null) {
                IntOffset(region.x + region.width / 2, region.y + region.height / 2)
            } else {
                IntOffset(remoteWidth / 2, remoteHeight / 2)
            }
            trackpadPointer = pointer
            trackPointer(pointer.x, pointer.y)
            session.sendPointer(pointer.x, pointer.y, 0)
        }
        lastAction = context.getString(
            R.string.session_action_prefix,
            context.getString(
                if (next) {
                    R.string.session_pointer_trackpad
                } else {
                    R.string.session_pointer_direct
                },
            ),
        )
    }

    val imeVisible = WindowInsets.isImeVisible
    // Focus may survive the IME being dismissed with Back. Drop the accessory row shortly
    // after the IME really goes away, but leave enough time for it to open on slow devices.
    LaunchedEffect(keyboardActive, imeVisible) {
        if (keyboardActive && !imeVisible) {
            delay(IME_OPEN_GRACE_MS)
            keyboardActive = false
        }
    }

    LaunchedEffect(keyboardActive) {
        if (keyboardActive) {
            focusRequester.requestFocus()
        } else {
            focusManager.clearFocus()
        }
    }

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
    // When the soft keyboard is up, Back should close it before it disconnects.
    BackHandler(enabled = keyboardActive) { keyboardActive = false }

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
                SessionEvent.Connecting -> {
                    status = SessionStatus.Connecting
                    cursor = null
                    cursorPosition = null
                    // A new session starts on a fresh transport: the old bitmap is
                    // cropped to a viewport the new session knows nothing about.
                    frame = null
                    viewport = null
                }
                is SessionEvent.Connected -> {
                    status = SessionStatus.Connected
                    remoteWidth = event.width
                    remoteHeight = event.height
                    // The core publishes a whole-framebuffer viewport on connect and
                    // emits the new crop with its first complete frame.
                    frame = null
                    viewport = null
                    onConnected()
                }
                is SessionEvent.Resized -> {
                    remoteWidth = event.width
                    remoteHeight = event.height
                    // Frame and viewport stay paired: keep the previous crop so the
                    // stale bitmap is drawn at its real geometry instead of being
                    // stretched over the whole framebuffer.
                    if (!viewportFits(viewport, event.width, event.height)) {
                        frame = null
                        viewport = null
                    }
                }
                is SessionEvent.DesktopLayout -> {
                    remoteWidth = event.width
                    remoteHeight = event.height
                    desktopScreens = event.screens
                    if (!viewportFits(viewport, event.width, event.height)) {
                        frame = null
                        viewport = null
                    }
                }
                is SessionEvent.Viewport -> viewport = event
                is SessionEvent.Frame -> {
                    status = SessionStatus.Connected
                    frame = event
                }
                is SessionEvent.Cursor -> cursor = event
                is SessionEvent.UploadRequest -> {
                    val pending = pendingUpload?.takeIf { it.handle == event.handle }
                    pendingUpload = null
                    if (pending != null) {
                        scope.launch {
                            transferLabel = context.getString(R.string.session_upload_preparing)
                            try {
                                uploadPickedFiles(
                                    session = session,
                                    handle = event.handle,
                                    destination = event.path,
                                    uris = pending.uris,
                                    resolver = context.contentResolver,
                                    cacheDir = context.cacheDir,
                                ) { name -> transferLabel = if (name.isEmpty()) null else name }
                                snackbarHostState.showSnackbar(
                                    context.getString(
                                        R.string.session_upload_done,
                                        pending.uris.size,
                                    ),
                                )
                            } catch (error: Exception) {
                                runCatching { session.cancelTransfer(event.handle) }
                                snackbarHostState.showSnackbar(
                                    context.getString(
                                        R.string.session_upload_failed,
                                        error.message ?: error.javaClass.simpleName,
                                    ),
                                )
                            } finally {
                                transferLabel = null
                            }
                        }
                    }
                }
                is SessionEvent.TransferProgress -> {
                    event.name?.let { transferLabel = it }
                }
                is SessionEvent.TransferComplete -> transferLabel = null
                is SessionEvent.RemoteClipboard -> {
                    context.getSystemService(ClipboardManager::class.java)
                        ?.setPrimaryClip(
                            ClipData.newPlainText(
                                context.getString(R.string.app_name),
                                event.text,
                            ),
                        )
                    lastAction = context.getString(
                        R.string.session_action_prefix,
                        context.getString(R.string.session_clipboard_received),
                    )
                }
                is SessionEvent.DownloadProgress -> {
                    transferLabel = buildString {
                        append(
                            event.name
                                ?: context.getString(R.string.session_download_progress_fallback),
                        )
                        if (event.total > 0) {
                            append(' ')
                            append(event.bytes * 100 / event.total)
                            append('%')
                        }
                    }
                }
                is SessionEvent.DownloadComplete -> {
                    transferLabel = null
                    val root = downloadRoot
                    scope.launch {
                        if (event.error == null && root != null) {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.session_download_saved, root),
                            )
                        } else if (event.error != null) {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.session_download_failed, event.error),
                            )
                        }
                    }
                }
                is SessionEvent.DragInfo,
                is SessionEvent.FileTransfer,
                -> Unit
                is SessionEvent.Disconnected -> {
                    status = SessionStatus.Disconnected
                    if (!isExiting) {
                        scope.launch {
                            snackbarHostState.showSnackbar(
                                event.message
                                    ?: context.getString(R.string.session_status_disconnected),
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

    // A backgrounded app may come back with a suspended socket: the poller is still
    // blocked in a read that never returns, so no event ever flips the UI out of
    // "Connected". Rebuild the transport once the app has been away long enough.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, session) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> backgroundedAt = SystemClock.elapsedRealtime()
                Lifecycle.Event.ON_START -> {
                    val leftAt = backgroundedAt
                    backgroundedAt = 0L
                    if (leftAt == 0L || isExiting) return@LifecycleEventObserver
                    val away = SystemClock.elapsedRealtime() - leftAt
                    val lostWhileAway = status == SessionStatus.Disconnected ||
                        status == SessionStatus.Failed
                    val stale = away >= RESUME_RECONNECT_MS && status == SessionStatus.Connected
                    if (lostWhileAway || stale) {
                        scope.launch { session.reconnect() }
                    }
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    DisposableEffect(session) {
        onDispose { session.close() }
    }

    LaunchedEffect(remoteWidth, remoteHeight) {
        zoom = 1f
        pan = Offset.Zero
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

    // Sticky modifiers are pressed for the duration of one key chord, then released so
    // they cannot get stuck on the remote if the connection drops mid-chord.
    val sendKeysym: (Int) -> Unit = { keysym ->
        val active = MODIFIER_KEYS.filter { modifiers and it.flag != 0 }
        active.forEach { session.sendKey(it.keysym, true) }
        session.sendKey(keysym, true)
        session.sendKey(keysym, false)
        active.asReversed().forEach { session.sendKey(it.keysym, false) }
    }

    val sendLabelledKey: (Int, String) -> Unit = { keysym, label ->
        sendKeysym(keysym)
        lastAction = context.getString(
            R.string.session_action_prefix,
            context.getString(R.string.session_key_sent, label),
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
        val aspect = if (remoteWidth > 0 && remoteHeight > 0) {
            (remoteWidth.toFloat() / remoteHeight.toFloat()).coerceAtLeast(0.1f)
        } else {
            // Unknown until Connected; keep layout valid (NaN aspectRatio crashes).
            16f / 9f
        }
        val canvasWidth = min(maxWidth.value, maxHeight.value * aspect).dp

        // Subscribe only to the region the viewport shows, and ask for a
        // sampling density that matches the current zoom. Debounced so a pinch
        // or pan settles before the region is re-requested.
        val density = LocalDensity.current
        val canvasPixelWidth = with(density) { canvasWidth.toPx() }
        val canvasPixelHeight = canvasPixelWidth / aspect
        val screenPixelWidth = with(density) { maxWidth.toPx() }
        val screenPixelHeight = with(density) { maxHeight.toPx() }
        val screenSizePx = IntSize(
            screenPixelWidth.roundToInt(),
            screenPixelHeight.roundToInt(),
        )
        val bandSizePx = IntSize(
            canvasPixelWidth.roundToInt(),
            canvasPixelHeight.roundToInt(),
        )
        LaunchedEffect(
            session,
            status,
            zoom,
            pan,
            remoteWidth,
            remoteHeight,
            canvasPixelWidth,
            canvasPixelHeight,
            screenPixelWidth,
            screenPixelHeight,
        ) {
            if (status != SessionStatus.Connected ||
                remoteWidth <= 1 || remoteHeight <= 1 || canvasPixelWidth < 1f
            ) {
                return@LaunchedEffect
            }
            delay(VIEWPORT_SETTLE_MS)
            val rect = visibleServerRect(
                zoom = zoom,
                pan = pan,
                bandWidth = canvasPixelWidth,
                bandHeight = canvasPixelHeight,
                screenWidth = screenPixelWidth,
                screenHeight = screenPixelHeight,
                serverWidth = remoteWidth,
                serverHeight = remoteHeight,
            )
            session.setViewport(
                rect[0],
                rect[1],
                rect[2],
                rect[3],
                screenPixelWidth.roundToInt(),
            )
        }

        HiddenKeyboardField(
            focusRequester = focusRequester,
            onChar = { char -> sendKeysym(if (char == '\n') KEY_RETURN else x11Keysym(char)) },
            onBackspace = { sendKeysym(KEY_BACKSPACE) },
            onFocusChange = { focused -> if (!focused) keyboardActive = false },
            modifier = Modifier.align(Alignment.TopStart),
        )

        val zoomed = zoom > ZOOM_ACTIVE_EPSILON
        val zoomEnabled = connection.zoomEnabled
        val longPressSlop = with(density) { 12.dp.toPx() }
        val swipeThreshold = with(density) { 48.dp.toPx() }
        Box(
            modifier = Modifier
                .fillMaxSize()
                // Gestures use screen coordinates: the band below is scaled by a
                // graphicsLayer, and pointer deltas read inside that layer would
                // feed the new zoom back into the next delta.
                .pointerInput(session, remoteWidth, remoteHeight, trackpadMode, zoomEnabled) {
                    // No framebuffer yet: pointer math would divide by zero and
                    // round NaN coordinates.
                    if (remoteWidth <= 1 || remoteHeight <= 1) return@pointerInput
                    val touchSlop = viewConfiguration.touchSlop
                    val doubleTapTimeout = viewConfiguration.doubleTapTimeoutMillis.toLong()
                    val longPressTimeout = viewConfiguration.longPressTimeoutMillis
                    val doubleTapSlop = touchSlop * 2.5f
                    val wheelStep = WHEEL_STEP_PX
                    val screenSize = size

                    fun isInsideContent(position: Offset): Boolean {
                        val halfWidth = bandSizePx.width * zoom / 2f
                        val halfHeight = bandSizePx.height * zoom / 2f
                        val centerX = screenSize.width / 2f + pan.x * zoom
                        val centerY = screenSize.height / 2f + pan.y * zoom
                        return abs(position.x - centerX) <= halfWidth &&
                            abs(position.y - centerY) <= halfHeight
                    }

                    fun sendPointerClick(x: Int, y: Int) {
                        session.sendPointer(x, y, 0)
                        session.sendPointer(x, y, 1)
                        session.sendPointer(x, y, 0)
                        trackPointer(x, y)
                        recordPointer(x, y)
                    }

                    fun cancelPendingTap() {
                        taps.job?.cancel()
                        taps.job = null
                        taps.pending = null
                    }

                    fun flushPendingTap() {
                        val pending = taps.pending ?: return
                        cancelPendingTap()
                        sendPointerClick(pending.x, pending.y)
                    }

                    fun scheduleTap(x: Int, y: Int, position: Offset, time: Long) {
                        val pending = PendingTap(x, y, position, time)
                        taps.pending = pending
                        taps.job = scope.launch {
                            // A small margin keeps the deferred click from winning a race
                            // against a second tap that arrives exactly at the timeout.
                            delay(doubleTapTimeout + DOUBLE_TAP_CLICK_MARGIN_MS)
                            if (taps.pending === pending) {
                                taps.pending = null
                                taps.job = null
                                sendPointerClick(x, y)
                            }
                        }
                    }

                    fun sendWheel(mask: Int, labelRes: Int) {
                        val (x, y) = pointerMemory.resolve(remoteWidth, remoteHeight)
                        cursorPosition = IntOffset(x, y)
                        session.sendPointer(x, y, mask)
                        session.sendPointer(x, y, 0)
                        lastAction = context.getString(
                            R.string.session_action_prefix,
                            context.getString(labelRes),
                        )
                    }

                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        if (!isInsideContent(down.position)) {
                            // Letterbox taps still toggle the session chrome; they
                            // must not reach the remote pointer.
                            var moved = false
                            while (true) {
                                val event = withTimeoutOrNull(50L) { awaitPointerEvent() }
                                    ?: continue
                                val pressed = event.changes.filter { it.pressed }
                                if (pressed.isEmpty()) break
                                if (pressed.size > 1 ||
                                    (pressed.first().position - down.position)
                                        .getDistance() > touchSlop
                                ) {
                                    moved = true
                                }
                            }
                            if (!moved) chromeVisible = !chromeVisible
                            return@awaitEachGesture
                        }
                        val previousTap = taps.pending
                        val isDoubleTap = previousTap != null &&
                            down.uptimeMillis - previousTap.time <= doubleTapTimeout &&
                            (down.position - previousTap.position).getDistance() <= doubleTapSlop
                        if (previousTap != null) {
                            if (isDoubleTap) cancelPendingTap() else flushPendingTap()
                        }

                        var mode = GestureMode.Pending
                        var start = remotePoint(
                            down.position,
                            screenSize,
                            bandSizePx,
                            remoteWidth,
                            remoteHeight,
                            zoom,
                            pan,
                        )
                        var last = start
                        var lastTouch = down.position
                        val downTime = SystemClock.uptimeMillis()

                        // Two-finger state: a pinch is anchored at the touch
                        // centroid, a drag scrolls at 1x and pans when zoomed.
                        var multiTouchStartZoom = zoom
                        var multiTouchStartPan = pan
                        var multiTouchStartCentroid = Offset.Zero
                        var multiTouchZoom = 1f
                        var scrollAccum = Offset.Zero
                        var threeFinger = false
                        var multiTouchMoved = false
                        var multiTouchTapCandidate = false
                        val screenCenter = Offset(
                            screenSize.width / 2f,
                            screenSize.height / 2f,
                        )

                        // Long press holds a button down for dragging: one finger
                        // holds the left button, two the right, three the middle.
                        // Movement or a change in finger count cancels it.
                        var holdTouches = 1
                        var holdStartedAt = down.uptimeMillis
                        var holdAnchor = down.position
                        var currentTouches = 1
                        var currentCentroid = down.position
                        var pressActive = false
                        var pressTouches = 0
                        var pressButton = 0
                        var pressTarget = start
                        var threeFingerSwipe: SwipeDirection? = null
                        var threeFingerStart = Offset.Zero

                        fun movePress(position: Offset) {
                            currentCentroid = position
                            pressIndicator = pressIndicator?.copy(position = position)
                            if (!trackpadMode) {
                                pressTarget = remotePoint(
                                    position,
                                    screenSize,
                                    bandSizePx,
                                    remoteWidth,
                                    remoteHeight,
                                    zoom,
                                    pan,
                                )
                            }
                            session.sendPointer(pressTarget.first, pressTarget.second, pressButton)
                            trackPointer(pressTarget.first, pressTarget.second)
                        }

                        fun beginPress() {
                            if (pressActive || holdTouches == 0 ||
                                currentTouches != holdTouches
                            ) {
                                return
                            }
                            if (SystemClock.uptimeMillis() - holdStartedAt < longPressTimeout) return
                            if (!isInsideContent(currentCentroid)) {
                                holdTouches = 0
                                return
                            }
                            val button = when (currentTouches) {
                                1 -> 1
                                2 -> 1 shl 2
                                else -> 1 shl 1
                            }
                            pressTarget = if (trackpadMode) {
                                trackpadPointer?.let { it.x to it.y }
                                    ?: remotePoint(
                                        currentCentroid,
                                        screenSize,
                                        bandSizePx,
                                        remoteWidth,
                                        remoteHeight,
                                        zoom,
                                        pan,
                                    )
                            } else {
                                remotePoint(
                                    currentCentroid,
                                    screenSize,
                                    bandSizePx,
                                    remoteWidth,
                                    remoteHeight,
                                    zoom,
                                    pan,
                                )
                            }
                            pressActive = true
                            pressTouches = currentTouches
                            pressButton = button
                            pressIndicator = PressIndicator(
                                pressIndicatorColor(button),
                                currentCentroid,
                            )
                            session.sendPointer(pressTarget.first, pressTarget.second, 0)
                            session.sendPointer(pressTarget.first, pressTarget.second, button)
                            trackPointer(pressTarget.first, pressTarget.second)
                            recordPointer(pressTarget.first, pressTarget.second)
                            multiTouchTapCandidate = false
                            multiTouchMoved = true
                            threeFingerSwipe = null
                            holdTouches = 0
                        }

                        fun endPress() {
                            if (!pressActive) return
                            session.sendPointer(pressTarget.first, pressTarget.second, 0)
                            trackPointer(pressTarget.first, pressTarget.second)
                            pressActive = false
                            pressIndicator = null
                        }

                        fun sendClick(x: Int, y: Int, mask: Int) {
                            session.sendPointer(x, y, 0)
                            session.sendPointer(x, y, mask)
                            session.sendPointer(x, y, 0)
                            trackPointer(x, y)
                            recordPointer(x, y)
                        }

                        fun sendDoubleClick(x: Int, y: Int) {
                            sendClick(x, y, 1)
                            sendClick(x, y, 1)
                        }

                        fun applyPinch(centroid: Offset) {
                            val newZoom = (multiTouchStartZoom * multiTouchZoom)
                                .coerceIn(1f, MAX_ZOOM)
                            val newPan = clampPan(
                                multiTouchStartPan +
                                    (centroid - screenCenter) / newZoom -
                                    (multiTouchStartCentroid - screenCenter) /
                                    multiTouchStartZoom,
                                newZoom,
                                bandSizePx,
                                screenSizePx,
                            )
                            zoom = newZoom
                            pan = newPan
                        }

                        fun scheduleTwoFingerTap(position: Offset) {
                            val target = if (trackpadMode) {
                                trackpadPointer?.let { it.x to it.y }
                                    ?: remotePoint(
                                        position,
                                        screenSize,
                                        bandSizePx,
                                        remoteWidth,
                                        remoteHeight,
                                        zoom,
                                        pan,
                                    )
                            } else {
                                remotePoint(
                                    position,
                                    screenSize,
                                    bandSizePx,
                                    remoteWidth,
                                    remoteHeight,
                                    zoom,
                                    pan,
                                )
                            }
                            val pending = PendingTap(
                                target.first,
                                target.second,
                                position,
                                SystemClock.uptimeMillis(),
                            )
                            twoFingerTaps.job?.cancel()
                            twoFingerTaps.pending = pending
                            twoFingerTaps.job = scope.launch {
                                delay(doubleTapTimeout + DOUBLE_TAP_CLICK_MARGIN_MS)
                                if (twoFingerTaps.pending === pending) {
                                    twoFingerTaps.pending = null
                                    twoFingerTaps.job = null
                                    sendClick(target.first, target.second, 1 shl 2)
                                }
                            }
                        }

                        fun handleTwoFingerTap(position: Offset) {
                            val now = SystemClock.uptimeMillis()
                            val previous = twoFingerTaps.pending
                            if (previous != null) {
                                twoFingerTaps.job?.cancel()
                                twoFingerTaps.pending = null
                                twoFingerTaps.job = null
                                if (now - previous.time <= doubleTapTimeout &&
                                    (position - previous.position).getDistance() <= doubleTapSlop
                                ) {
                                    chromeVisible = !chromeVisible
                                    return
                                }
                                sendClick(previous.x, previous.y, 1 shl 2)
                            }
                            scheduleTwoFingerTap(position)
                        }

                        while (true) {
                            val event = withTimeoutOrNull(50L) { awaitPointerEvent() }
                            if (event == null) {
                                // Fingers held still produce no events: this is
                                // where the long-press timer actually fires.
                                beginPress()
                                continue
                            }
                            if (event.changes.any { it.pressed }) beginPress()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (pressActive && pressed.size < pressTouches) break
                            if (mode == GestureMode.Transform && pressed.size < 2) break
                            if (mode == GestureMode.TwoFinger && pressed.size < 2) break
                            if (mode == GestureMode.Scroll && pressed.size < 2) break

                            if (pressed.size >= 2) {
                                currentTouches = pressed.size
                                val centroidNow = event.calculateCentroid(useCurrent = true)
                                currentCentroid = centroidNow
                                if (pressActive) {
                                    movePress(centroidNow)
                                    event.changes.forEach { it.consume() }
                                    continue
                                }
                                if (holdTouches > 0 && (pressed.size != holdTouches ||
                                        (centroidNow - holdAnchor).getDistance() > longPressSlop)
                                ) {
                                    holdTouches = 0
                                }
                                if (mode == GestureMode.Pending || mode == GestureMode.Drag ||
                                    mode == GestureMode.Move
                                ) {
                                    if (mode == GestureMode.Drag) {
                                        session.sendPointer(last.first, last.second, 0)
                                        trackPointer(last.first, last.second)
                                    }
                                    multiTouchTapCandidate = mode == GestureMode.Pending
                                    mode = if (zoomEnabled && zoom > ZOOM_ACTIVE_EPSILON) {
                                        GestureMode.Transform
                                    } else {
                                        GestureMode.TwoFinger
                                    }
                                    multiTouchStartZoom = zoom
                                    multiTouchStartPan = pan
                                    multiTouchStartCentroid = centroidNow
                                    multiTouchZoom = 1f
                                    scrollAccum = Offset.Zero
                                    threeFinger = pressed.size >= 3
                                    threeFingerStart = centroidNow
                                    threeFingerSwipe = null
                                    holdTouches = pressed.size.coerceAtMost(3)
                                    holdStartedAt = SystemClock.uptimeMillis()
                                    holdAnchor = centroidNow
                                    multiTouchMoved = false
                                    // The pointer count changed on this event, so its pan and
                                    // zoom deltas are not meaningful. Start clean next event.
                                    event.changes.forEach { it.consume() }
                                    continue
                                }

                                if (threeFinger || pressed.size >= 3) {
                                    if (!threeFinger) {
                                        threeFinger = true
                                        threeFingerStart = centroidNow
                                        threeFingerSwipe = null
                                    }
                                    if (threeFingerSwipe == null) {
                                        val delta = centroidNow - threeFingerStart
                                        if (max(abs(delta.x), abs(delta.y)) > swipeThreshold) {
                                            threeFingerSwipe = if (abs(delta.x) > abs(delta.y)) {
                                                if (delta.x > 0f) {
                                                    SwipeDirection.Right
                                                } else {
                                                    SwipeDirection.Left
                                                }
                                            } else if (delta.y > 0f) {
                                                SwipeDirection.Down
                                            } else {
                                                SwipeDirection.Up
                                            }
                                            multiTouchMoved = true
                                            multiTouchTapCandidate = false
                                            holdTouches = 0
                                        }
                                    }
                                    event.changes.forEach { it.consume() }
                                    continue
                                }

                                when (mode) {
                                    GestureMode.TwoFinger -> {
                                        if (zoomEnabled) {
                                            multiTouchZoom *= event.calculateZoom()
                                        }
                                        if (zoomEnabled &&
                                            abs(multiTouchZoom - 1f) > PINCH_ZOOM_EPSILON
                                        ) {
                                            // A pinch always wins over scrolling.
                                            multiTouchMoved = true
                                            multiTouchTapCandidate = false
                                            holdTouches = 0
                                            mode = GestureMode.Transform
                                            applyPinch(centroidNow)
                                        } else if ((centroidNow - multiTouchStartCentroid)
                                                .getDistance() > touchSlop * 2f
                                        ) {
                                            multiTouchTapCandidate = false
                                            holdTouches = 0
                                            mode = GestureMode.Scroll
                                            scrollAccum = Offset.Zero
                                        }
                                        event.changes.forEach { it.consume() }
                                        continue
                                    }

                                    GestureMode.Scroll -> {
                                        val panChange = event.calculatePan()
                                        if (zoomEnabled) {
                                            multiTouchZoom *= event.calculateZoom()
                                        }
                                        if (zoomEnabled &&
                                            abs(multiTouchZoom - 1f) > PINCH_ZOOM_EPSILON
                                        ) {
                                            multiTouchMoved = true
                                            multiTouchTapCandidate = false
                                            mode = GestureMode.Transform
                                            applyPinch(centroidNow)
                                            event.changes.forEach { it.consume() }
                                            continue
                                        }

                                        scrollAccum += panChange
                                        var steps = 0
                                        while (steps < MAX_WHEEL_STEPS_PER_EVENT) {
                                            val ax = abs(scrollAccum.x)
                                            val ay = abs(scrollAccum.y)
                                            if (max(ax, ay) < wheelStep) break
                                            if (ay >= ax) {
                                                val fingersUp = scrollAccum.y < 0f
                                                // Natural touch scrolling: content follows fingers.
                                                sendWheel(
                                                    if (fingersUp) WHEEL_DOWN else WHEEL_UP,
                                                    if (fingersUp) {
                                                        R.string.session_scroll_down
                                                    } else {
                                                        R.string.session_scroll_up
                                                    },
                                                )
                                                scrollAccum = Offset(
                                                    scrollAccum.x,
                                                    scrollAccum.y -
                                                        (if (fingersUp) -1f else 1f) * wheelStep,
                                                )
                                            } else {
                                                val fingersLeft = scrollAccum.x < 0f
                                                sendWheel(
                                                    if (fingersLeft) WHEEL_RIGHT else WHEEL_LEFT,
                                                    if (fingersLeft) {
                                                        R.string.session_scroll_right
                                                    } else {
                                                        R.string.session_scroll_left
                                                    },
                                                )
                                                scrollAccum = Offset(
                                                    scrollAccum.x -
                                                        (if (fingersLeft) -1f else 1f) * wheelStep,
                                                    scrollAccum.y,
                                                )
                                            }
                                            steps++
                                        }
                                        event.changes.forEach { it.consume() }
                                        continue
                                    }

                                    GestureMode.Transform -> {
                                        if (zoomEnabled) {
                                            multiTouchZoom *= event.calculateZoom()
                                            applyPinch(centroidNow)
                                        }
                                        event.changes.forEach { it.consume() }
                                        continue
                                    }

                                    else -> Unit
                                }
                            }

                            if (mode == GestureMode.Transform || mode == GestureMode.TwoFinger ||
                                mode == GestureMode.Scroll
                            ) {
                                continue
                            }

                            val change = pressed.first()
                            currentTouches = 1
                            currentCentroid = change.position
                            if (pressActive) {
                                movePress(change.position)
                                change.consume()
                                continue
                            }
                            if (holdTouches == 1 &&
                                (change.position - holdAnchor).getDistance() > longPressSlop
                            ) {
                                holdTouches = 0
                            }
                            if (mode == GestureMode.Pending &&
                                (change.position - down.position).getDistance() > touchSlop
                            ) {
                                if (trackpadMode) {
                                    mode = GestureMode.Move
                                    val pointer = trackpadPointer ?: IntOffset(
                                        remoteWidth / 2,
                                        remoteHeight / 2,
                                    )
                                    trackpadPointer = pointer
                                    trackPointer(pointer.x, pointer.y)
                                } else {
                                    mode = GestureMode.Drag
                                    session.sendPointer(start.first, start.second, 1)
                                    trackPointer(start.first, start.second)
                                    recordPointer(start.first, start.second)
                                }
                            }
                            if (mode == GestureMode.Drag) {
                                last = remotePoint(
                                    change.position,
                                    screenSize,
                                    bandSizePx,
                                    remoteWidth,
                                    remoteHeight,
                                    zoom,
                                    pan,
                                )
                                session.sendPointer(last.first, last.second, 1)
                                trackPointer(last.first, last.second)
                                change.consume()
                            } else if (mode == GestureMode.Move) {
                                val delta = change.position - lastTouch
                                lastTouch = change.position
                                val region = viewport
                                val base = trackpadPointer
                                    ?: IntOffset(remoteWidth / 2, remoteHeight / 2)
                                // The cursor follows the finger 1:1 on screen, so a
                                // screen pixel maps to a smaller framebuffer step
                                // as the image is magnified.
                                val scaleX = remoteWidth.toFloat() /
                                    (bandSizePx.width * zoom).coerceAtLeast(1f)
                                val scaleY = remoteHeight.toFloat() /
                                    (bandSizePx.height * zoom).coerceAtLeast(1f)
                                val minX = region?.x ?: 0
                                val minY = region?.y ?: 0
                                val maxX = (region?.let { it.x + it.width } ?: remoteWidth) - 1
                                val maxY = (region?.let { it.y + it.height } ?: remoteHeight) - 1
                                val nextX = (base.x + delta.x * scaleX).roundToInt().coerceIn(minX, maxX)
                                val nextY = (base.y + delta.y * scaleY).roundToInt().coerceIn(minY, maxY)
                                trackpadPointer = IntOffset(nextX, nextY)
                                trackPointer(nextX, nextY)
                                session.sendPointer(nextX, nextY, 0)
                                change.consume()
                            }
                        }

                        if (pressActive) {
                            endPress()
                        } else when (mode) {
                            GestureMode.Drag -> {
                                session.sendPointer(last.first, last.second, 0)
                                trackPointer(last.first, last.second)
                            }
                            GestureMode.Pending -> {
                                if (isDoubleTap) {
                                    val target = if (trackpadMode) {
                                        trackpadPointer?.let { it.x to it.y } ?: start
                                    } else {
                                        start
                                    }
                                    sendDoubleClick(target.first, target.second)
                                } else {
                                    val tapTarget = if (trackpadMode) {
                                        trackpadPointer?.let { it.x to it.y } ?: start
                                    } else {
                                        start
                                    }
                                    // Hold the click briefly so a double tap can click twice.
                                    scheduleTap(
                                        tapTarget.first,
                                        tapTarget.second,
                                        down.position,
                                        SystemClock.uptimeMillis(),
                                    )
                                }
                            }
                            else -> {
                                val swipe = threeFingerSwipe
                                if (swipe != null) {
                                    val keysym = when (swipe) {
                                        SwipeDirection.Up -> KEY_UP
                                        SwipeDirection.Down -> KEY_DOWN
                                        SwipeDirection.Left -> KEY_LEFT
                                        SwipeDirection.Right -> KEY_RIGHT
                                    }
                                    session.sendKey(KEY_CONTROL, true)
                                    session.sendKey(keysym, true)
                                    session.sendKey(keysym, false)
                                    session.sendKey(KEY_CONTROL, false)
                                } else if (multiTouchTapCandidate && !multiTouchMoved &&
                                    SystemClock.uptimeMillis() - downTime <= TAP_TIMEOUT_MS
                                ) {
                                    if (threeFinger) {
                                        val target = if (trackpadMode) {
                                            trackpadPointer?.let { it.x to it.y }
                                                ?: remotePoint(
                                                    multiTouchStartCentroid,
                                                    screenSize,
                                                    bandSizePx,
                                                    remoteWidth,
                                                    remoteHeight,
                                                    zoom,
                                                    pan,
                                                )
                                        } else {
                                            remotePoint(
                                                multiTouchStartCentroid,
                                                screenSize,
                                                bandSizePx,
                                                remoteWidth,
                                                remoteHeight,
                                                zoom,
                                                pan,
                                            )
                                        }
                                        sendClick(target.first, target.second, 1 shl 1)
                                    } else {
                                        handleTwoFingerTap(multiTouchStartCentroid)
                                    }
                                }
                            }
                        }
                    }
                },
        ) {
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .width(canvasWidth)
                    .aspectRatio(aspect)
                    // The letterbox frame only exists at 1x; once zoomed the image
                    // has to spill out and cover the local screen edge to edge.
                    .then(
                        if (zoomed) {
                            Modifier
                        } else {
                            Modifier
                                .clip(RoundedCornerShape(16.dp))
                                .background(FramebufferBackground)
                                .border(
                                    1.dp,
                                    Color.White.copy(alpha = 0.08f),
                                    RoundedCornerShape(16.dp),
                                )
                        },
                    )
                    .graphicsLayer {
                        scaleX = zoom
                        scaleY = zoom
                        // Pan is stored in band units; the layer moves content
                        // in parent pixels.
                        translationX = pan.x * zoom
                        translationY = pan.y * zoom
                        transformOrigin = TransformOrigin.Center
                    },
            ) {
                val live = frame
                if (live != null) {
                    Canvas(modifier = Modifier.fillMaxSize()) {
                        val crop = viewport
                        val sourceX = crop?.x ?: 0
                        val sourceY = crop?.y ?: 0
                        val sourceWidth = crop?.width ?: remoteWidth
                        val sourceHeight = crop?.height ?: remoteHeight
                        val destination = IntRect(
                            left = (sourceX.toFloat() / remoteWidth * size.width).roundToInt(),
                            top = (sourceY.toFloat() / remoteHeight * size.height).roundToInt(),
                            right = ((sourceX + sourceWidth).toFloat() / remoteWidth * size.width)
                                .roundToInt(),
                            bottom = ((sourceY + sourceHeight).toFloat() / remoteHeight * size.height)
                                .roundToInt(),
                        )
                        drawImage(
                            image = live.bitmap.asImageBitmap(),
                            srcOffset = IntOffset.Zero,
                            srcSize = IntSize(live.bitmap.width, live.bitmap.height),
                            dstOffset = IntOffset(destination.left, destination.top),
                            dstSize = IntSize(
                                (destination.right - destination.left).coerceAtLeast(1),
                                (destination.bottom - destination.top).coerceAtLeast(1),
                            ),
                            filterQuality = if (zoom > 1.2f) FilterQuality.Medium else FilterQuality.Low,
                        )
                        drawRemoteCursor(cursor, cursorPosition, remoteWidth.toFloat(), size)
                    }
                } else {
                    RemoteCanvasPlaceholder(
                        remoteWidth = remoteWidth,
                        remoteHeight = remoteHeight,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
            }
        }

        pressIndicator?.let { indicator ->
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .offset {
                        IntOffset(
                            (indicator.position.x - 11.dp.roundToPx()).roundToInt(),
                            (indicator.position.y - 11.dp.roundToPx()).roundToInt(),
                        )
                    }
                    .size(22.dp)
                    .shadow(8.dp, CircleShape)
                    .background(indicator.color.copy(alpha = 0.9f), CircleShape)
                    .border(2.dp, Color.White.copy(alpha = 0.85f), CircleShape),
            )
        }

        lastAction?.let { action ->
            InputBadge(
                text = action,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(12.dp),
            )
        }

        if (chromeVisible) {
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
        }

        transferLabel?.let { label ->
            Surface(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(top = 72.dp),
                shape = RoundedCornerShape(14.dp),
                color = Color.Black.copy(alpha = 0.65f),
                contentColor = Color.White,
            ) {
                Text(
                    text = label,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }

        if (keyboardActive) {
            SessionKeyboardBar(
                modifiers = modifiers,
                onToggleModifier = { flag -> modifiers = modifiers xor flag },
                onKey = sendLabelledKey,
                onHideKeyboard = { keyboardActive = false },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        } else if (chromeVisible) {
            SessionToolbar(
                quality = quality,
                qualityMenuExpanded = qualityMenuExpanded,
                onQualityMenuChange = { qualityMenuExpanded = it },
                onQualitySelected = selectQuality,
                isFullscreen = isFullscreen,
                trackpadMode = trackpadMode,
                onTogglePointerMode = togglePointerMode,
                displays = desktopScreens,
                displayMenuExpanded = displayMenuExpanded,
                onDisplayMenuChange = { displayMenuExpanded = it },
                onSelectDisplay = { id ->
                    displayMenuExpanded = false
                    scope.launch {
                        runCatching { session.selectDisplay(id) }
                            .onFailure { error ->
                                snackbarHostState.showSnackbar(
                                    error.message ?: context.getString(R.string.session_displays),
                                )
                            }
                    }
                },
                onKeyboard = { keyboardActive = true },
                onClipboard = { showClipboardDialog = true },
                onUpload = { sendFilePicker.launch(arrayOf("*/*")) },
                onDownload = { showDownloadDialog = true },
                onToggleFullscreen = { isFullscreen = !isFullscreen },
                onHideChrome = { chromeVisible = false },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        } else {
            ChromeRestoreButton(
                onClick = { chromeVisible = true },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(12.dp),
            )
        }

        if (zoom > 1.01f) {
            Surface(
                onClick = {
                    zoom = 1f
                    pan = Offset.Zero
                },
                shape = RoundedCornerShape(50),
                color = Color.Black.copy(alpha = 0.55f),
                contentColor = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(top = if (chromeVisible) 72.dp else 12.dp, end = 12.dp),
            ) {
                Text(
                    text = stringResource(R.string.session_zoom_level, zoom),
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
        }

        SnackbarHost(
            hostState = snackbarHostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(start = 16.dp, end = 16.dp, bottom = 76.dp),
        )
    }

    if (showDownloadDialog) {
        DownloadDialog(
            onDismiss = { showDownloadDialog = false },
            onDownload = { path ->
                val root = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    ?: File(context.filesDir, "downloads")
                root.mkdirs()
                downloadRoot = root.absolutePath
                transferLabel = context.getString(R.string.session_download_preparing)
                showDownloadDialog = false
                scope.launch {
                    runCatching {
                        session.startDownload(session.nextTransferHandle(), path, root.absolutePath)
                    }.onFailure { error ->
                        transferLabel = null
                        snackbarHostState.showSnackbar(
                            context.getString(
                                R.string.session_download_failed,
                                error.message ?: error.javaClass.simpleName,
                            ),
                        )
                    }
                }
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

/** True when a stored crop still lies inside a framebuffer of [width] × [height]. */
private fun viewportFits(viewport: SessionEvent.Viewport?, width: Int, height: Int): Boolean {
    if (viewport == null) return false
    if (viewport.width <= 0 || viewport.height <= 0) return false
    return viewport.x + viewport.width <= width && viewport.y + viewport.height <= height
}

/** Framebuffer region visible through the screen-sized window under zoom/pan. */
private fun visibleServerRect(
    zoom: Float,
    pan: Offset,
    bandWidth: Float,
    bandHeight: Float,
    screenWidth: Float,
    screenHeight: Float,
    serverWidth: Int,
    serverHeight: Int,
): IntArray {
    val safeZoom = zoom.coerceAtLeast(0.01f)
    // The band is the 1x fit rect, scaled about its centre and panned in band
    // units; inverting the screen rect gives the visible band region.
    val halfScreenX = screenWidth / (2f * safeZoom)
    val halfScreenY = screenHeight / (2f * safeZoom)
    val left = (bandWidth / 2f - halfScreenX - pan.x).coerceIn(0f, bandWidth)
    val right = (bandWidth / 2f + halfScreenX - pan.x).coerceIn(0f, bandWidth)
    val top = (bandHeight / 2f - halfScreenY - pan.y).coerceIn(0f, bandHeight)
    val bottom = (bandHeight / 2f + halfScreenY - pan.y).coerceIn(0f, bandHeight)
    val scaleX = serverWidth / bandWidth
    val scaleY = serverHeight / bandHeight
    // Round outward so the delivered crop always covers the visible edges.
    val outLeft = floor(left * scaleX).toInt().coerceIn(0, serverWidth - 1)
    val outTop = floor(top * scaleY).toInt().coerceIn(0, serverHeight - 1)
    val outRight = ceil(right * scaleX).toInt().coerceIn(outLeft + 1, serverWidth)
    val outBottom = ceil(bottom * scaleY).toInt().coerceIn(outTop + 1, serverHeight)
    return intArrayOf(outLeft, outTop, outRight - outLeft, outBottom - outTop)
}

/**
 * Draws the client-side cursor bitmap in framebuffer coordinates, so the canvas
 * transpose (zoom and pan via graphicsLayer) applies to it automatically.
 */
private fun DrawScope.drawRemoteCursor(
    cursor: SessionEvent.Cursor?,
    position: IntOffset?,
    remoteWidth: Float,
    canvasSize: Size,
) {
    if (cursor == null || position == null || remoteWidth <= 0f) return
    val scale = canvasSize.width / remoteWidth
    val left = (position.x - cursor.hotspotX) * scale
    val top = (position.y - cursor.hotspotY) * scale
    val width = (cursor.bitmap.width * scale).roundToInt().coerceAtLeast(1)
    val height = (cursor.bitmap.height * scale).roundToInt().coerceAtLeast(1)
    drawImage(
        image = cursor.bitmap.asImageBitmap(),
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(cursor.bitmap.width, cursor.bitmap.height),
        dstOffset = IntOffset(left.roundToInt(), top.roundToInt()),
        dstSize = IntSize(width, height),
        filterQuality = FilterQuality.Low,
    )
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
        if (remoteWidth > 0 && remoteHeight > 0) {
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
            .touchBarrier()
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
    trackpadMode: Boolean,
    onTogglePointerMode: () -> Unit,
    displays: List<DisplayScreen>,
    displayMenuExpanded: Boolean,
    onDisplayMenuChange: (Boolean) -> Unit,
    onSelectDisplay: (Int?) -> Unit,
    quality: QualityPreset,
    qualityMenuExpanded: Boolean,
    onQualityMenuChange: (Boolean) -> Unit,
    onQualitySelected: (QualityPreset) -> Unit,
    isFullscreen: Boolean,
    onKeyboard: () -> Unit,
    onClipboard: () -> Unit,
    onUpload: () -> Unit,
    onDownload: () -> Unit,
    onToggleFullscreen: () -> Unit,
    onHideChrome: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .touchBarrier()
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.1f),
                shape = RoundedCornerShape(28.dp),
            ),
        shape = RoundedCornerShape(28.dp),
        color = Color.Black.copy(alpha = 0.6f),
        contentColor = Color.White,
    ) {
        Row(
            modifier = Modifier
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 6.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            ToolbarButton(
                icon = if (trackpadMode) Icons.Outlined.Mouse else Icons.Outlined.TouchApp,
                label = stringResource(
                    if (trackpadMode) {
                        R.string.session_pointer_trackpad
                    } else {
                        R.string.session_pointer_direct
                    },
                ),
                onClick = onTogglePointerMode,
            )
            if (displays.isNotEmpty()) {
                Box {
                    ToolbarButton(
                        icon = Icons.Outlined.Monitor,
                        label = stringResource(R.string.session_displays),
                        onClick = { onDisplayMenuChange(true) },
                    )
                    DropdownMenu(
                        expanded = displayMenuExpanded,
                        onDismissRequest = { onDisplayMenuChange(false) },
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.session_all_displays)) },
                            onClick = { onSelectDisplay(null) },
                        )
                        displays.forEach { screen ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        stringResource(
                                            R.string.session_display_entry,
                                            screen.width,
                                            screen.height,
                                        ),
                                    )
                                },
                                onClick = { onSelectDisplay(screen.id) },
                            )
                        }
                    }
                }
            }
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
            ToolbarButton(
                icon = Icons.Outlined.UploadFile,
                label = stringResource(R.string.session_send_file),
                onClick = onUpload,
            )
            ToolbarButton(
                icon = Icons.Outlined.Download,
                label = stringResource(R.string.session_download),
                onClick = onDownload,
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
            ToolbarButton(
                icon = Icons.Outlined.VisibilityOff,
                label = stringResource(R.string.session_hide_controls),
                onClick = onHideChrome,
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

/**
 * Invisible input field that feeds hardware and IME keystrokes to the remote. The
 * leading zero-width space keeps the field non-empty, so Backspace is observable even
 * when the user has not typed anything yet. Composing regions are not forwarded; only
 * committed text is, which keeps CJK IMEs from streaming pinyin letters to the host.
 */
@Composable
private fun HiddenKeyboardField(
    focusRequester: FocusRequester,
    onChar: (Char) -> Unit,
    onBackspace: () -> Unit,
    onFocusChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    var value by remember {
        mutableStateOf(TextFieldValue(KEYBOARD_SENTINEL, TextRange(KEYBOARD_SENTINEL.length)))
    }
    var committed by remember { mutableStateOf(KEYBOARD_SENTINEL) }

    BasicTextField(
        value = value,
        onValueChange = { next ->
            if (next.composition != null) {
                // Let the IME finish composing; nothing is sent until it commits.
                value = next
            } else {
                val old = committed
                val new = next.text
                when {
                    new.length > old.length && new.startsWith(old) ->
                        new.substring(old.length).forEach(onChar)

                    new.length < old.length && old.startsWith(new) ->
                        repeat(old.length - new.length) { onBackspace() }

                    new != old -> {
                        repeat((old.length - 1).coerceAtLeast(0)) { onBackspace() }
                        new.filter { it != KEYBOARD_SENTINEL_CHAR }.forEach(onChar)
                    }
                }
                committed = KEYBOARD_SENTINEL
                value = TextFieldValue(KEYBOARD_SENTINEL, TextRange(KEYBOARD_SENTINEL.length))
            }
        },
        modifier = modifier
            .size(1.dp)
            .alpha(0f)
            .focusRequester(focusRequester)
            .onFocusChanged { onFocusChange(it.isFocused) },
        textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.Transparent),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Text,
            imeAction = ImeAction.None,
            autoCorrectEnabled = false,
            showKeyboardOnFocus = true,
        ),
        cursorBrush = SolidColor(Color.Transparent),
        singleLine = true,
    )
}

@Composable
private fun SessionKeyboardBar(
    modifiers: Int,
    onToggleModifier: (Int) -> Unit,
    onKey: (Int, String) -> Unit,
    onHideKeyboard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val esc = stringResource(R.string.session_key_esc)
    val tab = stringResource(R.string.session_key_tab)
    val enter = stringResource(R.string.session_key_enter)
    val backspace = stringResource(R.string.session_key_backspace)
    val arrowLeft = stringResource(R.string.session_key_arrow_left)
    val arrowUp = stringResource(R.string.session_key_arrow_up)
    val arrowDown = stringResource(R.string.session_key_arrow_down)
    val arrowRight = stringResource(R.string.session_key_arrow_right)

    Surface(
        modifier = modifier
            .widthIn(max = 640.dp)
            .fillMaxWidth()
            .touchBarrier()
            .border(1.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(22.dp)),
        shape = RoundedCornerShape(22.dp),
        color = Color.Black.copy(alpha = 0.74f),
        contentColor = Color.White,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MODIFIER_KEYS.forEach { key ->
                    KeyChip(
                        label = stringResource(key.labelRes),
                        active = modifiers and key.flag != 0,
                        onClick = { onToggleModifier(key.flag) },
                    )
                }
                KeyboardBarDivider()
                KeyChip(label = esc, onClick = { onKey(KEY_ESCAPE, esc) })
                KeyChip(label = tab, onClick = { onKey(KEY_TAB, tab) })
                KeyIconButton(
                    icon = Icons.AutoMirrored.Outlined.KeyboardReturn,
                    label = enter,
                    onClick = { onKey(KEY_RETURN, enter) },
                )
                KeyIconButton(
                    icon = Icons.AutoMirrored.Outlined.Backspace,
                    label = backspace,
                    onClick = { onKey(KEY_BACKSPACE, backspace) },
                )
                KeyboardBarDivider()
                KeyIconButton(
                    icon = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                    label = arrowLeft,
                    onClick = { onKey(KEY_LEFT, arrowLeft) },
                )
                KeyIconButton(
                    icon = Icons.Filled.KeyboardArrowUp,
                    label = arrowUp,
                    onClick = { onKey(KEY_UP, arrowUp) },
                )
                KeyIconButton(
                    icon = Icons.Filled.KeyboardArrowDown,
                    label = arrowDown,
                    onClick = { onKey(KEY_DOWN, arrowDown) },
                )
                KeyIconButton(
                    icon = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    label = arrowRight,
                    onClick = { onKey(KEY_RIGHT, arrowRight) },
                )
            }
            KeyboardBarDivider()
            KeyIconButton(
                icon = Icons.Outlined.KeyboardHide,
                label = stringResource(R.string.session_keyboard_hide),
                onClick = onHideKeyboard,
            )
        }
    }
}

@Composable
private fun KeyboardBarDivider() {
    Box(
        modifier = Modifier
            .width(1.dp)
            .height(26.dp)
            .background(Color.White.copy(alpha = 0.14f)),
    )
}

@Composable
private fun KeyChip(
    label: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(10.dp),
        color = if (active) Color.White.copy(alpha = 0.92f) else Color.White.copy(alpha = 0.09f),
        contentColor = if (active) Color.Black else Color.White,
    ) {
        Box(
            modifier = Modifier
                .widthIn(min = 42.dp)
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun KeyIconButton(
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
private fun ChromeRestoreButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = Color.Black.copy(alpha = 0.5f),
        contentColor = Color.White.copy(alpha = 0.9f),
        modifier = modifier,
    ) {
        Box(
            modifier = Modifier.padding(10.dp),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Visibility,
                contentDescription = stringResource(R.string.session_show_controls),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun DownloadDialog(
    onDismiss: () -> Unit,
    onDownload: (String) -> Unit,
) {
    var path by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.session_download)) },
        text = {
            OutlinedTextField(
                value = path,
                onValueChange = { path = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.session_download_hint)) },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onDownload(path.trim()) },
                enabled = path.isNotBlank(),
            ) {
                Text(stringResource(R.string.session_download_start))
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

private const val MAX_ZOOM = 6f
private const val ZOOM_ACTIVE_EPSILON = 1.01f
private const val PINCH_ZOOM_EPSILON = 0.08f
private const val TAP_TIMEOUT_MS = 500L
private const val IME_OPEN_GRACE_MS = 1200L
private const val RESUME_RECONNECT_MS = 5_000L
private const val VIEWPORT_SETTLE_MS = 120L
private const val DOUBLE_TAP_CLICK_MARGIN_MS = 32L

// Wheel scrolling: one RFB button press/release pair per step of finger travel.
private const val WHEEL_STEP_PX = 40f
private const val MAX_WHEEL_STEPS_PER_EVENT = 4
private const val WHEEL_UP = 1 shl 3
private const val WHEEL_DOWN = 1 shl 4
private const val WHEEL_LEFT = 1 shl 5
private const val WHEEL_RIGHT = 1 shl 6

// X11 keysyms for the keys the accessory bar can send.
private const val KEY_SHIFT = 0xFFE1
private const val KEY_CONTROL = 0xFFE3
private const val KEY_ALT = 0xFFE9
private const val KEY_SUPER = 0xFFEB
private const val KEY_ESCAPE = 0xFF1B
private const val KEY_TAB = 0xFF09
private const val KEY_RETURN = 0xFF0D
private const val KEY_BACKSPACE = 0xFF08
private const val KEY_LEFT = 0xFF51
private const val KEY_UP = 0xFF52
private const val KEY_RIGHT = 0xFF53
private const val KEY_DOWN = 0xFF54

private const val MODIFIER_CONTROL = 1
private const val MODIFIER_ALT = 1 shl 1
private const val MODIFIER_SHIFT = 1 shl 2
private const val MODIFIER_META = 1 shl 3

private const val KEYBOARD_SENTINEL_CHAR = '\u200B'
private const val KEYBOARD_SENTINEL = "\u200B"

private data class PendingUpload(val handle: Int, val uris: List<Uri>)

private data class ModifierKey(val flag: Int, val keysym: Int, val labelRes: Int)

private val MODIFIER_KEYS = listOf(
    ModifierKey(MODIFIER_CONTROL, KEY_CONTROL, R.string.session_key_ctrl),
    ModifierKey(MODIFIER_ALT, KEY_ALT, R.string.session_key_alt),
    ModifierKey(MODIFIER_SHIFT, KEY_SHIFT, R.string.session_key_shift),
    ModifierKey(MODIFIER_META, KEY_SUPER, R.string.session_key_meta),
)

private data class PendingTap(
    val x: Int,
    val y: Int,
    val position: Offset,
    val time: Long,
)

private data class PressIndicator(val color: Color, val position: Offset)

private enum class SwipeDirection { Up, Down, Left, Right }

/// Screens colours the held button the same way on every platform: blue for the
/// left button, red for the right one and green for the middle.
private fun pressIndicatorColor(button: Int): Color = when (button) {
    1 -> Color(0.29f, 0.56f, 1f)
    1 shl 2 -> Color(1f, 0.35f, 0.32f)
    else -> Color(0.20f, 0.78f, 0.35f)
}

private class DeferredTapController {
    var pending: PendingTap? = null
    var job: Job? = null
}

/** Remembers the last remote pointer position so wheel events land where the user left it. */
private class PointerMemory {
    private var x = -1
    private var y = -1

    fun remember(remoteX: Int, remoteY: Int) {
        x = remoteX
        y = remoteY
    }

    fun resolve(remoteWidth: Int, remoteHeight: Int): Pair<Int, Int> {
        val maxX = (remoteWidth - 1).coerceAtLeast(0)
        val maxY = (remoteHeight - 1).coerceAtLeast(0)
        return if (x < 0 || y < 0) {
            maxX / 2 to maxY / 2
        } else {
            x.coerceIn(0, maxX) to y.coerceIn(0, maxY)
        }
    }
}

private enum class GestureMode { Pending, Drag, Move, TwoFinger, Scroll, Transform }

/**
 * Keeps a bar in the pointer hit path so taps on its padding cannot fall through to the
 * canvas underneath, without consuming anything from its child buttons or scroller.
 */
private fun Modifier.touchBarrier(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent()
        }
    }
}

/**
 * Keeps the pan inside the range where the scaled band still covers the local
 * screen on that axis; content smaller than the screen stays centred.
 */
private fun clampPan(value: Offset, zoom: Float, band: IntSize, screen: IntSize): Offset {
    val safeZoom = zoom.coerceAtLeast(0.01f)
    // When the band covers the screen, keep its edges outside; when it is
    // smaller, let it move inside so a pinch stays anchored between the fingers
    // instead of snapping back to the centre.
    val maxX = abs(band.width * safeZoom - screen.width) / (2f * safeZoom)
    val maxY = abs(band.height * safeZoom - screen.height) / (2f * safeZoom)
    return Offset(
        x = value.x.coerceIn(-maxX, maxX),
        y = value.y.coerceIn(-maxY, maxY),
    )
}

/**
 * Maps a screen-space touch to the framebuffer. The band is drawn at the zoom-1
 * fit rect and scaled about its centre with a pan offset, so the inverse
 * transform lands in band coordinates, which map linearly to server pixels.
 */
private fun remotePoint(
    position: Offset,
    screen: IntSize,
    band: IntSize,
    remoteWidth: Int,
    remoteHeight: Int,
    zoom: Float,
    pan: Offset,
): Pair<Int, Int> {
    if (band.width == 0 || band.height == 0) return 0 to 0
    val safeZoom = zoom.coerceAtLeast(0.01f)
    val bandX = band.width / 2f + (position.x - screen.width / 2f) / safeZoom - pan.x
    val bandY = band.height / 2f + (position.y - screen.height / 2f) / safeZoom - pan.y
    val x = (bandX / band.width * remoteWidth).roundToInt().coerceIn(0, remoteWidth - 1)
    val y = (bandY / band.height * remoteHeight).roundToInt().coerceIn(0, remoteHeight - 1)
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
