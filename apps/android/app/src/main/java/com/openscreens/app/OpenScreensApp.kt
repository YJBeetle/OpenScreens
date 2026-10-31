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
import com.openscreens.app.ui.sshkeys.SshKeysScreen
import com.openscreens.app.ui.theme.OpenScreensTheme

@Composable
fun OpenScreensApp(viewModel: MainViewModel = viewModel()) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val route by viewModel.route.collectAsStateWithLifecycle()
    val connections by viewModel.connections.collectAsStateWithLifecycle()
    val sshKeys by viewModel.sshKeys.collectAsStateWithLifecycle()

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
                    sshKeyCount = sshKeys.size,
                    onThemeModeChange = viewModel::setThemeMode,
                    updateChannel = settings.updateChannel,
                    onUpdateChannelChange = viewModel::setUpdateChannel,
                    onManageSshKeys = { viewModel.navigate(Route.SshKeys) },
                    onBack = viewModel::back,
                )

                Route.SshKeys -> SshKeysScreen(
                    keys = sshKeys,
                    onGenerate = viewModel::generateSshKey,
                    onImport = viewModel::importSshKey,
                    onDelete = viewModel::deleteSshKey,
                    onBack = viewModel::back,
                )

                is Route.Editor -> ConnectionEditorScreen(
                    connection = current.connectionId?.let(viewModel::connection),
                    sshKeys = sshKeys,
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
                            sshKey = viewModel.sshKey(connection.ssh?.keyId),
                            quality = connection.quality,
                            onQualityChange = { viewModel.setConnectionQuality(connection.id, it) },
                            onConnected = { viewModel.markConnected(connection.id) },
                            onExit = viewModel::back,
                        )
                    }
                }
            }
        }
    }
}
