package com.openscreens.app.ui.settings

import androidx.compose.foundation.background
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
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.openscreens.app.BuildConfig
import com.openscreens.app.R
import com.openscreens.app.data.AppSettings
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.ThemeMode
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.theme.ThemedSystemBarIcons

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    settings: AppSettings,
    onThemeModeChange: (ThemeMode) -> Unit,
    onQualityChange: (QualityPreset) -> Unit,
    onBack: () -> Unit,
) {
    ThemedSystemBarIcons()

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
