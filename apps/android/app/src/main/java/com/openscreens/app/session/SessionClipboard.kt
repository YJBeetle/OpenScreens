package com.openscreens.app.session

/** Text stays in memory for a single transport. The platform clipboard is read
 * only on explicit send or for foreground automatic sharing. */
internal class SessionClipboard(
    var shared: Boolean,
    private val read: () -> String?,
    private val write: (String) -> Unit,
) {
    private var latestRemote: String? = null

    fun reset() {
        latestRemote = null
    }

    fun receive(text: String, focused: Boolean, requested: Boolean = false) {
        latestRemote = text
        if (requested || (shared && focused)) write(text)
    }

    fun localText(): String? = read()?.takeIf { it.isNotEmpty() }

    // The engine suppresses echoes against the current wire clipboard state.
    fun reply(focused: Boolean): String? = if (shared && focused) localText() else null

    fun copyLatest(): Boolean {
        val text = latestRemote ?: return false
        write(text)
        return true
    }
}
