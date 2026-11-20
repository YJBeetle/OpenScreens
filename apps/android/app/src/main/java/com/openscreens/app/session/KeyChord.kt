package com.openscreens.app.session

/** Enqueue the modifier and key transitions on the session's ordered input path. */
internal inline fun sendChord(keysym: Int, modifiers: List<Int>, send: (Int, Boolean) -> Unit) {
    for (modifier in modifiers) send(modifier, true)
    send(keysym, true)
    send(keysym, false)
    for (modifier in modifiers.asReversed()) send(modifier, false)
}
