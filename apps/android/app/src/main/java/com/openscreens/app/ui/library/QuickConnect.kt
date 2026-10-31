package com.openscreens.app.ui.library

import com.openscreens.app.data.Connection
import java.net.URI

internal data class QuickConnectTarget(val host: String, val port: Int, val username: String?)

internal fun parseQuickConnectUrl(raw: String): QuickConnectTarget? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val withScheme = if (trimmed.contains("://")) trimmed else "vnc://$trimmed"
    val uri = runCatching { URI(withScheme) }.getOrNull() ?: return null
    if (!uri.scheme.equals("vnc", ignoreCase = true)) return null
    val host = uri.host?.removeSurrounding("[", "]")?.takeIf { it.isNotBlank() } ?: return null
    val port = if (uri.port == -1) Connection.DEFAULT_VNC_PORT else uri.port
    if (port !in 1..65535) return null
    val username = uri.userInfo?.substringBefore(':')?.takeIf { it.isNotBlank() }
    return QuickConnectTarget(host, port, username)
}
