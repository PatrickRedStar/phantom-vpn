#!/usr/bin/env bash
# Build phantom-client-apple for iOS device + simulator + macOS archs and
# package them as an XCFramework consumable by Xcode.
#
# Invoke from anywhere:  bash crates/client-apple/build-xcframework.sh
# Make sure it is executable:  chmod +x crates/client-apple/build-xcframework.sh
# Verbose mode:          VERBOSE=1 bash crates/client-apple/build-xcframework.sh

set -euo pipefail
if [ "${VERBOSE:-}" = "1" ]; then
    set -x
fi

# ─── Paths ────────────────────────────────────────────────────────────────────
#
# MIG-R4-R01: resolve the repo root via `cd && pwd` instead of
# `git rev-parse --show-toplevel`. The release tarballs that the
# notarisation pipeline produces are extracted in a non-git workdir on
# CI, so a git-based lookup `fatal: not a git repository`-fails and the
# whole xcframework build aborts. The script lives at a known relative
# path inside the repo (`crates/client-apple/`), so the two-up
# resolution is stable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CRATE_DIR="$REPO_ROOT/crates/client-apple"
HEADERS_DIR="$CRATE_DIR/include"
OUT_DIR="$REPO_ROOT/apps/ios/Frameworks"
OUT_XCFRAMEWORK="$OUT_DIR/PhantomCore.xcframework"
LIB_NAME="libphantom_client_apple.a"
FAT_SIM_DIR="$REPO_ROOT/target/ios-sim-fat/release"
FAT_MACOS_DIR="$REPO_ROOT/target/macos-fat/release"

# ─── Tool checks ──────────────────────────────────────────────────────────────

command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found in PATH" >&2; exit 1; }
command -v rustup >/dev/null 2>&1 || { echo "error: rustup not found in PATH" >&2; exit 1; }
command -v lipo >/dev/null 2>&1 || { echo "error: lipo not found (Xcode command-line tools)" >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found (Xcode command-line tools)" >&2; exit 1; }

if ! command -v cbindgen >/dev/null 2>&1; then
    echo "error: cbindgen not found in PATH" >&2
    echo "       install via:  cargo install cbindgen" >&2
    exit 1
fi

# ─── Targets ──────────────────────────────────────────────────────────────────

echo "==> Ensuring Apple rustup targets are installed…"
rustup target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios \
    aarch64-apple-darwin \
    x86_64-apple-darwin

# ─── Build per target ─────────────────────────────────────────────────────────

IOS_MIN="${IOS_DEPLOYMENT_TARGET:-17.0}"
MACOS_MIN="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

build_target() {
    local triple="$1"
    local var_name="CFLAGS_${triple//-/_}"
    local deployment_flag=""
    local platform_label=""
    case "$triple" in
        aarch64-apple-ios)
            deployment_flag="-mios-version-min=$IOS_MIN"
            platform_label="min iOS $IOS_MIN"
            ;;
        aarch64-apple-ios-sim)
            deployment_flag="-mios-simulator-version-min=$IOS_MIN"
            platform_label="min iOS $IOS_MIN (sim)"
            ;;
        x86_64-apple-ios)
            deployment_flag="-mios-simulator-version-min=$IOS_MIN"
            platform_label="min iOS $IOS_MIN (sim)"
            ;;
        aarch64-apple-darwin|x86_64-apple-darwin)
            deployment_flag="-mmacosx-version-min=$MACOS_MIN"
            platform_label="min macOS $MACOS_MIN"
            ;;
    esac
    # MIG-R4-N14: `--locked` pins Cargo.lock so a stale crate cache
    # on the build host can't silently produce binaries whose
    # transitive deps differ from CI. Without it, a `cargo update` in
    # one of the dev shells would change ABI underneath the xcframework
    # (rustls and ring in particular touch the C symbol surface) — the
    # resulting .a would link fine but exhibit subtle runtime
    # mismatches against the Swift FFI layer.
    echo "==> cargo build --locked --release --target $triple -p phantom-client-apple ($platform_label)"
    (cd "$REPO_ROOT" && \
        export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" && \
        export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN" && \
        export "$var_name=$deployment_flag" && \
        cargo build --locked --release --target "$triple" -p phantom-client-apple)
}

build_target aarch64-apple-ios
build_target aarch64-apple-ios-sim
build_target x86_64-apple-ios
build_target aarch64-apple-darwin
build_target x86_64-apple-darwin

# ─── Lipo the two simulator archs into a single fat lib ───────────────────────

echo "==> lipo arm64-sim + x86_64-sim → fat sim lib"
mkdir -p "$FAT_SIM_DIR"
lipo -create \
    "$REPO_ROOT/target/aarch64-apple-ios-sim/release/$LIB_NAME" \
    "$REPO_ROOT/target/x86_64-apple-ios/release/$LIB_NAME" \
    -output "$FAT_SIM_DIR/$LIB_NAME"

# ─── Lipo the two macOS archs into a single fat lib ───────────────────────────

echo "==> lipo arm64-macos + x86_64-macos → fat macos lib"
mkdir -p "$FAT_MACOS_DIR"
lipo -create \
    "$REPO_ROOT/target/aarch64-apple-darwin/release/$LIB_NAME" \
    "$REPO_ROOT/target/x86_64-apple-darwin/release/$LIB_NAME" \
    -output "$FAT_MACOS_DIR/$LIB_NAME"

# ─── Regenerate C header ──────────────────────────────────────────────────────

echo "==> cbindgen → $HEADERS_DIR/PhantomCore.h"
mkdir -p "$HEADERS_DIR"
cbindgen \
    --config "$CRATE_DIR/cbindgen.toml" \
    --crate phantom-client-apple \
    --output "$HEADERS_DIR/PhantomCore.h"

# ─── Create XCFramework ───────────────────────────────────────────────────────

echo "==> Creating XCFramework at $OUT_XCFRAMEWORK"
mkdir -p "$OUT_DIR"
# xcodebuild refuses to overwrite an existing xcframework.
rm -rf "$OUT_XCFRAMEWORK"

xcodebuild -create-xcframework \
    -library "$REPO_ROOT/target/aarch64-apple-ios/release/$LIB_NAME" \
    -headers "$HEADERS_DIR" \
    -library "$FAT_SIM_DIR/$LIB_NAME" \
    -headers "$HEADERS_DIR" \
    -library "$FAT_MACOS_DIR/$LIB_NAME" \
    -headers "$HEADERS_DIR" \
    -output "$OUT_XCFRAMEWORK"

echo ""
echo "==> SUCCESS"
echo "    XCFramework: $OUT_XCFRAMEWORK"
echo "    Header:      $HEADERS_DIR/PhantomCore.h"
