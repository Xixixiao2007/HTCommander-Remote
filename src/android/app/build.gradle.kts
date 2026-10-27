import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // com.google.gms.google-services is absent on purpose: this fork does not
    // ship APRS cloud push, so there is no google-services.json to process.
    // Without that plugin the applicationId is free to differ from upstream's,
    // which is what lets both builds coexist on one device.
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.meshcentral.htcommander"
    // permission_handler_android 14.x requires API 37. Compiling against a
    // newer SDK remains backward-compatible with the min/target SDK settings.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (v10+) even when only
        // immediate notifications are used.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Distinct from upstream's com.meshcentral.htcommander on purpose.
        //
        // The two builds are signed with different keys, so Android refuses to
        // install one over the other (INSTALL_FAILED_UPDATE_INCOMPATIBLE) --
        // meaning trying this fork would first destroy the official app's
        // settings, channels and tokens on the device. A separate application
        // id lets both coexist, each with its own data.
        //
        // namespace stays com.meshcentral.htcommander: MainActivity,
        // RadioCarAppService and the Dart entrypoint all resolve through that
        // package, and only the install identity needs to differ.
        applicationId = "com.meshcentral.htcommander.remote"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Firebase Cloud Messaging (firebase_messaging) requires a minimum of
        // API 23, so raise it above Flutter's default when needed.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Enables per-app language selection (autoStoreLocales) on Android 12 and below.
    implementation("androidx.appcompat:appcompat:1.7.0")
    // Android for Cars App Library: templated Android Auto UI (RadioCarAppService).
    implementation("androidx.car.app:app:1.7.0")
    // Core-library desugaring support for flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
