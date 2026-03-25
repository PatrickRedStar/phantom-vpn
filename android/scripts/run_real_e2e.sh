#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
PROFILE_FILE="$ANDROID_DIR/local-test-profile.json"

if [[ ! -f "$PROFILE_FILE" ]]; then
  echo "Missing profile file: $PROFILE_FILE"
  echo "Create untracked android/local-test-profile.json with addr/sni/tun/cert/key/(ca)/admin."
  exit 1
fi

PROFILE_B64="$(base64 -w0 "$PROFILE_FILE")"

cd "$ANDROID_DIR"
JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
./gradlew \
  assembleDebug \
  connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.e2e_profile_b64="$PROFILE_B64" \
  --no-daemon

echo "E2E PASS: assembleDebug + connectedDebugAndroidTest"
