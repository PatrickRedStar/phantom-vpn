# GhostStream Privacy Policy

**Effective date:** May 1, 2026

GhostStream is a client-only proxy profile and routing utility. The app does not
provide, sell, rent, or operate VPN services, proxy services, or network tunnel
servers. Users connect only with their own GhostStream-compatible server
profile, key, certificate, or connection string.

## Data We Collect

GhostStream does not collect, transmit, sell, rent, or share personal data with
the GhostStream developer.

The app does not collect:

- names, email addresses, phone numbers, or account identifiers;
- browsing history, DNS queries, destination hosts, or network activity logs;
- advertising identifiers, tracking data, analytics, or marketing data;
- precise location, coarse location, contacts, photos, or payment information;
- network traffic contents or metadata for developer-operated processing.

## Local Data Stored On Your Device

GhostStream stores the following data locally so the app can work:

- connection profiles and app preferences in the app container or App Group
  storage;
- client certificates and private keys in the iOS Keychain;
- optional routing rules, including user-created rules and downloaded public
  GeoIP/Geosite presets;
- local runtime status and diagnostic logs shown inside the app.

This local data is not sent to the GhostStream developer. Users can delete
profiles and clear local logs inside the app. Removing the app removes its app
container data according to iOS behavior; Keychain items are managed by iOS and
may be removed by deleting profiles before uninstalling the app.

## Network Connections

When you connect, GhostStream sends traffic only to the server configured in
your own profile. The operator of that server controls how that server handles
traffic and logs. GhostStream does not receive, proxy, inspect, or store that
traffic on developer-operated infrastructure.

If you use an admin-capable profile, the app may request subscription status,
client information, or server diagnostics from that same user-configured server.
Those requests are made directly between your device and your configured server.

If you choose to download routing presets, GhostStream may request public rule
files from GitHub-hosted V2Fly sources. GitHub may receive ordinary request
metadata such as IP address and user agent according to GitHub's own privacy
practices. GhostStream does not add personal profile data to those requests.

## Permissions

GhostStream may request camera access only to scan QR codes containing
connection profiles. Images are not saved or transmitted by GhostStream.

GhostStream uses Apple's Network Extension capability to create a local packet
tunnel according to the profile and routing rules chosen by the user. This is
used only to provide the client utility functionality.

## Third-Party Services

GhostStream does not include third-party analytics, advertising, tracking, or
crash-reporting SDKs.

The app may use platform services provided by Apple, such as TestFlight, App
Store distribution, iCloud device backups if enabled by the user, and iOS system
networking. Those services are governed by Apple's terms and privacy policy.

## Debug Reports And Sharing

GhostStream can generate local diagnostic information to help troubleshoot a
connection. Debug reports are created on the device and are shared only if the
user explicitly chooses to export or share them through the iOS share sheet.
Users should review exported files before sending them to anyone.

## Data Retention And Deletion

Because GhostStream does not collect user data on developer-operated systems,
there is no server-side user data for the GhostStream developer to delete.
Local profiles, keys, preferences, routing rules, and logs remain on the device
until the user deletes them in the app or removes the app, subject to iOS
Keychain and backup behavior.

## Children's Privacy

GhostStream is not directed to children and does not knowingly collect personal
information from children.

## Changes To This Policy

This policy may be updated when GhostStream changes how it handles data. The
latest version will be posted at the public Privacy Policy URL used in App Store
Connect.

## Contact

Questions about this policy can be opened at:
https://github.com/PatrickRedStar/phantom-vpn/issues
