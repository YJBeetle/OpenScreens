package com.openscreens.app.ui.session

import android.os.SystemClock
import androidx.activity.compose.BackHandler
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
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.FullscreenExit
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.KeyboardHide
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.PowerSettingsNew
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
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
import com.openscreens.app.session.SessionEvent
import com.openscreens.app.session.SessionProvider
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.theme.SystemBarIconAppearance
import com.openscreens.app.ui.theme.findActivity
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs
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
        SessionProvider.create(connection, quality, sshKey)
    }

    var status by remember { mutableStateOf(SessionStatus.Connecting) }
    var remoteWidth by remember { mutableIntStateOf(1920) }
    var remoteHeight by remember { mutableIntStateOf(1200) }
    var frame by remember { mutableStateOf<SessionEvent.Frame?>(null) }
    var lastAction by remember { mutableStateOf<String?>(null) }
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var showClipboardDialog by rememberSaveable { mutableStateOf(false) }
    var qualityMenuExpanded by remember { mutableStateOf(false) }
    var isFullscreen by rememberSaveable { mutableStateOf(true) }
    var isExiting by remember { mutableStateOf(false) }
    var chromeVisible by rememberSaveable { mutableStateOf(true) }
    var keyboardActive by remember { mutableStateOf(false) }
    var modifiers by remember { mutableIntStateOf(0) }
    var backgroundedAt by remember { mutableLongStateOf(0L) }

    val focusRequester = remember { FocusRequester() }
    val pointerMemory = remember(session) { PointerMemory() }
    val taps = remember(session) { DeferredTapController() }

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
        val aspect = (remoteWidth.toFloat() / remoteHeight.toFloat()).coerceAtLeast(0.1f)
        val canvasWidth = min(maxWidth.value, maxHeight.value * aspect).dp

        // Letterboxed area around the framebuffer: tapping it toggles the session chrome
        // without stealing taps from the canvas, which sits above this layer.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures { chromeVisible = !chromeVisible }
                },
        )

        HiddenKeyboardField(
            focusRequester = focusRequester,
            onChar = { char -> sendKeysym(if (char == '\n') KEY_RETURN else x11Keysym(char)) },
            onBackspace = { sendKeysym(KEY_BACKSPACE) },
            onFocusChange = { focused -> if (!focused) keyboardActive = false },
            modifier = Modifier.align(Alignment.TopStart),
        )

        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .width(canvasWidth)
                .aspectRatio(aspect)
                .clip(RoundedCornerShape(16.dp))
                .background(FramebufferBackground)
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                .pointerInput(session, remoteWidth, remoteHeight) {
                    val touchSlop = viewConfiguration.touchSlop
                    val doubleTapTimeout = viewConfiguration.doubleTapTimeoutMillis.toLong()
                    val doubleTapSlop = touchSlop * 2.5f
                    val wheelStep = WHEEL_STEP_PX

                    fun sendPointerClick(x: Int, y: Int) {
                        session.sendPointer(x, y, 0)
                        session.sendPointer(x, y, 1)
                        session.sendPointer(x, y, 0)
                        pointerMemory.remember(x, y)
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

                    fun toggleZoomAt(position: Offset) {
                        val targetZoom = if (zoom > ZOOM_ACTIVE_EPSILON) 1f else DOUBLE_TAP_ZOOM
                        val center = Offset(size.width / 2f, size.height / 2f)
                        val imagePoint = (position - pan - center) / zoom + center
                        val targetPan =
                            position - center - (imagePoint - center) * targetZoom
                        zoom = targetZoom
                        pan = clampPan(targetPan, targetZoom, size)
                    }

                    fun sendWheel(mask: Int, labelRes: Int) {
                        val (x, y) = pointerMemory.resolve(remoteWidth, remoteHeight)
                        session.sendPointer(x, y, mask)
                        session.sendPointer(x, y, 0)
                        lastAction = context.getString(
                            R.string.session_action_prefix,
                            context.getString(labelRes),
                        )
                    }

                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val previousTap = taps.pending
                        val isDoubleTap = previousTap != null &&
                            down.uptimeMillis - previousTap.time <= doubleTapTimeout &&
                            (down.position - previousTap.position).getDistance() <= doubleTapSlop
                        if (previousTap != null) {
                            if (isDoubleTap) cancelPendingTap() else flushPendingTap()
                        }

                        var mode = GestureMode.Pending
                        var start = remotePoint(down.position, size, remoteWidth, remoteHeight, zoom, pan)
                        var last = start
                        var lastZoom = zoom
                        var lastPan = pan
                        var longPressSent = false
                        val downTime = SystemClock.uptimeMillis()

                        // Decision state for a two-finger gesture at 1x: it scrolls unless
                        // the finger span changes enough to be recognised as a pinch.
                        var multiTouchStartZoom = zoom
                        var multiTouchStartPan = pan
                        var multiTouchZoom = 1f
                        var multiTouchPan = Offset.Zero
                        var scrollAccum = Offset.Zero

                        while (true) {
                            val event = withTimeoutOrNull(50L) { awaitPointerEvent() }
                            if (event == null) {
                                if (mode == GestureMode.Pending && !longPressSent &&
                                    SystemClock.uptimeMillis() - downTime >= LONG_PRESS_MS
                                ) {
                                    longPressSent = true
                                    session.sendPointer(start.first, start.second, 2)
                                    session.sendPointer(start.first, start.second, 0)
                                    pointerMemory.remember(start.first, start.second)
                                    recordPointer(start.first, start.second)
                                }
                                continue
                            }

                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (mode == GestureMode.Transform && pressed.size < 2) break
                            if (mode == GestureMode.TwoFinger && pressed.size < 2) break
                            if (mode == GestureMode.Scroll && pressed.size < 2) break

                            if (pressed.size >= 2) {
                                if (mode == GestureMode.Pending || mode == GestureMode.Drag) {
                                    if (mode == GestureMode.Drag) {
                                        session.sendPointer(last.first, last.second, 0)
                                        pointerMemory.remember(last.first, last.second)
                                    }
                                    mode = if (zoom > ZOOM_ACTIVE_EPSILON) {
                                        GestureMode.Transform
                                    } else {
                                        GestureMode.TwoFinger
                                    }
                                    lastZoom = zoom
                                    lastPan = pan
                                    multiTouchStartZoom = zoom
                                    multiTouchStartPan = pan
                                    multiTouchZoom = 1f
                                    multiTouchPan = Offset.Zero
                                    scrollAccum = Offset.Zero
                                    // The pointer count changed on this event, so its pan and
                                    // zoom deltas are not meaningful. Start clean next event.
                                    event.changes.forEach { it.consume() }
                                    continue
                                }

                                when (mode) {
                                    GestureMode.TwoFinger -> {
                                        val zoomChange = event.calculateZoom()
                                        val panChange = event.calculatePan()
                                        multiTouchZoom *= zoomChange
                                        multiTouchPan += panChange
                                        if (abs(multiTouchZoom - 1f) > PINCH_ZOOM_EPSILON) {
                                            // A pinch always wins over scrolling.
                                            val newZoom = (multiTouchStartZoom * multiTouchZoom)
                                                .coerceIn(1f, MAX_ZOOM)
                                            val centroid =
                                                event.calculateCentroid(useCurrent = true)
                                            val center =
                                                Offset(size.width / 2f, size.height / 2f)
                                            val anchored = if (centroid == Offset.Unspecified) {
                                                multiTouchStartPan
                                            } else {
                                                centroid - (centroid - center - multiTouchStartPan) *
                                                    (newZoom / multiTouchStartZoom)
                                            }
                                            val newPan = clampPan(
                                                anchored + multiTouchPan,
                                                newZoom,
                                                size,
                                            )
                                            zoom = newZoom
                                            pan = newPan
                                            lastZoom = newZoom
                                            lastPan = newPan
                                            mode = GestureMode.Transform
                                        } else if (multiTouchPan.getDistance() > touchSlop * 2f) {
                                            mode = GestureMode.Scroll
                                            scrollAccum = multiTouchPan
                                        }
                                        event.changes.forEach { it.consume() }
                                        continue
                                    }

                                    GestureMode.Scroll -> {
                                        val zoomChange = event.calculateZoom()
                                        val panChange = event.calculatePan()
                                        multiTouchZoom *= zoomChange
                                        multiTouchPan += panChange
                                        if (abs(multiTouchZoom - 1f) > PINCH_ZOOM_EPSILON) {
                                            val newZoom = (multiTouchStartZoom * multiTouchZoom)
                                                .coerceIn(1f, MAX_ZOOM)
                                            val centroid =
                                                event.calculateCentroid(useCurrent = true)
                                            val center =
                                                Offset(size.width / 2f, size.height / 2f)
                                            val anchored = if (centroid == Offset.Unspecified) {
                                                multiTouchStartPan
                                            } else {
                                                centroid - (centroid - center - multiTouchStartPan) *
                                                    (newZoom / multiTouchStartZoom)
                                            }
                                            val newPan = clampPan(
                                                anchored + multiTouchPan,
                                                newZoom,
                                                size,
                                            )
                                            zoom = newZoom
                                            pan = newPan
                                            lastZoom = newZoom
                                            lastPan = newPan
                                            mode = GestureMode.Transform
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
                                        val zoomChange = event.calculateZoom()
                                        val panChange = event.calculatePan()
                                        if (zoomChange != 1f || panChange != Offset.Zero) {
                                            val newZoom =
                                                (lastZoom * zoomChange).coerceIn(1f, MAX_ZOOM)
                                            val centroid =
                                                event.calculateCentroid(useCurrent = true)
                                            val center =
                                                Offset(size.width / 2f, size.height / 2f)
                                            val anchored = if (centroid == Offset.Unspecified) {
                                                lastPan
                                            } else {
                                                centroid - (centroid - center - lastPan) *
                                                    (newZoom / lastZoom)
                                            }
                                            val newPan =
                                                clampPan(anchored + panChange, newZoom, size)
                                            zoom = newZoom
                                            pan = newPan
                                            lastZoom = newZoom
                                            lastPan = newPan
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
                            if (mode == GestureMode.Pending && !longPressSent &&
                                (change.position - down.position).getDistance() > touchSlop
                            ) {
                                mode = GestureMode.Drag
                                session.sendPointer(start.first, start.second, 1)
                                pointerMemory.remember(start.first, start.second)
                                recordPointer(start.first, start.second)
                            }
                            if (mode == GestureMode.Drag) {
                                last = remotePoint(change.position, size, remoteWidth, remoteHeight, zoom, pan)
                                session.sendPointer(last.first, last.second, 1)
                                pointerMemory.remember(last.first, last.second)
                                change.consume()
                            }
                        }

                        when (mode) {
                            GestureMode.Drag -> {
                                session.sendPointer(last.first, last.second, 0)
                                pointerMemory.remember(last.first, last.second)
                            }
                            GestureMode.Pending -> if (!longPressSent) {
                                if (isDoubleTap) {
                                    toggleZoomAt(down.position)
                                } else {
                                    // Hold the click briefly so a double tap can zoom instead.
                                    scheduleTap(
                                        start.first,
                                        start.second,
                                        down.position,
                                        SystemClock.uptimeMillis(),
                                    )
                                }
                            }
                            else -> Unit
                        }
                    }
                },
        ) {
            val live = frame
            if (live != null) {
                Canvas(
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = zoom
                            scaleY = zoom
                            translationX = pan.x
                            translationY = pan.y
                            transformOrigin = TransformOrigin.Center
                        },
                ) {
                    drawImage(
                        image = live.bitmap.asImageBitmap(),
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(live.bitmap.width, live.bitmap.height),
                        dstOffset = IntOffset.Zero,
                        dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
                        filterQuality = if (zoom > 1.2f) FilterQuality.Medium else FilterQuality.Low,
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
                onKeyboard = { keyboardActive = true },
                onClipboard = { showClipboardDialog = true },
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
    quality: QualityPreset,
    qualityMenuExpanded: Boolean,
    onQualityMenuChange: (Boolean) -> Unit,
    onQualitySelected: (QualityPreset) -> Unit,
    isFullscreen: Boolean,
    onKeyboard: () -> Unit,
    onClipboard: () -> Unit,
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
private const val DOUBLE_TAP_ZOOM = 2f
private const val ZOOM_ACTIVE_EPSILON = 1.01f
private const val PINCH_ZOOM_EPSILON = 0.08f
private const val LONG_PRESS_MS = 500L
private const val IME_OPEN_GRACE_MS = 1200L
private const val RESUME_RECONNECT_MS = 5_000L
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

private enum class GestureMode { Pending, Drag, TwoFinger, Scroll, Transform }

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

private fun clampPan(value: Offset, zoom: Float, size: IntSize): Offset {
    val maxX = size.width * (zoom - 1f) / 2f
    val maxY = size.height * (zoom - 1f) / 2f
    return Offset(
        x = value.x.coerceIn(-maxX, maxX),
        y = value.y.coerceIn(-maxY, maxY),
    )
}

private fun remotePoint(
    offset: Offset,
    size: IntSize,
    remoteWidth: Int,
    remoteHeight: Int,
    zoom: Float,
    pan: Offset,
): Pair<Int, Int> {
    if (size.width == 0 || size.height == 0) return 0 to 0
    val center = Offset(size.width / 2f, size.height / 2f)
    val local = (offset - pan - center) / zoom + center
    val x = (local.x / size.width * remoteWidth).roundToInt().coerceIn(0, remoteWidth - 1)
    val y = (local.y / size.height * remoteHeight).roundToInt().coerceIn(0, remoteHeight - 1)
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
