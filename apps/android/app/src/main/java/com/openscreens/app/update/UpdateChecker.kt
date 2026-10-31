package com.openscreens.app.update

import com.openscreens.app.data.UpdateChannel
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class UpdateInfo(
    val version: String,
    val tag: String,
    val label: String,
    val notes: String,
    val pageUrl: String,
    val downloadUrl: String?,
)

sealed interface UpdateCheck {
    data class Available(val info: UpdateInfo) : UpdateCheck
    data object UpToDate : UpdateCheck
    data object NoReleases : UpdateCheck
}

/** A non-success response from the GitHub API; the UI localizes the status code. */
class UpdateHttpException(val statusCode: Int) : IOException("GitHub returned HTTP $statusCode")

/**
 * Reads the latest public GitHub release. The asset naming convention is
 * `<anything>-android.apk`; any `.apk` asset is accepted as a fallback.
 */
object UpdateChecker {
    private const val SNAPSHOT_TAG = "snapshot"

    const val RELEASES_URL =
        "https://api.github.com/repos/YJBeetle/OpenScreens/releases?per_page=20"

    suspend fun check(
        currentVersion: String,
        channel: UpdateChannel,
        installedSnapshot: String? = null,
    ): Result<UpdateCheck> = withContext(Dispatchers.IO) {
        runCatching {
            val body = fetch(RELEASES_URL)
                ?: return@runCatching UpdateCheck.NoReleases
            parse(body, currentVersion, channel, installedSnapshot)
        }
    }

    internal fun fetch(url: String): String? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 10_000
            readTimeout = 15_000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "OpenScreens-Android")
        }
        try {
            val code = connection.responseCode
            if (code == HttpURLConnection.HTTP_NOT_FOUND) return null
            if (code !in 200..299) {
                throw UpdateHttpException(code)
            }
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    internal fun parse(
        json: String,
        currentVersion: String,
        channel: UpdateChannel,
        installedSnapshot: String?,
    ): UpdateCheck {
        val releases = JSONArray(json)
        var selected: JSONObject? = null
        for (index in 0 until releases.length()) {
            val candidate = releases.optJSONObject(index) ?: continue
            if (candidate.optBoolean("draft")) continue
            val tag = candidate.optString("tag_name")
            val isSnapshot = tag.equals(SNAPSHOT_TAG, ignoreCase = true)
            val eligible = when (channel) {
                UpdateChannel.Snapshot -> isSnapshot
                UpdateChannel.PreRelease -> !isSnapshot
                UpdateChannel.Release -> !isSnapshot && !candidate.optBoolean("prerelease")
            }
            if (!eligible) continue
            selected = candidate
            break
        }
        val root = selected ?: return UpdateCheck.NoReleases
        val tag = root.optString("tag_name")
        val version = tag.removePrefix("v").trim()
        val label = root.optString("name").trim()
            .ifBlank { version.ifEmpty { root.optString("published_at") } }
        val pageUrl = root.optString("html_url")
        val notes = root.optString("body").trim()

        if (channel == UpdateChannel.Snapshot) {
            if (installedSnapshot != null && installedSnapshot == label) {
                return UpdateCheck.UpToDate
            }
        } else if (version.isEmpty() || !isNewer(version, currentVersion)) {
            return UpdateCheck.UpToDate
        }

        var apkUrl: String? = null
        val assets = root.optJSONArray("assets")
        if (assets != null) {
            for (index in 0 until assets.length()) {
                val asset = assets.optJSONObject(index) ?: continue
                val name = asset.optString("name").lowercase()
                val url = asset.optString("browser_download_url")
                if (!name.endsWith(".apk") || !url.startsWith("https://")) continue
                apkUrl = url
                if (name.contains("android")) break
            }
        }

        return UpdateCheck.Available(
            UpdateInfo(
                version = version.ifEmpty { tag },
                tag = tag,
                label = label.ifEmpty { version.ifEmpty { tag } },
                notes = notes,
                pageUrl = pageUrl,
                downloadUrl = apkUrl,
            ),
        )
    }

    internal fun isNewer(candidate: String, current: String): Boolean =
        compareVersions(candidate, current) > 0

    internal fun compareVersions(candidate: String, current: String): Int {
        fun core(value: String) = value.trim().removePrefix("v")
            .substringBefore('-')
            .substringBefore('+')

        val left = core(candidate).split('.')
        val right = core(current).split('.')
        for (index in 0 until maxOf(left.size, right.size)) {
            val a = left.getOrNull(index)?.toIntOrNull() ?: 0
            val b = right.getOrNull(index)?.toIntOrNull() ?: 0
            if (a != b) return a.compareTo(b)
        }

        val candidateIsPrerelease = candidate.contains('-')
        val currentIsPrerelease = current.contains('-')
        return when {
            candidateIsPrerelease && !currentIsPrerelease -> -1
            !candidateIsPrerelease && currentIsPrerelease -> 1
            else -> 0
        }
    }
}
