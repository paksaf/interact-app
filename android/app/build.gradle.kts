plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM plugin only when operator has registered com.interactpak.interact_talk
// in the interact-lifestyle Firebase project and placed google-services.json
// (see docs/BACKGROUND_RING_AND_CAPTIONS_2026-07-24.md). Without it the APK
// still builds; background ring stays creds-gated / foreground poll works.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.interactpak.interact_talk"
    // Pinned to 36: transitive AndroidX (core 1.17, browser 1.9) + plugins
    // (flutter_webrtc, flutter_tts, record, speech_to_text, url_launcher…)
    // require compileSdk 36. compileSdk only allows newer APIs at compile time;
    // targetSdk/minSdk stay flutter defaults (runtime behaviour / device floor).
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications 17+ (uses java.time APIs).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.interactpak.interact_talk"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Gotcha #67 (2026-07-31): an arm64-only APK installs on 32-bit phones
        // (Redmi / Phone B) but splash→closes — no libflutter.so for armeabi-v7a.
        // Pin BOTH phone ABIs so `flutter build apk --release` always ships a
        // fat APK safe for OTA + Wi‑Fi sideload. Omit when SPLIT_PER_ABI=1
        // (or Flutter --split-per-abi) — abiFilters conflict with ABI splits.
        val splitPerAbi =
            System.getenv("SPLIT_PER_ABI") == "1" ||
                (project.findProperty("target-platform")?.toString() ?: "").contains(',')
        if (!splitPerAbi) {
            ndk {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a")
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Flutter --split-per-abi sets versionCodeOverride = abiIndex*1000 + N
// (arm64 → 8xxx, v7a → 7xxx). That breaks OTA: CDN latest.json advertises N,
// but a USB-installed split reports 8xxx so checkOnce() never offers an update,
// and fat APKs can't install over the split (VERSION_DOWNGRADE). Sideload-only
// channel — keep every ABI on the pubspec +N code.
android.applicationVariants.configureEach {
    val code = flutter.versionCode
    outputs.configureEach {
        @Suppress("DEPRECATION")
        (this as com.android.build.gradle.api.ApkVariantOutput).versionCodeOverride = code
    }
}

dependencies {
    // Core-library desugaring runtime for flutter_local_notifications 17+.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Virtual BG peer publish: WebRTC VideoFrame types + ML Kit selfie mask.
    // Versions aligned with flutter_webrtc 1.4.0 / google_mlkit_selfie_segmentation.
    implementation("io.github.webrtc-sdk:android:144.7559.01")
    implementation("com.google.mlkit:segmentation-selfie:16.0.0-beta6")
}
