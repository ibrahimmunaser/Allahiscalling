import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Whether this Gradle invocation is producing a release artifact.
val wantsReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) ||
        it.contains("Bundle", ignoreCase = true)
}

// --dart-define values arrive from the Flutter tool as a comma-separated
// list of base64-encoded KEY=VALUE strings in the "dart-defines" property.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as? String)
        ?.split(",")
        ?.mapNotNull { encoded ->
            runCatching {
                val decoded =
                    String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
                val idx = decoded.indexOf('=')
                if (idx > 0) decoded.substring(0, idx) to
                    decoded.substring(idx + 1) else null
            }.getOrNull()
        }?.toMap() ?: emptyMap()

// Build-time validation of required production configuration. Fails the
// release build BEFORE packaging; the in-app runtime check remains only as
// a secondary safeguard. Debug builds are never blocked (the app shows a
// visible dev warning instead).
fun validateReleaseConfig() {
    val problems = mutableListOf<String>()

    val privacyUrl = dartDefines["PRIVACY_POLICY_URL"].orEmpty()
    if (privacyUrl.isEmpty()) {
        problems += "PRIVACY_POLICY_URL is missing"
    } else if (!privacyUrl.startsWith("https://") ||
        privacyUrl.contains("example.")
    ) {
        problems += "PRIVACY_POLICY_URL is not a valid production https URL: $privacyUrl"
    }

    val supportEmail = dartDefines["SUPPORT_EMAIL"].orEmpty()
    if (supportEmail.isEmpty() || !supportEmail.contains("@")) {
        problems += "SUPPORT_EMAIL is missing or invalid"
    }

    if (problems.isNotEmpty()) {
        throw GradleException(
            "RELEASE CONFIGURATION INVALID (build stopped before packaging):\n" +
                problems.joinToString("\n") { " - $it" } +
                "\nPass the values with --dart-define, e.g.:\n" +
                "  flutter build appbundle " +
                "--dart-define=PRIVACY_POLICY_URL=https://yourdomain.com/privacy " +
                "--dart-define=SUPPORT_EMAIL=support@yourdomain.com\n" +
                "See RELEASE_CHECKLIST.md."
        )
    }
}

// Release signing is configured from android/key.properties (gitignored) or
// environment variables — never committed to the repository.
// See RELEASE_CHECKLIST.md for how to create the upload keystore.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

fun signingValue(key: String, env: String): String? =
    keystoreProperties.getProperty(key) ?: System.getenv(env)

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseSigning = releaseStoreFile != null &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

android {
    namespace = "com.salahinvite.allah_invites_you_to_salah"
    compileSdk = flutter.compileSdkVersion
    // Highest NDK required across plugins (flutter_local_notifications,
    // geolocator, etc.).
    ndkVersion = "27.0.12077973"

    compileOptions {
        // Required by flutter_local_notifications (java.time backport).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.salahinvite.allah_invites_you_to_salah"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        if (wantsReleaseBuild && applicationId.orEmpty().startsWith("com.example")) {
            throw GradleException(
                "RELEASE CONFIGURATION INVALID: applicationId is still a " +
                    "com.example placeholder."
            )
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Both checks run at configuration time, so a bad release build
            // fails in seconds — before any compilation or packaging.
            if (wantsReleaseBuild) {
                validateReleaseConfig()
            }
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Fail release builds loudly instead of silently signing
                // with debug keys. Debug builds are unaffected.
                if (wantsReleaseBuild) {
                    throw GradleException(
                        "RELEASE SIGNING NOT CONFIGURED: create " +
                            "android/key.properties (see key.properties.example " +
                            "and RELEASE_CHECKLIST.md) or set the " +
                            "ANDROID_KEYSTORE_* environment variables. " +
                            "Never ship with debug keys."
                    )
                }
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
