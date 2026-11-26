import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = file(
    providers.environmentVariable("MOMENTAI_SIGNING_PROPERTIES")
        .orElse(
            "${System.getProperty("user.home")}/.config/momentai/android-signing.properties"
        ).get()
)
val productSigning = Properties().apply {
    if (signingPropertiesFile.isFile) signingPropertiesFile.inputStream().use { load(it) }
}

val signingKeys = setOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val signingConfigured = signingKeys.all { !productSigning.getProperty(it).isNullOrBlank() }
require(productSigning.isEmpty() || signingConfigured) {
    "Signing configuration must provide storeFile, storePassword, keyAlias, and keyPassword."
}
val productReleaseRequested = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
require(!productReleaseRequested || signingConfigured) {
    "Product release requires MOMENTAI_SIGNING_PROPERTIES with complete signing configuration."
}

android {
    namespace = "org.hohu.momentai"
    // flutter_secure_storage 11 compiles against API 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.hohu.momentai"
        manifestPlaceholders["momentaiAppLabel"] = "@string/app_name"
        testInstrumentationRunner = "org.hohu.momentai.M3aInstrumentation"
        // Flutter 3.44 requires API 24; this is a build floor, not a tested device matrix.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Android application builds target arm64. Keep native assets
        // on the same ABI as the selected Flutter engine.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingConfigured) {
            create("product") {
                storeFile = file(productSigning.getProperty("storeFile"))
                storePassword = productSigning.getProperty("storePassword")
                keyAlias = productSigning.getProperty("keyAlias")
                keyPassword = productSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
        }
        release {
            if (signingConfigured) signingConfig = signingConfigs.getByName("product")
        }
    }
    bundle {
        language {
            // Both languages must remain available for the offline language switcher.
            enableSplit = false
        }
    }
    sourceSets.getByName("androidTest").assets.srcDir("../../test/fixtures/m2")
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
    testImplementation("junit:junit:4.13.2")
    implementation("androidx.core:core:1.13.1")
    implementation("androidx.activity:activity:1.8.1")
}
