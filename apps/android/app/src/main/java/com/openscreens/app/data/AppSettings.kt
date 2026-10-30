package com.openscreens.app.data

enum class ThemeMode { System, Light, Dark }

enum class QualityPreset { Low, Balanced, High }

data class AppSettings(
    val themeMode: ThemeMode = ThemeMode.System,
    val quality: QualityPreset = QualityPreset.Balanced,
)
