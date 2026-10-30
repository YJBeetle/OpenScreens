package com.openscreens.app.ui.theme

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/** Keeps status/navigation bar icons legible for the current app theme. */
@Composable
fun ThemedSystemBarIcons() {
    val lightBackground = MaterialTheme.colorScheme.background.luminance() > 0.5f
    SystemBarIconAppearance(darkIcons = !lightBackground)
}

@Composable
fun SystemBarIconAppearance(darkIcons: Boolean) {
    val view = LocalView.current
    if (view.isInEditMode) return

    DisposableEffect(darkIcons) {
        val controller = view.context.findActivity()?.window?.let {
            WindowCompat.getInsetsController(it, view)
        }
        controller?.apply {
            isAppearanceLightStatusBars = darkIcons
            isAppearanceLightNavigationBars = darkIcons
        }
        onDispose { }
    }
}

fun Context.findActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
