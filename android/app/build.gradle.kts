plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.ghoststream.vpn"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.ghoststream.vpn"
        minSdk = 26
        targetSdk = 35
        versionCode = 23
        versionName = "0.11.1"
        buildConfigField("String", "GIT_TAG", "\"v0.11.1\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // composeOptions блок убран — с Kotlin 2.0+ Compose Compiler встроен в Kotlin plugin

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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

    // Activity Compose
    implementation("androidx.activity:activity-compose:1.9.3")

    // Navigation Compose
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Lifecycle + ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.1.2")

    // Core
    implementation("androidx.core:core-ktx:1.15.0")

    // CameraX + ML Kit for QR scanning
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.2.0")

    // ZXing core for QR code generation
    implementation("com.google.zxing:core:3.5.3")
}

val cargoWorkspaceDir = file("${rootProject.rootDir}/..")

tasks.register<Exec>("buildRustAndroid") {
    description = "Build Rust JNI library for Android arm64-v8a + armeabi-v7a"
    workingDir = cargoWorkspaceDir
    commandLine(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-t", "armeabi-v7a",
        "-o", "${projectDir}/src/main/jniLibs",
        "build", "--release", "-p", "phantom-client-android"
    )
}
