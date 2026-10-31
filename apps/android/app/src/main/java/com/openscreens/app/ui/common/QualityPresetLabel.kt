package com.openscreens.app.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.openscreens.app.R
import com.openscreens.app.data.QualityPreset

@Composable
fun QualityPreset.label(): String = stringResource(
    when (this) {
        QualityPreset.Low -> R.string.quality_low
        QualityPreset.Balanced -> R.string.quality_balanced
        QualityPreset.High -> R.string.quality_high
    },
)

@Composable
fun QualityPreset.summary(): String = stringResource(
    when (this) {
        QualityPreset.Low -> R.string.quality_low_summary
        QualityPreset.Balanced -> R.string.quality_balanced_summary
        QualityPreset.High -> R.string.quality_high_summary
    },
)
