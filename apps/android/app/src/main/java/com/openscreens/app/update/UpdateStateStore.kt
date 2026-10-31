package com.openscreens.app.update

import android.content.Context

/**
 * Remembers which rolling snapshot is actually installed. The label is
 * committed only after the app package's update time passes the moment the
 * installer was launched, so cancelling the installer does not mark the build
 * as installed.
 */
class UpdateStateStore(context: Context) {
    private val appContext = context.applicationContext
    private val preferences =
        appContext.getSharedPreferences("openscreens.update", Context.MODE_PRIVATE)

    fun installedSnapshot(): String? {
        commitPendingIfInstalled()
        return preferences.getString(KEY_INSTALLED, null)
    }

    fun markInstallStarted(label: String) {
        preferences.edit()
            .putString(KEY_PENDING, label)
            .putLong(KEY_PENDING_AT, System.currentTimeMillis())
            .apply()
    }

    private fun commitPendingIfInstalled() {
        val pending = preferences.getString(KEY_PENDING, null) ?: return
        val since = preferences.getLong(KEY_PENDING_AT, 0L)
        if (since <= 0L) {
            preferences.edit().remove(KEY_PENDING).remove(KEY_PENDING_AT).apply()
            return
        }
        val updateTime = runCatching {
            appContext.packageManager.getPackageInfo(appContext.packageName, 0).lastUpdateTime
        }.getOrDefault(0L)
        if (updateTime >= since) {
            preferences.edit()
                .putString(KEY_INSTALLED, pending)
                .remove(KEY_PENDING)
                .remove(KEY_PENDING_AT)
                .apply()
        }
    }

    private companion object {
        const val KEY_INSTALLED = "installedSnapshotV2"
        const val KEY_PENDING = "pendingSnapshot"
        const val KEY_PENDING_AT = "pendingSnapshotAt"
    }
}
