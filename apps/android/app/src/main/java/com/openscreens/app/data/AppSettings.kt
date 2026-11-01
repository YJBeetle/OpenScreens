package com.openscreens.app.data

enum class ThemeMode { System, Light, Dark }

enum class QualityPreset { Low, Balanced, High }

enum class UpdateChannel { Release, PreRelease, Snapshot }

data class AppSettings(
    val themeMode: ThemeMode = ThemeMode.System,
    val updateChannel: UpdateChannel = UpdateChannel.Release,
    val librarySort: LibrarySortOrder = LibrarySortOrder.Az,
    /** Browse for computers advertising VNC over Bonjour on the local network. */
    val discoverNearby: Boolean = true,
)
