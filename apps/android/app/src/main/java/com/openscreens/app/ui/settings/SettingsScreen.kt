package com.openscreens.app.ui.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openscreens.app.BuildConfig
import com.openscreens.app.R
import com.openscreens.app.data.AppSettings
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.ThemeMode
import com.openscreens.app.data.UpdateChannel
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.theme.ThemedSystemBarIcons
import com.openscreens.app.update.ApkUpdater
import com.openscreens.app.update.UpdateCheck
import com.openscreens.app.update.UpdateChecker
import com.openscreens.app.update.UpdateInfo
import com.openscreens.app.update.UpdateStateStore
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    sshKeyCount: Int,
    onThemeModeChange: (ThemeMode) -> Unit,
    onQualityChange: (QualityPreset) -> Unit,
    updateChannel: UpdateChannel,
    onUpdateChannelChange: (UpdateChannel) -> Unit,
    onManageSshKeys: () -> Unit,
    onBack: () -> Unit,
) {
    ThemedSystemBarIcons()

    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val updater = remember { ApkUpdater(context) }
    val updateStore = remember { UpdateStateStore(context) }
    var updateState by remember { mutableStateOf<UpdateUiState>(UpdateUiState.Idle) }

    fun checkForUpdates() {
        if (updateState is UpdateUiState.Checking) return
        updateState = UpdateUiState.Checking
        scope.launch {
            updateState = UpdateChecker.check(
                BuildConfig.VERSION_NAME,
                updateChannel,
                updateStore.installedSnapshot,
            ).fold(
                onSuccess = { result ->
                    when (result) {
                        is UpdateCheck.Available -> UpdateUiState.Available(result.info)
                        UpdateCheck.UpToDate -> UpdateUiState.UpToDate
                        UpdateCheck.NoReleases -> UpdateUiState.NoReleases
                    }
                },
                onFailure = { UpdateUiState.Failed(it.message ?: it.javaClass.simpleName) },
            )
        }
    }

    fun downloadAndInstall(info: UpdateInfo) {
        val url = info.downloadUrl ?: return
        updateState = UpdateUiState.Available(info, downloading = true)
        scope.launch {
            runCatching {
                val file = updater.download(url)
                updater.install(file)
            }.onSuccess {
                if (info.tag.equals("snapshot", ignoreCase = true)) {
                    updateStore.installedSnapshot = info.label
                }
                updateState = UpdateUiState.Available(info, installerOpened = true)
            }.onFailure {
                updateState = UpdateUiState.Failed(it.message ?: it.javaClass.simpleName)
            }
        }
    }

    fun openReleasePage(info: UpdateInfo) {
        val uri = Uri.parse(info.pageUrl)
        if (uri.scheme == "https") {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.settings_back),
                        )
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            SectionHeader(stringResource(R.string.settings_appearance))
            SettingsCard {
                ThemeMode.entries.forEachIndexed { index, mode ->
                    SelectionRow(
                        title = themeLabel(mode),
                        selected = settings.themeMode == mode,
                        onClick = { onThemeModeChange(mode) },
                    )
                    if (index != ThemeMode.entries.lastIndex) {
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }

            Spacer(Modifier.height(4.dp))
            SectionHeader(stringResource(R.string.settings_streaming))
            SettingsCard {
                QualityPreset.entries.forEachIndexed { index, preset ->
                    SelectionRow(
                        title = preset.label(),
                        subtitle = qualitySummary(preset),
                        selected = settings.quality == preset,
                        onClick = { onQualityChange(preset) },
                    )
                    if (index != QualityPreset.entries.lastIndex) {
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }

            Spacer(Modifier.height(4.dp))
            SectionHeader(stringResource(R.string.settings_security))
            SettingsCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onManageSshKeys)
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.settings_ssh_keys),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            text = stringResource(R.string.settings_ssh_keys_count, sshKeyCount),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Text(
                        text = stringResource(R.string.settings_manage),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }


            Spacer(Modifier.height(4.dp))
            SectionHeader(stringResource(R.string.settings_updates))
            SettingsCard {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    UpdateChannel.entries.forEachIndexed { index, channel ->
                        SelectionRow(
                            title = stringResource(
                                when (channel) {
                                    UpdateChannel.Release -> R.string.settings_channel_release
                                    UpdateChannel.PreRelease -> R.string.settings_channel_prerelease
                                    UpdateChannel.Snapshot -> R.string.settings_channel_snapshot
                                },
                            ),
                            selected = updateChannel == channel,
                            onClick = {
                                if (updateChannel != channel) {
                                    updateState = UpdateUiState.Idle
                                    onUpdateChannelChange(channel)
                                }
                            },
                        )
                        if (index != UpdateChannel.entries.lastIndex) {
                            HorizontalDivider(Modifier.padding(start = 16.dp))
                        }
                    }

                    val available = updateState as? UpdateUiState.Available
                    if (available == null) {
                        Text(
                            text = updateStatusText(updateState),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    } else {
                        Text(
                            text = stringResource(
                                R.string.settings_update_available,
                                if (available.info.tag.equals("snapshot", ignoreCase = true)) {
                                    available.info.label
                                } else {
                                    available.info.version
                                },
                            ),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        if (available.info.notes.isNotEmpty()) {
                            Text(
                                text = available.info.notes,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 6,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (available.info.downloadUrl == null) {
                            Text(
                                text = stringResource(R.string.settings_update_no_asset),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                        if (available.downloading || available.installerOpened) {
                            Text(
                                text = stringResource(
                                    if (available.downloading) {
                                        R.string.settings_downloading
                                    } else {
                                        R.string.settings_installer_opened
                                    },
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val checking = updateState is UpdateUiState.Checking
                        val downloading = available?.downloading == true
                        Button(
                            onClick = { checkForUpdates() },
                            enabled = !checking && !downloading,
                        ) {
                            if (checking || downloading) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    stringResource(
                                        if (checking) R.string.settings_checking_updates
                                        else R.string.settings_downloading,
                                    ),
                                )
                            } else {
                                Text(stringResource(R.string.settings_check_updates))
                            }
                        }
                        if (available?.info?.downloadUrl != null &&
                            !available.downloading && !available.installerOpened
                        ) {
                            Button(onClick = { downloadAndInstall(available.info) }) {
                                Text(stringResource(R.string.settings_download_install))
                            }
                        }
                        if (available != null) {
                            TextButton(onClick = { openReleasePage(available.info) }) {
                                Text(stringResource(R.string.settings_view_release))
                            }
                        }
                    }

                    Text(
                        text = stringResource(R.string.settings_update_note),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
            SectionHeader(stringResource(R.string.settings_about))
            SettingsCard {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.primaryContainer),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Monitor,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = stringResource(R.string.app_name),
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Text(
                                text = stringResource(
                                    R.string.settings_version,
                                    BuildConfig.VERSION_NAME,
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Text(
                        text = stringResource(R.string.settings_app_description),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(
                        text = stringResource(R.string.settings_license),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}


private sealed interface UpdateUiState {
    data object Idle : UpdateUiState
    data object Checking : UpdateUiState
    data object UpToDate : UpdateUiState
    data object NoReleases : UpdateUiState
    data class Available(
        val info: UpdateInfo,
        val downloading: Boolean = false,
        val installerOpened: Boolean = false,
    ) : UpdateUiState
    data class Failed(val message: String) : UpdateUiState
}

@Composable
private fun updateStatusText(state: UpdateUiState): String = when (state) {
    UpdateUiState.Idle -> stringResource(R.string.settings_updates_footer)
    UpdateUiState.Checking -> stringResource(R.string.settings_checking_updates)
    UpdateUiState.UpToDate -> stringResource(R.string.settings_up_to_date)
    UpdateUiState.NoReleases -> stringResource(R.string.settings_no_releases)
    is UpdateUiState.Available -> stringResource(R.string.settings_updates_footer)
    is UpdateUiState.Failed ->
        stringResource(R.string.settings_update_failed, state.message)
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 4.dp),
    )
}

@Composable
private fun SettingsCard(content: @Composable () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            content()
        }
    }
}

@Composable
private fun SelectionRow(
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
    subtitle: String? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .selectable(
                selected = selected,
                onClick = onClick,
                role = Role.RadioButton,
            )
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        RadioButton(selected = selected, onClick = null)
    }
}

@Composable
private fun themeLabel(mode: ThemeMode): String = stringResource(
    when (mode) {
        ThemeMode.System -> R.string.theme_system
        ThemeMode.Light -> R.string.theme_light
        ThemeMode.Dark -> R.string.theme_dark
    },
)

@Composable
private fun qualitySummary(preset: QualityPreset): String = stringResource(
    when (preset) {
        QualityPreset.Low -> R.string.quality_low_summary
        QualityPreset.Balanced -> R.string.quality_balanced_summary
        QualityPreset.High -> R.string.quality_high_summary
    },
)
