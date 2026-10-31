// Keep build output outside the checkout locally at <workspace>/build/android.
// CI keeps Gradle's default in-workspace layout so artifact uploads stay simple.
if (providers.environmentVariable("GITHUB_ACTIONS").orNull == null) {
    val buildRoot = providers.environmentVariable("OPENSCREENS_BUILD_ROOT").orNull
        ?: rootDir.parentFile.parentFile.parentFile.resolve("build/android").path
    allprojects {
        layout.buildDirectory.set(File(buildRoot, project.name))
    }
}

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
