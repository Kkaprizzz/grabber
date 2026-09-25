import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key lives outside the repo; android/key.properties (gitignored)
// points at it. Without it release builds fall back to the debug key.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

// yt-dlp + Python 3.12 + ffmpeg + QuickJS, run as child processes.
val youtubedlAndroid = "0.18.1"

android {
    namespace = "online.fxsecret.grabber"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "online.fxsecret.grabber"
        // Android 8+: the user's Galaxy S8 tops out at Android 9.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // youtubedl-android executes python/ffmpeg straight out of
    // nativeLibraryDir, so the .so files must be extracted on install.
    packaging {
        jniLibs.useLegacyPackaging = true
        // Every phone this is meant for is arm64; the other ABIs would add
        // ~100 MB of Python and ffmpeg nobody runs. (abiFilters alone doesn't
        // do it: the Flutter plugin adds its own ABIs to the filter.)
        jniLibs.excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    // Every build type signs with the release key when it's available, so any
    // build installs over any other without wiping history.
    buildTypes.configureEach {
        if (keystoreProperties.isNotEmpty()) signingConfig = signingConfigs.getByName("release")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:$youtubedlAndroid")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$youtubedlAndroid")
    implementation("androidx.core:core-ktx:1.17.0")
}

flutter {
    source = "../.."
}
