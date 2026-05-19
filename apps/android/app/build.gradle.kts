plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.ghoststream.vpn"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.ghoststream.vpn"
        minSdk = 26
        targetSdk = 36
        versionCode = 90
        versionName = "0.26.16"
        buildConfigField("String", "GIT_TAG", "\"v0.26.16\"")
    }

    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("RELEASE_KEYSTORE_PATH")
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("RELEASE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("RELEASE_KEY_ALIAS")
                keyPassword = System.getenv("RELEASE_KEYSTORE_PASSWORD")
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            // Distinct applicationId so debug builds can coexist with the
            // Play Store release on the same device (used for perf testing).
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2025.01.01")
    implementation(composeBom)

    // Compose
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // v0.26.0: Material 3 Adaptive — currentWindowAdaptiveInfo (foldable/
    // window-class awareness) + NavigationSuiteScaffoldLayout for switching
    // between custom Bar/Rail/Drawer chrome based on form factor.
    //
    // Compose BOM 2025.01.01 does NOT include the adaptive-* artifacts —
    // they ship under separate version trains. Pinned explicitly.
    //
    // Versions verified against developer.android.com on 2026-05-16:
    //   adaptive / adaptive-layout / adaptive-navigation → 1.2.0 stable
    //     (released 2025-10-22, brings L/XL window classes to stable APIs).
    //   material3-adaptive-navigation-suite → 1.3.0 stable.
    //     This artifact moved into the main material3 release train, so its
    //     version number jumped from 1.0.0-xxx to 1.3.0-xxx and now tracks
    //     material3 1.3.x. 1.5.0-alphaXX is the bleeding edge — we stay on
    //     1.3.0 stable.
    implementation("androidx.compose.material3.adaptive:adaptive:1.2.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.2.0")
    implementation("androidx.compose.material3.adaptive:adaptive-navigation:1.2.0")
    implementation("androidx.compose.material3:material3-adaptive-navigation-suite:1.3.0")

    // Activity Compose
    implementation("androidx.activity:activity-compose:1.9.3")

    // Navigation Compose
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Lifecycle + ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Core
    implementation("androidx.core:core-ktx:1.15.0")
    // AppCompat — required for AppCompatDelegate.setApplicationLocales()
    implementation("androidx.appcompat:appcompat:1.7.0")

    // CameraX + ML Kit for QR scanning
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // ZXing core for QR code generation
    implementation("com.google.zxing:core:3.5.3")

    // OkHttp for mTLS admin API
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Glance — home screen widgets
    implementation("androidx.glance:glance:1.1.1")
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")

    testImplementation("junit:junit:4.13.2")
}

val cargoWorkspaceDir = file("${rootProject.rootDir}/../..")

tasks.register<Exec>("buildRustAndroid") {
    description = "Build Rust JNI library for Android arm64-v8a"
    workingDir = cargoWorkspaceDir
    commandLine(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-o", "${projectDir}/src/main/jniLibs",
        "build", "--release", "-p", "phantom-client-android"
    )
}
