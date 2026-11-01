plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// CI passes the signing key through the environment. Without one, a release build stays unsigned.
val keystorePath: String? = System.getenv("MARGIN_KEYSTORE_PATH")
// The release tag names the version, so an update always installs over the one before it.
val tagVersion: String = System.getenv("MARGIN_VERSION") ?: "1.0.0"
val versionParts = tagVersion.split(".").map { it.toIntOrNull() ?: 0 } + listOf(0, 0, 0)

android {
    namespace = "com.warriorbiswas.margin"
    compileSdk = 35
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.warriorbiswas.margin"
        minSdk = 29
        targetSdk = 35
        versionName = tagVersion
        versionCode = versionParts[0] * 1_000_000 + versionParts[1] * 1_000 + versionParts[2]
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // llama.cpp's speed and the 1.7B model both need a 64-bit device.
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared", "-DCMAKE_BUILD_TYPE=Release")
                // Nothing links to ggml's CPU variants, so each has to be named for it to reach the APK.
                targets += listOf("margin_llm") + listOf(
                    "armv8.0_1", "armv8.2_1", "armv8.2_2", "armv8.6_1", "armv9.0_1", "armv9.2_1", "armv9.2_2",
                ).map { "ggml-cpu-android_$it" }
            }
        }
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("MARGIN_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MARGIN_KEY_ALIAS")
                keyPassword = System.getenv("MARGIN_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        // Lets a development build sit beside the released app without touching its notes.
        debug { applicationIdSuffix = ".debug" }
        release {
            // Compose's full icon set alone is tens of megabytes, nearly all of it unused.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (keystorePath != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    // ggml finds its CPU variants by listing the app's library folder, so they must exist there as real files.
    packaging { jniLibs { useLegacyPackaging = true } }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")
    implementation("com.google.mlkit:digital-ink-recognition:18.1.0")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}
