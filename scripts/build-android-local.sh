#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

source ~/.cargo/env
export ANDROID_NDK_HOME=/opt/android-ndk
export JAVA_HOME="$HOME/.jdk"
export PATH="$HOME/.gradle-dist/gradle-8.7/bin:$PATH"

echo "==> Building Rust .so..."
cargo ndk -t arm64-v8a --platform 26 \
  build --release -p phantom-client-android

mkdir -p android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/libphantom_android.so \
   android/app/src/main/jniLibs/arm64-v8a/

echo "==> Building APK..."
cd android
[ ! -f gradlew ] && gradle wrapper --gradle-version 8.7
./gradlew assembleDebug --no-daemon -q

APK=app/build/outputs/apk/debug/app-debug.apk
echo "==> Installing on device..."
adb install -r "$APK" 2>/dev/null || (adb uninstall com.ghoststream.vpn 2>/dev/null; adb install "$APK")
echo "==> Done"
