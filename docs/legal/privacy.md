# GhostStream Privacy Policy

**Effective date:** 17 May 2026
**App ID:** `io.ghoststream.vpn`
**Contact:** peterkurkin1@gmail.com

## TL;DR

**GhostStream does not collect, store, transmit, or share any personal data.** No analytics. No tracking. No advertising SDKs. No third-party data sharing of any kind.

---

## What the app does

GhostStream is a VPN client. It routes the user's outbound network traffic through a remote server that the user explicitly configures by entering a connection string (server address, cryptographic keys, server name). The user is in full control of:

- Which server is used
- When the VPN is active (start/stop is always a manual user action)
- Which connection profile is selected

The VPN is the **sole and core function** of the app. There are no other features.

## Data the app handles

### Stored locally on the user's device

- **Connection profiles** — server address, mutual-TLS keys, SNI, server name. Entered by the user and stored on the device only.
- **Diagnostic logs** — connection state, errors, byte counters. Kept on-device, can be cleared by the user from the app's Logs screen at any time.
- **App preferences** — theme, language, auto-reconnect toggle, split-routing rules. Stored on-device only.

### Sent over the network

Only the **encrypted traffic the user is intentionally routing through the VPN tunnel**. The app does not send any data of its own to any server. There are no analytics endpoints, no telemetry pings, no crash reporting backends, no advertising trackers integrated.

### Sent to GhostStream developers

**Nothing.** The developers have no servers that collect data from users.

## Encryption

All data between the user's device and the VPN endpoint is encrypted with **TLS 1.3 with mutual TLS authentication** (mTLS). The user controls both endpoints of the encryption — there is no shared service that could decrypt the traffic in transit.

## Permissions

| Android permission | Why GhostStream needs it |
|---|---|
| `BIND_VPN_SERVICE` | Required by Android to establish a VPN tunnel. This is the core function of the app. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keeps the VPN connection alive while the device screen is off; standard pattern for VPN apps. |
| `ACCESS_NETWORK_STATE` | Detects Wi-Fi ↔ mobile transitions to automatically reconnect the tunnel. No network metadata is logged or transmitted. |
| `POST_NOTIFICATIONS` | Displays the persistent VPN status notification (connection state, bytes transferred). |
| `RECEIVE_BOOT_COMPLETED` | Optional — enables auto-start of the VPN on device boot if the user enabled this in settings. |

The app does **not** request, and does not need:
- Contacts, calendar, SMS, microphone, camera (except for QR-code scanning of connection strings, which never leaves the device)
- Location
- Access to device files outside its own sandbox
- Read access to other apps' data

## Children

The app is not directed at children and does not collect data from anyone, including children.

## Third parties

The app does not integrate any third-party SDK. No Firebase, no Crashlytics, no Google Analytics, no Facebook SDK, no advertising network, no attribution service.

## Changes to this policy

If this policy changes, the new version will be published at the same URL. Previous versions remain accessible in the git history of the project repository.

## Open source

GhostStream is open source. The full source code is available at:
https://github.com/PatrickRedStar/phantom-vpn

You can verify all claims in this policy by reading the source code.

## Contact

For privacy questions: **peterkurkin1@gmail.com**
