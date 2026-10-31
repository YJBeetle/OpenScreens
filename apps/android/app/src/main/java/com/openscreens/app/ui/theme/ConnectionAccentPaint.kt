package com.openscreens.app.ui.theme

import androidx.annotation.StringRes
import androidx.compose.ui.graphics.Color
import com.openscreens.app.R
import com.openscreens.app.data.ConnectionAccent

data class AccentGradient(val start: Color, val end: Color)

/**
 * Fixed, saturated gradients so neighbouring cards stay distinguishable. They are
 * independent of the Material palette, whose containers collapse into near-identical
 * pale tints when dynamic color is on.
 */
private val AccentGradients = mapOf(
    ConnectionAccent.Teal to AccentGradient(Color(0xFF0F766E), Color(0xFF0D9488)),
    ConnectionAccent.Rose to AccentGradient(Color(0xFF9F1239), Color(0xFFE11D48)),
    ConnectionAccent.Indigo to AccentGradient(Color(0xFF3730A3), Color(0xFF4F46E5)),
    ConnectionAccent.Amber to AccentGradient(Color(0xFFB45309), Color(0xFFD97706)),
    ConnectionAccent.Slate to AccentGradient(Color(0xFF1E293B), Color(0xFF475569)),
    ConnectionAccent.Violet to AccentGradient(Color(0xFF5B21B6), Color(0xFF7C3AED)),
    ConnectionAccent.Emerald to AccentGradient(Color(0xFF047857), Color(0xFF10B981)),
    ConnectionAccent.Sky to AccentGradient(Color(0xFF0369A1), Color(0xFF0EA5E9)),
)

val ConnectionAccent.gradient: AccentGradient get() = AccentGradients.getValue(this)

@get:StringRes
val ConnectionAccent.labelRes: Int
    get() = when (this) {
        ConnectionAccent.Teal -> R.string.accent_teal
        ConnectionAccent.Rose -> R.string.accent_rose
        ConnectionAccent.Indigo -> R.string.accent_indigo
        ConnectionAccent.Amber -> R.string.accent_amber
        ConnectionAccent.Slate -> R.string.accent_slate
        ConnectionAccent.Violet -> R.string.accent_violet
        ConnectionAccent.Emerald -> R.string.accent_emerald
        ConnectionAccent.Sky -> R.string.accent_sky
    }

/**
 * Order used before accents were configurable. Keeping it for the automatic
 * choice means renaming an untouched connection does not recolour it.
 */
private val LegacyAccentOrder = listOf(
    ConnectionAccent.Teal,
    ConnectionAccent.Rose,
    ConnectionAccent.Indigo,
    ConnectionAccent.Amber,
    ConnectionAccent.Slate,
    ConnectionAccent.Violet,
)

fun autoAccent(name: String): ConnectionAccent =
    LegacyAccentOrder[Math.floorMod(name.hashCode(), LegacyAccentOrder.size)]
