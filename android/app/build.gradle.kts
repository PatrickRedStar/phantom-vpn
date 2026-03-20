plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.phantom.vpn"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.phantom.vpn"
        minSdk = 26          // Android 8.0+ (API 26), needed for foregroundServiceType
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
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
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }

    // Rust .so files built separately with cargo-ndk
    // Place at: android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.activity:activity-ktx:1.8.2")
}

// ─── Task to build Rust library with cargo-ndk ────────────────────────────────
//
// Prerequisites:
//   cargo install cargo-ndk
//   rustup target add aarch64-linux-android
//
// The task builds libphantom_android.so and copies it to jniLibs.

val cargoWorkspaceDir = file("${rootProject.rootDir}/..")

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

// If you want Gradle to auto-build Rust before assembling:
// tasks.named("preBuild") { dependsOn("buildRustAndroid") }
