# Privacy Policy — GhostStream VPN

**Last updated:** April 22, 2026

## Overview

GhostStream VPN ("the App") is a personal VPN application. We are committed to protecting your privacy and do not collect, store, or share any personal data.

## Data Collection

The App does **not** collect, transmit, or store:

- Personal information (name, email, phone number)
- Usage analytics or telemetry
- Advertising identifiers
- Browsing history or DNS queries
- IP addresses of users
- Location data

## Permissions

The App requests the following Android permissions:

- **VPN Service (`android.permission.BIND_VPN_SERVICE`)** — required to establish a VPN tunnel. All traffic is encrypted and routed through the VPN server. No traffic is logged.
- **Camera (`android.permission.CAMERA`)** — used solely to scan QR codes for connection configuration. No images are stored or transmitted.
- **Internet (`android.permission.INTERNET`)** — required to establish the VPN connection.
- **Foreground Service (`android.permission.FOREGROUND_SERVICE`)** — required to keep the VPN connection active.

## VPN Server

The VPN server does not log user traffic, connection timestamps, or IP addresses. The server uses mutual TLS (mTLS) authentication with per-client certificates for security, but does not retain connection metadata.

## Third-Party Services

The App does not integrate any third-party analytics, advertising, or tracking services.

## Data Security

All traffic between the App and the VPN server is encrypted using TLS 1.3 with mutual certificate authentication. No shared secrets are used.

## Children's Privacy

The App is not directed at children under 13 and does not knowingly collect data from children.

## Changes

We may update this Privacy Policy from time to time. Changes will be posted in this document with an updated date.

## Contact

If you have questions about this Privacy Policy, please open an issue at:
https://github.com/PatrickRedStar/phantom-vpn/issues
