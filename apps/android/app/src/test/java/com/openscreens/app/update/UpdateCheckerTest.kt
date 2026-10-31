package com.openscreens.app.update

import com.openscreens.app.data.UpdateChannel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateCheckerTest {
    private fun release(
        tag: String,
        name: String = tag,
        prerelease: Boolean = false,
        draft: Boolean = false,
        assets: List<Pair<String, String>> = listOf(
            "OpenScreens-android.apk" to "https://example.test/app.apk",
        ),
    ): JSONObject = JSONObject().apply {
        put("tag_name", tag)
        put("name", name)
        put("prerelease", prerelease)
        put("draft", draft)
        put("body", "notes for $tag")
        put("html_url", "https://example.test/releases/$tag")
        put("published_at", "2026-10-31T10:00:00Z")
        put("assets", JSONArray().apply {
            assets.forEach { (assetName, url) ->
                put(JSONObject().apply {
                    put("name", assetName)
                    put("browser_download_url", url)
                })
            }
        })
    }

    private fun json(vararg releases: JSONObject): String = JSONArray(releases.toList()).toString()

    @Test
    fun compares_versions() {
        assertTrue(UpdateChecker.isNewer("0.2.0", "0.1.9"))
        assertTrue(!UpdateChecker.isNewer("1.0", "1.0.0"))
        assertTrue(!UpdateChecker.isNewer("1.0.0-beta.1", "1.0.0"))
        assertTrue(UpdateChecker.isNewer("1.0.0", "1.0.0-beta.1"))
        assertEquals(0, UpdateChecker.compareVersions("v1.2.3", "1.2.3"))
    }

    @Test
    fun stable_channel_skips_prereleases_and_snapshots() {
        val body = json(
            release("snapshot", prerelease = true),
            release("v0.3.0-beta.1", prerelease = true),
            release("v0.2.0"),
            release("v0.1.0"),
        )
        val result = UpdateChecker.parse(body, "0.1.0", UpdateChannel.Release, null)
        assertEquals(
            "0.2.0",
            (result as UpdateCheck.Available).info.version,
        )
    }

    @Test
    fun prerelease_channel_accepts_betas_but_not_snapshots() {
        val body = json(
            release("snapshot", prerelease = true),
            release("v0.3.0-beta.1", prerelease = true),
            release("v0.2.0"),
        )
        val result = UpdateChecker.parse(body, "0.2.0", UpdateChannel.PreRelease, null)
        assertEquals("0.3.0-beta.1", (result as UpdateCheck.Available).info.version)
    }

    @Test
    fun snapshot_channel_is_available_until_installed_label_matches() {
        val body = json(
            release("snapshot", name = "Development snapshot 2026-10-31", prerelease = true),
            release("v0.2.0"),
        )
        val available = UpdateChecker.parse(body, "0.1.0", UpdateChannel.Snapshot, null)
        assertEquals(
            "Development snapshot 2026-10-31",
            (available as UpdateCheck.Available).info.label,
        )
        assertEquals(
            "https://example.test/app.apk",
            available.info.downloadUrl,
        )
        assertEquals(
            UpdateCheck.UpToDate,
            UpdateChecker.parse(
                body,
                "0.1.0",
                UpdateChannel.Snapshot,
                "Development snapshot 2026-10-31",
            ),
        )
    }

    @Test
    fun up_to_date_and_missing_channels() {
        val body = json(release("v0.1.0"))
        assertEquals(
            UpdateCheck.UpToDate,
            UpdateChecker.parse(body, "0.1.0", UpdateChannel.Release, null),
        )
        assertEquals(
            UpdateCheck.NoReleases,
            UpdateChecker.parse(json(), "0.1.0", UpdateChannel.Release, null),
        )
    }

    @Test
    fun prefers_android_named_asset() {
        val body = json(
            release(
                "v0.2.0",
                assets = listOf(
                    "other.apk" to "https://example.test/other.apk",
                    "OpenScreens-android.apk" to "https://example.test/android.apk",
                ),
            ),
        )
        val result = UpdateChecker.parse(body, "0.1.0", UpdateChannel.Release, null)
        assertEquals(
            "https://example.test/android.apk",
            (result as UpdateCheck.Available).info.downloadUrl,
        )
    }
}
