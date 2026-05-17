#!/usr/bin/env bash
# smoke-test.sh — end-to-end Connect verification for macOS GhostStream.
#
# WHY: 5 rounds of static audit/fix iterations in 2026-05 failed to detect a
# regression where the system extension couldn't read cert/key from the user
# Data Protection Keychain (extension runs as root → no user keychain access).
# The bug only surfaced at runtime — every static check passed. This script
# is the runtime gate. Run it after every fix wave, before declaring done.
#
# What it does:
#   1. Verifies a debug or release build is installed in /Applications.
#   2. Reads the active profile id from the App Group container.
#   3. Triggers Connect via `scutil --nc start` (no clicking required).
#   4. Polls `scutil --nc status` for up to ${TIMEOUT_SECS} seconds.
#   5. PASS iff status reaches "Connected" — anything else (Disconnected,
#      Disconnecting, error) dumps the last 2 minutes of ghoststream unified
#      log to /tmp/ghoststream-smoke-fail.log and exits non-zero.
#
# Use as: apps/macos/scripts/smoke-test.sh
# Env vars (optional):
#   TIMEOUT_SECS=45  — how long to wait for .connected
#   PROFILE_NAME     — VPN config name in NEVPNManager (default: auto-detect)
#
# See:
#   docs/knowledge/incidents/2026-05-17-cert-pem-keychain-regression.md
#   docs/knowledge/decisions/0009-cert-pem-providerConfiguration.md

set -euo pipefail

TIMEOUT_SECS="${TIMEOUT_SECS:-45}"
APP_PATH="/Applications/GhostStream.app"
FAIL_LOG="/tmp/ghoststream-smoke-fail.log"
APP_GROUP_DIR="$HOME/Library/Group Containers/group.com.ghoststream.client"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# ─── Pre-flight ─────────────────────────────────────────────────────────────

if [[ ! -d "$APP_PATH" ]]; then
    red "FAIL: $APP_PATH not installed. Run install-debug.sh or open the DMG first."
    exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
yellow "==> Smoke-testing GhostStream $VERSION ($BUILD)"

# Resolve VPN config name. Most installs name it "macbook-m1pro" or similar
# from the host's `Host.current.localizedName`. Use the first ghoststream
# packet-tunnel config we find.
if [[ -z "${PROFILE_NAME:-}" ]]; then
    PROFILE_NAME="$(scutil --nc list 2>/dev/null | grep -E 'com\.ghoststream\.client[^.]*$' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi
if [[ -z "$PROFILE_NAME" ]]; then
    red "FAIL: no NEVPNManager config found for com.ghoststream.client. Run the app once and import a ghs:// URL first."
    exit 3
fi
yellow "==> VPN config name: $PROFILE_NAME"

# Check there IS a profile in the App Group so Provider can load something.
ACTIVE_ID="$(/usr/libexec/PlistBuddy -c 'Print :active_id' "$APP_GROUP_DIR/Library/Preferences/group.com.ghoststream.client.plist" 2>/dev/null || true)"
if [[ -z "$ACTIVE_ID" ]]; then
    red "FAIL: no active_id in App Group container. Import a ghs:// URL via Settings first."
    exit 4
fi
yellow "==> Active profile id: $ACTIVE_ID"

# ─── Trigger Connect ────────────────────────────────────────────────────────

INITIAL_STATUS="$(scutil --nc status "$PROFILE_NAME" 2>/dev/null | head -1 || echo Unknown)"
if [[ "$INITIAL_STATUS" == "Connected" ]]; then
    yellow "==> Tunnel already connected — stopping first for a clean test."
    scutil --nc stop "$PROFILE_NAME" >/dev/null || true
    sleep 2
fi

yellow "==> Triggering scutil --nc start $PROFILE_NAME"
scutil --nc start "$PROFILE_NAME"

# ─── Poll for Connected ─────────────────────────────────────────────────────

DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
LAST_STATUS=""
while (( $(date +%s) < DEADLINE )); do
    STATUS="$(scutil --nc status "$PROFILE_NAME" 2>/dev/null | head -1 || echo Unknown)"
    if [[ "$STATUS" != "$LAST_STATUS" ]]; then
        echo "  status: $STATUS  ($(date +%T))"
        LAST_STATUS="$STATUS"
    fi
    case "$STATUS" in
        Connected)
            green "==> PASS: tunnel reached Connected in $((TIMEOUT_SECS - (DEADLINE - $(date +%s))))s"
            exit 0
            ;;
        Disconnected)
            # Could be initial state — give it a moment to transition.
            sleep 1
            ;;
        Disconnecting|Invalid|Reasserting)
            # These are terminal-failure indicators if we never reached Connected.
            sleep 1
            ;;
        *)
            sleep 1
            ;;
    esac
done

# ─── Failure path: dump logs ────────────────────────────────────────────────

red "==> FAIL: tunnel did NOT reach Connected within ${TIMEOUT_SECS}s (last status: $LAST_STATUS)"
yellow "==> Dumping ghoststream logs to $FAIL_LOG"

log show \
    --predicate 'subsystem CONTAINS "ghoststream" OR composedMessage CONTAINS "ghoststream" OR composedMessage CONTAINS "client.tunnel"' \
    --last 2m \
    --info --debug \
    --style compact 2>&1 > "$FAIL_LOG" || true

echo ""
red "Last 30 lines of failure log:"
tail -30 "$FAIL_LOG"

echo ""
yellow "Full log:  $FAIL_LOG"
yellow "Hint: if you see 'BridgeError error 1', the bug is the cert/key sanitisation"
yellow "      regression — read docs/knowledge/incidents/2026-05-17-cert-pem-keychain-regression.md"

exit 1
