package com.openscreens.app.update

import android.content.Context

/** Remembers which rolling snapshot was installed on this device. */
class UpdateStateStore(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences("openscreens.update", Context.MODE_PRIVATE)

    var installedSnapshot: String?
        get() = preferences.getString("installedSnapshot", null)
        set(value) {
            preferences.edit().putString("installedSnapshot", value).apply()
        }
}
