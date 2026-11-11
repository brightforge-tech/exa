import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives in android/key.properties (never commit it).
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.brightforge.exa"
    // Pinned to 36: flutter_plugin_android_lifecycle (pulled in by file_picker
    // and other plugins) requires apps to compile against SDK 36+.
    compileSdk = 36
    // Flutter's default NDK (28.2) is a corrupted download on this machine;
    // 29.0 is installed and intact.
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (java.time backport).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.brightforge.exa"
        // Android 8.0+ per the product spec; secure storage needs 23+.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                storeFile =
                    rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    // Unit tests for the messaging package (NotificationMedia's Extras
    // mapping and bounded probe). Robolectric because the code under test
    // speaks Bundle/Uri/ContentResolver - framework types a bare JVM test
    // cannot build - and no androidx.core, which this module deliberately
    // does not depend on (see ExaNotificationListener.messageEntries).
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }

    buildTypes {
        release {
            // Signed with the release keystore when key.properties exists;
            // falls back to debug keys so `flutter run --release` still
            // works on machines without it.
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Keep rules for flutter_gemma's MediaPipe/protobuf classes so R8
            // minification doesn't fail or strip JNI-referenced classes.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // workmanager_android depends on work-runtime with `implementation`, which
    // keeps it off this module's compile classpath. ExaApplication references
    // androidx.work.Configuration directly, so declare it here. This is a
    // floor, not a pin: Gradle still resolves to the highest version any
    // plugin asks for.
    implementation("androidx.work:work-runtime:2.11.0")
    // The unit-test seam for the messaging package. Robolectric's android
    // jar provides Bundle/Uri/ContentResolver behaviour on the JVM; these
    // are testImplementation, so nothing ships in the app.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
    // ApplicationProvider, the Context the Robolectric tests hand to
    // NotificationMedia.capture; it lives in androidx.test:core, which
    // robolectric does not pull in on its own.
    testImplementation("androidx.test:core:1.6.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
