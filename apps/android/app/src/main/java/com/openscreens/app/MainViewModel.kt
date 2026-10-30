package com.openscreens.app

import androidx.lifecycle.ViewModel
import com.openscreens.app.data.AppSettings
import com.openscreens.app.data.Connection
import com.openscreens.app.data.ConnectionStore
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.ThemeMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

class MainViewModel : ViewModel() {

    private val connectionStore = ConnectionStore()
    val connections = connectionStore.connections

    private val _settings = MutableStateFlow(AppSettings())
    val settings = _settings.asStateFlow()

    private val _route = MutableStateFlow<Route>(Route.Library)
    val route = _route.asStateFlow()

    fun connection(id: String): Connection? = connectionStore.find(id)

    fun saveConnection(connection: Connection) {
        connectionStore.save(connection)
    }

    fun markConnected(id: String) {
        connectionStore.markConnected(id)
    }

    fun setThemeMode(mode: ThemeMode) {
        _settings.update { it.copy(themeMode = mode) }
    }

    fun setQuality(quality: QualityPreset) {
        _settings.update { it.copy(quality = quality) }
    }

    fun navigate(route: Route) {
        _route.value = route
    }

    fun back() {
        if (_route.value != Route.Library) {
            _route.value = Route.Library
        }
    }
}

sealed interface Route {
    data object Library : Route
    data object Settings : Route
    data class Editor(val connectionId: String?) : Route
    data class Session(val connectionId: String) : Route
}
