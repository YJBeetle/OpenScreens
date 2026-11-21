import java.io.FileInputStream
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// Release signing is optional locally: CI and fresh checkouts fall back to debug signing.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("keystore.properties")
if (keystorePropertiesFile.isFile) {
    FileInputStream(keystorePropertiesFile).use(keystoreProperties::load)
}
val releaseKeystore = keystoreProperties.getProperty("storeFile")
    ?.let(rootProject::file)
    ?.takeIf { it.isFile }

// `git describe --tags` yields the tag alone when HEAD is tagged and
// "tag-<count>-g<hash>[-dirty]" afterwards, so release and snapshot builds are
// distinguishable without touching the numeric version used by the updater.
val buildVersion = runCatching {
    providers.exec {
        commandLine("git", "describe", "--tags", "--always", "--dirty")
    }.standardOutput.asText.get().trim()
}.getOrNull().orEmpty().ifBlank { "dev" }

android {
    namespace = "com.openscreens.app"
    compileSdk = 36

    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        applicationId = "org.scrctl.android"
        minSdk = 26
        targetSdk = 36
        versionCode = providers.gradleProperty("openscreens.versionCode")
            .map(String::toInt)
            .getOrElse(1)
        versionName = providers.gradleProperty("openscreens.versionName").getOrElse("0.1.0")
        buildConfigField("String", "BUILD_VERSION", "\"$buildVersion\"")

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
        jniLibs.useLegacyPackaging = true
    }
}

val nativeLibraries = listOf("arm64-v8a", "armeabi-v7a", "x86_64").map {
    layout.projectDirectory.file("src/main/jniLibs/$it/librfb_ffi.so").asFile
}
tasks.named("preBuild") {
    doFirst {
        check(nativeLibraries.all { it.isFile }) {
            "Build the Android core with ./scripts/build-android-core.sh before running Gradle."
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.android)
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
