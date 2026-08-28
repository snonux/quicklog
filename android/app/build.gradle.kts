import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Optional release keystore, read from android/key.properties (git-ignored).
// F-Droid never uses it: F-Droid builds from source and signs every APK with its
// own key, so the release build type must not depend on a keystore being present.
// storeFile is resolved by Project.file() below, i.e. relative to android/app/.
val keystoreKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

val keystoreProperties =
    Properties().apply {
        val keystoreFile = rootProject.file("key.properties")
        if (keystoreFile.exists()) {
            keystoreFile.inputStream().use { load(it) }
            // A half-filled key.properties would otherwise fall through to the
            // debug keys below and quietly produce a debug-signed "release" APK.
            val missing = keystoreKeys.filter { getProperty(it).isNullOrBlank() }
            require(missing.isEmpty()) {
                "android/key.properties is missing: ${missing.joinToString(", ")}"
            }
        }
    }

val hasReleaseKeystore = keystoreProperties.isNotEmpty()

// Only nag when a release is actually being assembled, so `flutter run` stays quiet.
if (!hasReleaseKeystore &&
    gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
) {
    logger.quiet(
        "Quicklog: no android/key.properties found -- this release build will be " +
            "signed with the debug keys. Fine for local testing and for F-Droid " +
            "(which re-signs), not for an APK you hand to anyone else.",
    )
}

android {
    namespace = "org.buetow.quicklog"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.buetow.quicklog"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Both come from the `version:` line in pubspec.yaml (see the comment there).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // AGP otherwise embeds a Google Play dependency-metadata blob in the APK
    // signing block. F-Droid's scanner rejects the APK over it ("Found extra
    // signing block 'Dependency metadata'"), and it serves nothing outside Play.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Own keystore when android/key.properties exists, otherwise the debug
            // keys so `flutter run --release` and local test APKs still work. Either
            // way F-Droid strips the signature and re-signs with the F-Droid key.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
