#!/usr/bin/env bash
# ship-android.sh — one-command Android tester deploy.
#
# Builds the Rust JNI .so + the Compose APK, updates the tester package
# in place (adb install -r, never uninstall — that wipes profiles),
# verifies versionCode/Name. Leaves `com.ghoststream.vpn` (Play Market
# legacy install) alone.
#
# Usage:
#   tools/ship-android.sh                 # debug, no version bump
#   tools/ship-android.sh --release       # signed release (needs keystore env)
#   tools/ship-android.sh --bump          # auto-increment versionCode + patch
#   tools/ship-android.sh --bump --tag    # also push tag and run CI (= Play production!):
#                                         #   only from a clean tree with a "## [Android X.Y.Z]"
#                                         #   CHANGELOG section, asks for confirmation
#   tools/ship-android.sh --tag --ci-only # skip local build, pull APK from the new tag
#   tools/ship-android.sh --device <id>   # adb -s <id>; defaults to TARGET_DEVICE
#
# Memory rules baked in:
#   - never uninstall anything: update in place, profiles must survive
#   - never touch com.ghoststream.vpn (Play Market)
#   - bump version every install (feedback_version_bump)
#
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="${REPO_ROOT}/apps/android"
APP_DIR="${ANDROID_DIR}/app"
BUILD_GRADLE="${APP_DIR}/build.gradle.kts"
NATIVE_OUT="${APP_DIR}/src/main/jniLibs"
RUST_CRATE="phantom-client-android"
TARGET_ABI="arm64-v8a"
PLAYSTORE_PKG="com.ghoststream.vpn"      # legacy, NEVER touch
DEBUG_PKG="io.ghoststream.vpn.debug"
RELEASE_PKG="io.ghoststream.vpn"
DEFAULT_DEVICE="${TARGET_DEVICE:-}"      # set env to skip --device flag

# ── Argv ──────────────────────────────────────────────────────────────────
MODE="debug"
BUMP=0
PUSH_TAG=0
CI_ONLY=0
DEVICE="${DEFAULT_DEVICE}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) MODE="release"; shift ;;
        --bump) BUMP=1; shift ;;
        --tag) PUSH_TAG=1; BUMP=1; shift ;;
        --ci-only) CI_ONLY=1; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Logging helpers ──────────────────────────────────────────────────────
say()  { printf '\033[1;36m[ship]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ship]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ship]\033[0m %s\n' "$*" >&2; exit 1; }

# ── adb wrapper ──────────────────────────────────────────────────────────
adb_cmd() {
    if [[ -n "$DEVICE" ]]; then
        adb -s "$DEVICE" "$@"
    else
        adb "$@"
    fi
}

resolve_device() {
    local count
    count=$(adb devices | grep -E "^\S+\s+device$" | wc -l | tr -d ' ')
    if [[ -z "$DEVICE" ]]; then
        if [[ "$count" == "0" ]]; then die "no adb device found"; fi
        if [[ "$count" == "1" ]]; then
            DEVICE=$(adb devices | grep -E "^\S+\s+device$" | awk '{print $1}')
            say "using device: ${DEVICE}"
        else
            warn "multiple adb devices, pass --device <id> or set TARGET_DEVICE"
            adb devices
            exit 2
        fi
    fi
}

# ── version bump ─────────────────────────────────────────────────────────
bump_version() {
    local cur_code cur_name new_code new_name
    cur_code=$(grep -E 'versionCode = [0-9]+' "$BUILD_GRADLE" | head -1 | grep -oE '[0-9]+')
    cur_name=$(grep -E 'versionName = "[^"]+"' "$BUILD_GRADLE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    new_code=$((cur_code + 1))
    # patch bump: split MAJOR.MINOR.PATCH, +1 to PATCH
    new_name=$(echo "$cur_name" | awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}')
    say "bump: $cur_code/$cur_name → $new_code/$new_name"
    # Use sed in-place compatible with both BSD (macOS) and GNU
    if sed --version >/dev/null 2>&1; then
        sed -i -E "s/versionCode = ${cur_code}/versionCode = ${new_code}/" "$BUILD_GRADLE"
        sed -i -E "s/versionName = \"${cur_name}\"/versionName = \"${new_name}\"/" "$BUILD_GRADLE"
        sed -i -E "s/GIT_TAG\", \"\\\\\"v${cur_name}\\\\\"\"/GIT_TAG\", \"\\\\\"v${new_name}\\\\\"\"/" "$BUILD_GRADLE"
    else
        sed -i '' -E "s/versionCode = ${cur_code}/versionCode = ${new_code}/" "$BUILD_GRADLE"
        sed -i '' -E "s/versionName = \"${cur_name}\"/versionName = \"${new_name}\"/" "$BUILD_GRADLE"
        sed -i '' -E "s/GIT_TAG\", \"\\\\\"v${cur_name}\\\\\"\"/GIT_TAG\", \"\\\\\"v${new_name}\\\\\"\"/" "$BUILD_GRADLE"
    fi
    NEW_TAG="v${new_name}"
}

# ── ensure SDK + NDK reachable, never touch git-tracked local.properties ─
LOCAL_PROPS="${ANDROID_DIR}/local.properties"
LOCAL_PROPS_BACKUP=""

ensure_sdk() {
    if [[ -n "${ANDROID_HOME:-}" ]] && [[ -d "$ANDROID_HOME" ]]; then return 0; fi
    if [[ -n "${ANDROID_SDK_ROOT:-}" ]] && [[ -d "$ANDROID_SDK_ROOT" ]]; then
        export ANDROID_HOME="$ANDROID_SDK_ROOT"
        return 0
    fi
    # Try canonical macOS paths
    local candidates=(
        "$HOME/Library/Android/sdk"
        "/opt/homebrew/share/android-commandlinetools"
        "/usr/local/share/android-commandlinetools"
        "/opt/android-sdk"
    )
    for c in "${candidates[@]}"; do
        if [[ -d "$c" ]]; then
            export ANDROID_HOME="$c"
            export ANDROID_SDK_ROOT="$c"
            say "SDK auto-detected: $ANDROID_HOME"
            return 0
        fi
    done
    return 1
}

ensure_ndk() {
    if [[ -n "${ANDROID_NDK_HOME:-}" ]] && [[ -d "$ANDROID_NDK_HOME" ]]; then
        say "NDK: $ANDROID_NDK_HOME"
        return 0
    fi
    local search_roots=(
        "${ANDROID_HOME:-}"
        "$HOME/Library/Android/sdk"
        "/opt/homebrew/share/android-commandlinetools"
        "/usr/local/share/android-commandlinetools"
    )
    for root in "${search_roots[@]}"; do
        [[ -n "$root" ]] || continue
        if [[ -d "${root}/ndk" ]]; then
            local newest
            newest=$(ls -1 "${root}/ndk" 2>/dev/null | sort -V | tail -1 || true)
            if [[ -n "$newest" ]] && [[ -d "${root}/ndk/${newest}" ]]; then
                export ANDROID_NDK_HOME="${root}/ndk/${newest}"
                say "NDK auto-detected: $ANDROID_NDK_HOME"
                return 0
            fi
        fi
    done
    return 1
}

# Make sure local.properties points at *our* SDK for the duration of the
# build, then restore on exit so we never accidentally commit a path
# specific to this machine (the repo ships `/opt/android-sdk` for CI).
ensure_local_properties() {
    [[ -n "${ANDROID_HOME:-}" ]] || die "ANDROID_HOME unset after ensure_sdk"
    LOCAL_PROPS_BACKUP=$(mktemp)
    if [[ -f "$LOCAL_PROPS" ]]; then
        cp "$LOCAL_PROPS" "$LOCAL_PROPS_BACKUP"
    fi
    printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$LOCAL_PROPS"
}

restore_local_properties() {
    if [[ -n "$LOCAL_PROPS_BACKUP" ]] && [[ -f "$LOCAL_PROPS_BACKUP" ]]; then
        cp "$LOCAL_PROPS_BACKUP" "$LOCAL_PROPS"
        rm -f "$LOCAL_PROPS_BACKUP"
    elif [[ -n "$LOCAL_PROPS_BACKUP" ]]; then
        rm -f "$LOCAL_PROPS"
    fi
}
trap restore_local_properties EXIT

# ── build Rust native lib ────────────────────────────────────────────────
build_rust() {
    say "building Rust JNI (cargo ndk -t $TARGET_ABI release)..."
    cd "$REPO_ROOT"
    # gradle preBuild собирает .so и под armeabi-v7a — нужен и этот target.
    rustup target add aarch64-linux-android armv7-linux-androideabi >/dev/null
    cargo ndk -t "$TARGET_ABI" -o "$NATIVE_OUT" --platform 26 \
        build --release -p "$RUST_CRATE"
    local so="${NATIVE_OUT}/${TARGET_ABI}/libphantom_android.so"
    if [[ ! -f "$so" ]]; then die "expected $so missing after cargo ndk"; fi
    say "Rust .so: $(ls -la "$so" | awk '{print $5,$6,$7,$8}')"
}

# ── build APK ────────────────────────────────────────────────────────────
build_apk() {
    say "building $MODE APK..."
    cd "$ANDROID_DIR"
    if [[ "$MODE" == "release" ]]; then
        ./gradlew :app:assembleRelease
        APK="$APP_DIR/build/outputs/apk/release/app-release.apk"
    else
        ./gradlew :app:assembleDebug
        APK="$APP_DIR/build/outputs/apk/debug/app-debug.apk"
    fi
    [[ -f "$APK" ]] || die "APK not found: $APK"
    say "APK: $APK ($(du -h "$APK" | awk '{print $1}'))"
}

# ── update in place (never uninstall: uninstall wipes the owner's profiles) ──
deploy_apk() {
    local target_pkg
    if [[ "$MODE" == "release" ]]; then target_pkg="$RELEASE_PKG"; else target_pkg="$DEBUG_PKG"; fi

    say "device packages before:"
    adb_cmd shell pm list packages | grep ghoststream || true

    say "updating $APK ($target_pkg)..."
    adb_cmd install -r "$APK" \
        || die "install -r failed (signature mismatch?) — NOT uninstalling: it would wipe profiles; ask the owner"

    say "device packages after:"
    adb_cmd shell pm list packages | grep ghoststream || true

    local installed
    installed=$(adb_cmd shell dumpsys package "$target_pkg" 2>/dev/null \
        | grep -E "versionName|versionCode" | head -2 | tr '\n' ' ')
    say "installed: $installed"
}

# ── CI route ─────────────────────────────────────────────────────────────
deploy_from_ci() {
    [[ -n "${NEW_TAG:-}" ]] || die "--ci-only requires --bump --tag to know which tag to fetch"
    confirm_push "Выкатить $NEW_TAG в Play production без проверки на устройстве?"
    say "pushing tag $NEW_TAG..."
    cd "$REPO_ROOT"
    git add "$BUILD_GRADLE"
    git commit -m "chore(android): bump to $NEW_TAG"
    git tag "$NEW_TAG"
    git push origin master
    git push origin "$NEW_TAG"

    say "waiting for CI..."
    # unset GITHUB_TOKEN if it's set to invalid value (gh expects keychain)
    unset GITHUB_TOKEN || true
    local start=$SECONDS
    while gh run list --limit 1 2>/dev/null | head -1 | grep -qE "(in_progress|queued)"; do
        sleep 30
        if (( SECONDS - start > 1800 )); then die "CI timeout"; fi
    done
    local last
    last=$(gh run list --limit 1 2>&1 | head -1)
    echo "$last" | grep -q "success" || die "CI failed: $last"

    say "downloading from release $NEW_TAG..."
    rm -rf "/tmp/ghoststream-${NEW_TAG}"
    gh release download "$NEW_TAG" -R PatrickRedStar/phantom-vpn \
        -D "/tmp/ghoststream-${NEW_TAG}/" --pattern '*.apk'
    APK="/tmp/ghoststream-${NEW_TAG}/app-release.apk"
    MODE="release"
    deploy_apk
}

# ── tag guard: в Play уходит то, что закоммичено, а не то, что на телефоне ──
require_clean_tree() {
    cd "$REPO_ROOT"
    git diff --quiet HEAD || die "--tag: есть незакоммиченные правки — в Play уехала бы сборка без них. Закоммить или убери."
}

# Release.yml без этой секции роняет Android-джобу, а тег уже был бы запушен.
require_changelog() {
    grep -q "^## \[Android ${NEW_TAG#v}\]" "$REPO_ROOT/CHANGELOG.md" && return 0
    git -C "$REPO_ROOT" checkout -- "$BUILD_GRADLE"
    die "--tag: в CHANGELOG.md нет секции '## [Android ${NEW_TAG#v}]' — добавь и закоммить; bump откачен"
}

confirm_push() {
    local ans
    read -r -p "$1 [y/N] " ans
    [[ "$ans" == [yY] ]] || die "тег не поставлен; bump остался в $BUILD_GRADLE (откат: git checkout -- $BUILD_GRADLE)"
}

# ── main ─────────────────────────────────────────────────────────────────
[[ "$PUSH_TAG" == "1" ]] && require_clean_tree

resolve_device

if [[ "$BUMP" == "1" ]]; then bump_version; fi
[[ "$PUSH_TAG" == "1" ]] && require_changelog

if [[ "$CI_ONLY" == "1" ]]; then
    [[ "$PUSH_TAG" == "1" ]] || die "--ci-only requires --tag"
    deploy_from_ci
    exit 0
fi

# Local build path
ensure_sdk || warn "no SDK auto-detected; relying on env"
if ! ensure_ndk; then
    # Без NDK нечего проверить на устройстве до тега — молча уходить в CI нельзя.
    die "NDK not found (install via sdkmanager 'ndk;26.3.11579264' or set ANDROID_NDK_HOME); for a CI-only build use --tag --ci-only explicitly"
fi
ensure_local_properties

build_rust
build_apk
deploy_apk

if [[ "$PUSH_TAG" == "1" ]]; then
    confirm_push "Проверил на устройстве?"
    say "pushing tag $NEW_TAG (for CI release)..."
    cd "$REPO_ROOT"
    git add "$BUILD_GRADLE"
    git commit -m "chore(android): bump to $NEW_TAG"
    git tag "$NEW_TAG"
    git push origin master
    git push origin "$NEW_TAG"
fi

say "done."
