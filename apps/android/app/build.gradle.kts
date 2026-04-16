plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.ghoststream.vpn"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.ghoststream.vpn"
        minSdk = 26
        targetSdk = 36
        versionCode = 55
        versionName = "0.21.0"
        buildConfigField("String", "GIT_TAG", "\"v0.21.0\"")
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
