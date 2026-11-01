package com.openscreens.app.data

import android.content.Context

/** Application preferences stored outside the encrypted connection library. */
class SettingsStore(context: Context) {
    private val preferences =
        context.applicationContext.getSharedPreferences("openscreens.settings", Context.MODE_PRIVATE)

    fun load(): AppSettings = AppSettings(
        themeMode = enumValueOrDefault(preferences.getString("themeMode", null), ThemeMode.System),
        updateChannel = enumValueOrDefault(
            preferences.getString("updateChannel", null),
            UpdateChannel.Release,
        ),
        librarySort = enumValueOrDefault(
            preferences.getString("librarySort", null),
            LibrarySortOrder.Az,
        ),
        discoverNearby = preferences.getBoolean("discoverNearby", true),
    )

    fun save(settings: AppSettings) {
        preferences.edit()
            .putString("themeMode", settings.themeMode.name)
            .putString("updateChannel", settings.updateChannel.name)
            .putString("librarySort", settings.librarySort.name)
            .putBoolean("discoverNearby", settings.discoverNearby)
            .apply()
    }

    private inline fun <reified T : Enum<T>> enumValueOrDefault(value: String?, default: T): T =
        runCatching { enumValueOf<T>(value ?: default.name) }.getOrDefault(default)
}
