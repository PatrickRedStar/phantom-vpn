# v0.25.0 — keep rules for when isMinifyEnabled is flipped to true.
# Currently R8 disabled, but build.gradle.kts:42 already references this
# file so it must exist for AGP to be happy.

# ── JNI bridge: Rust calls back into Kotlin by string name ───────────
-keepclasseswithmembernames class com.ghoststream.vpn.service.GhostStreamVpnService {
    native <methods>;
}
-keep,allowobfuscation interface com.ghoststream.vpn.service.PhantomListener
-keep class com.ghoststream.vpn.service.PhantomListener { *; }

# Methods called via JNI by name: onStatusFrame(String), onLogFrame(String),
# onPairingPayload(String), protect(int)
-keepclassmembers class * implements com.ghoststream.vpn.service.PhantomListener {
    public void onStatusFrame(java.lang.String);
    public void onLogFrame(java.lang.String);
    public void onPairingPayload(java.lang.String);
    public boolean protect(int);
}

# ── MLKit barcode scanning (uses reflection via Tasks API) ───────────
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.mlkit_**

# ── CameraX (camera2 backend reflectively loaded) ────────────────────
-keep class androidx.camera.camera2.** { *; }
-keep class androidx.camera.core.impl.** { *; }
-dontwarn androidx.camera.**

# ── Compose runtime helpers ──────────────────────────────────────────
# Keep Saveable factories — Compose uses reflection on Saver objects.
-keepclassmembers class androidx.compose.runtime.saveable.** { *; }
