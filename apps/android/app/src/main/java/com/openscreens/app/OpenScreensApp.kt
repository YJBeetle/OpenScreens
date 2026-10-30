package com.openscreens.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openscreens.app.data.ThemeMode
import com.openscreens.app.ui.editor.ConnectionEditorScreen
import com.openscreens.app.ui.library.LibraryScreen
import com.openscreens.app.ui.session.SessionScreen
import com.openscreens.app.ui.settings.SettingsScreen
import com.openscreens.app.ui.theme.OpenScreensTheme

@Composable
fun OpenScreensApp(viewModel: MainViewModel = viewModel()) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val route by viewModel.route.collectAsStateWithLifecycle()
    val connections by viewModel.connections.collectAsStateWithLifecycle()

    val darkTheme = when (settings.themeMode) {
        ThemeMode.System -> isSystemInDarkTheme()
        ThemeMode.Light -> false
        ThemeMode.Dark -> true
    }

    OpenScreensTheme(darkTheme = darkTheme) {
        Surface(modifier = Modifier.fillMaxSize()) {
            BackHandler(enabled = route != Route.Library) {
                viewModel.back()
            }

            when (val current = route) {
                Route.Library -> LibraryScreen(
                    connections = connections,
                    onOpenConnection = { viewModel.navigate(Route.Session(it.id)) },
                    onAddConnection = { viewModel.navigate(Route.Editor(connectionId = null)) },
                    onEditConnection = { viewModel.navigate(Route.Editor(it.id)) },
                    onOpenSettings = { viewModel.navigate(Route.Settings) },
                )

                Route.Settings -> SettingsScreen(
                    settings = settings,
                    onThemeModeChange = viewModel::setThemeMode,
                    onQualityChange = viewModel::setQuality,
                    onBack = viewModel::back,
                )

                is Route.Editor -> ConnectionEditorScreen(
                    connection = current.connectionId?.let(viewModel::connection),
                    onSave = {
                        viewModel.saveConnection(it)
                        viewModel.back()
                    },
                    onCancel = viewModel::back,
                )

                is Route.Session -> {
                    val connection = viewModel.connection(current.connectionId)
                    if (connection == null) {
                        LaunchedEffect(Unit) { viewModel.back() }
                    } else {
                        SessionScreen(
                            connection = connection,
                            quality = settings.quality,
                            onQualityChange = viewModel::setQuality,
                            onConnected = { viewModel.markConnected(connection.id) },
                            onExit = viewModel::back,
                        )
                    }
                }
            }
        }
    }
}
