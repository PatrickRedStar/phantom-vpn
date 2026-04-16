# GhostStream iOS UI Engineering Spec

**Purpose:** Pixel-perfect port from Android (Compose) to iOS (SwiftUI). This document is self-contained and requires no reference to Android code.

**Document Version:** 1.0  
**Target:** Swift/SwiftUI developer unfamiliar with the Android codebase  
**Word Count Target:** ~4500 words

---

## 1. Design System & Theme

### 1.1 Color Palette

**Dark Mode (Default)**

| Role | Hex | Purpose |
|------|-----|---------|
| `bg` | `#0A0908` | Primary background (warm near-black) |
| `bgElev` | `#12110E` | Elevated surface (cards, dialogs) |
| `bgElev2` | `#17150F` | Secondary elevation (layers within cards) |
| `hair` | `#2A2619` | Hairline borders (1px dividers) |
| `hairBold` | `#3D3828` | Bold divider borders |
| `bone` | `#E8E2D0` | Primary text color (warm cream) |
| `textDim` | `#948A6F` | Secondary text (labels, hints) |
| `textFaint` | `#5A5240` | Tertiary text (meta labels, timestamps) |
| `signal` | `#C4FF3E` | Accent (connected state, positive actions) — phosphor lime |
| `signalDim` | `#4A6010` | Muted accent (dimmed/inactive state) |
| `warn` | `#FF7A3D` | Warning state (cathode orange) |
| `danger` | `#FF4A3D` | Error/critical state (red) |

**Light Mode ("Daylight Palette")**

| Role | Hex | Purpose |
|------|-----|---------|
| `bg` | `#F1ECDC` | Primary background (warm paper) |
| `bgElev` | `#E8E2D0` | Elevated surface |
| `bgElev2` | `#DDD6C2` | Secondary elevation |
| `hair` | `#CBC3AD` | Hairline borders |
| `hairBold` | `#B5AD96` | Bold dividers |
| `bone` | `#16130C` | Primary text (ink) |
| `textDim` | `#5A5240` | Secondary text |
| `textFaint` | `#948A6F` | Tertiary text |
| `signal` | `#4A6010` | Accent (moss green) |
| `signalDim` | `#7A9B30` | Muted accent |
| `warn` | `#D4600A` | Warning (dark orange) |
| `danger` | `#CC3322` | Error (darker red) |

**Theme Switching:**
- Read `PreferencesStore.theme`: `"dark"` | `"light"` | `"system"` | `null`
- If `"system"`, respect `UITraitCollection.current.userInterfaceStyle`
- Apply to entire app via custom `Environment` key in SwiftUI

### 1.2 Typography

**Three Font Families:**

1. **Space Grotesk** (Bold weight) — headlines, titles, brand
2. **JetBrains Mono** (Regular, Medium) — body text, logs, addresses, numeric values
3. **Departure Mono** (Regular) — ALL-CAPS labels, small mono text, nav items

**Named Text Styles:**

| Style | Font | Weight | Size | Letter-Spacing | Line Height | Purpose |
|-------|------|--------|------|-----------------|-------------|---------|
| `brand` | Space Grotesk | Bold | 22sp | -0.02em | auto | Top-left brand text |
| `specTitle` | Space Grotesk | Bold | 42sp | -0.02em | auto | Large section titles |
| `stateHeadline` | Space Grotesk | Bold | 54sp | -0.035em | 56sp | VPN state (TRANSMITTING/TUNING/LOST) |
| `profileName` | Space Grotesk | Bold | 18sp | -0.01em | auto | Profile card name |
| `clientName` | Space Grotesk | Bold | 17sp | -0.01em | auto | Admin client name |
| `statValue` | Space Grotesk | Bold | 24sp | -0.01em | 24sp | Numeric stat display (Mbps, bytes) |
| `hint` | Space Grotesk | Normal | 22sp | -0.01em | auto | Large hint text |
| `labelMono` | Departure Mono | Normal | 10.5sp | +0.18em | auto | Main mono label (chip, nav) |
| `labelMonoSmall` | Departure Mono | Normal | 10sp | +0.15em | auto | Smaller mono label |
| `labelMonoTiny` | Departure Mono | Normal | 9.5sp | +0.14em | auto | Tiny mono label |
| `hdrMeta` | Departure Mono | Normal | 10.5sp | +0.12em | auto | Header metadata (right-aligned) |
| `ticker` | Departure Mono | Normal | 26sp | +0.04em | auto | Timer display (session duration) |
| `valueMono` | Departure Mono | Normal | 11sp | +0.08em | auto | Mono value in KV pairs |
| `chipText` | Departure Mono | Normal | 10.5sp | +0.12em | auto | Log filter chip text |
| `navItem` | Departure Mono | Normal | 10sp | +0.14em | auto | Bottom nav label (tiny) |
| `fabText` | Departure Mono | Medium | 11sp | +0.20em | auto | FAB button text |
| `body` | JetBrains Mono | Normal | 12sp | 0 | auto | Body text, general reading |
| `bodyMedium` | JetBrains Mono | Normal | 11.5sp | 0 | auto | Slightly smaller body |
| `kvValue` | JetBrains Mono | Normal | 11sp | 0 | auto | Key-value pair values |
| `host` | JetBrains Mono | Normal | 10sp | 0 | auto | Hostname/IP address |
| `logTs` | JetBrains Mono | Normal | 9sp | 0 | auto | Log entry timestamp |
| `logLevel` | Departure Mono | Normal | 9.5sp | +0.12em | auto | Log level badge (ERR, WRN, etc.) |
| `logMsg` | JetBrains Mono | Normal | 10.5sp | 0 | 16sp | Log message body (multi-line) |

**Conversion Note:** `sp` (scale-independent pixels) in Android ≈ `pt` in iOS after device-scale normalization. Letter-spacing is in `em` units (relative to font size).

---

## 2. Navigation & App Structure

### 2.1 Root Navigation

**Entry Point:** `MainActivity` → `GhostStreamTheme()` → `AppNavigation()`

**Tab-Based Interface:**
- 3-tab HorizontalPager (swipeable)
- Bottom floating nav bar (Capsule-shaped, animated)
- Tabs: Dashboard (◉), Logs (▤), Settings (⚙)

**Modal Routes (overlaid on tabs):**
- `qr_scanner` — QR camera for importing connection strings or pairing
- `qr_scanner_pair/{profileId}` — QR camera for TV pairing specific profile
- `tv_pairing` — Receive pairing from TV
- `admin/{profileId}` — Admin console for a profile (if `cachedIsAdmin == true`)
- `admin_root` — Admin console for default/first admin profile

**Data Flow from Modals:**
- QR result → `savedStateHandle.set("qr_result", qrText)` → passed back to Settings screen
- TV pairing result → `savedStateHandle.set("pair_qr_result", "profileId|||qrText")`
- Return to tabs: Settings tab auto-scrolls to page 2 if QR result pending

### 2.2 Bottom Navigation

**Component:** `GhostBottomNav`
- Compact floating pill (auto-width based on tab count, ~80dp per tab)
- Animated sliding background indicator (lime green signal color, 10% opacity)
- Animated glyph scale on active tab (1.05x)
- Label fades on inactive (0.55 alpha)
- Semi-transparent background with gradient fade (transparent → dark) behind
- Positioned above bottom inset (respects safe area)

---

## 3. Core Screens

### 3.1 Dashboard Screen

**State Variables:**
```swift
vpnState: StateFlow<VpnState>          // Disconnected | Connecting | Connected | Error | Disconnecting
stats: StateFlow<VpnStats>              // bytesRx, bytesTx, pktsRx, pktsTx, elapsedSecs
timerText: StateFlow<String>            // "HH:MM:SS" formatted session duration
subscriptionText: StateFlow<String?>    // e.g., "Подписка: 5д 3ч" or "Подписка истекла ⚠"
preflightWarning: StateFlow<String?>    // e.g., "Certificates not found" — dismissible
```

**Layout (Top-to-Bottom):**

1. **Screen Header**
   - Left: Brand text "STREAM" (Space Grotesk, 22sp, bone color)
   - Right: Header meta with pulsing dot if Connected or Connecting
   - Meta text: `"{serverName} · {timerText}"` (Connecting), `"standby"` (Disconnected), `"error"` (Error)
   - Pulsing lime dot on right (1.6s cycle: 1f → 0.25f alpha)

2. **VPN State Section** (Padding: 22dp horiz, 16dp vert + 12dp top)
   - Label: "TUNNEL STATE" (labelMono, textFaint)
   - Large animated headline (stateHeadline style, 54sp)
     - **Connected:** "TRANSMITTING·" in bone, final word in signal lime
     - **Connecting/Disconnecting:** "TUNING···" in bone, word in warn orange
     - **Error:** "LOST SIGNAL·" in bone, word in danger red
     - **Disconnected:** "STANDBY·" in bone, word in textDim gray
   - AnimatedContent transition: fade + slideInVertically (1/3 offset)

3. **Timer & Session Label Row** (Padding: 22dp horiz, 14dp bot, vertical spacing)
   - Left: Timer text (ticker style, 26sp mono)
     - Connected: formatted elapsed time "HH:MM:SS" (bone color)
     - Disconnected: "--:--:--" (textFaint)
   - Right: "SESSION" label (labelMonoSmall, textFaint)

4. **Empty State Hint** (if no active profile + Disconnected)
   - Box with bgElev background, hair border, 14dp padding
   - Text: "Add a connection string from Settings" (body, textDim)

5. **Preflight Warning** (if present)
   - Background: danger color @ 10% alpha
   - Text: warning message (kvValue, danger color)
   - Dismissible via button

6. **Scope Card** (GhostCard)
   - Header row:
     - Left: RX / TX values with colored lines
       - RX: signal (lime) 2dp × 14dp line + value (kvValue)
       - TX: warn (orange) 2dp × 14dp line + value (kvValue)
     - Right: Scope window label (hdrMeta, textFaint) — clickable to cycle 1m → 5m → 30m → 1h
   - Divider (hair color, 1dp height)
   - **ScopeChart:** Canvas with oscilloscope-style RX/TX traces
     - 3 horizontal grid lines (hair, 0.5f stroke)
     - RX trace: lime (signal) with glow + fill gradient
     - TX trace: orange (warn) with glow, no fill
     - Samples normalized to max of both RX/TX

7. **Mux Streams Card** (GhostCard)
   - Header row:
     - Left: "STREAM MULTIPLEX" (hdrMeta, textDim)
     - Right: "8/8 STREAMS" or similar (hdrMeta, signal)
   - Divider (hair)
   - **MuxBars:** 8 animated bars, shimmer every 700ms while connected
     - Bar height normalized 0..1, gradient from signal (top) to signalDim (bottom)
     - Gap 4f between bars, fills width

8. **KV Card** (GhostCard) — Profile metadata
   - Rows separated by dashed hairlines:
     - IDENTITY → profile.name (kvValue, bone)
     - ASSIGNED → profile.tunAddr (kvValue, bone)
     - SUBSCRIPTION → subscriptionText (kvValue, color depends on text: bone if OK, danger if expired)

9. **Bottom Spacer** + **FAB Bar** (18dp horiz padding)
   - **GhostFab** button
     - Connected/Connecting/Disconnecting: "DISCONNECT" (filled, signal lime)
     - Disconnected: "CONNECT" (outline, signal lime border)
     - Click → startVpn() or stopVpn()
   - Spacer: 80dp (bottom safe area)

**ViewModel Methods:**
- `startVpn()` — Request VPN permission (Android: VpnService.prepare), then launch foreground service with config
- `stopVpn()` — Send stop intent to service
- `dismissPreflightWarning()` — Clear warning banner

**Side Effects:**
- Timer polls every 1s when Connected (updates timerText)
- Stats poll every 1s from native layer (updates RX/TX buffers)
- Mux bars animate every 700ms while Connected
- Subscription info fetched on first connect (mTLS call to /api/clients)

---

### 3.2 Logs Screen

**State Variables:**
```swift
logs: StateFlow<List<LogEntry>>    // Reversed order (newest first)
filter: StateFlow<String>          // "ALL" | "TRACE" | "DEBUG" | "INFO" | "WARN" | "ERROR"
```

**LogEntry:**
```
seq: Long
timestamp: String       // "YYYY-MM-DD HH:MM:SS" or "HH:MM:SS"
level: String          // "TRACE" | "DEBUG" | "INFO" | "WARN" | "ERROR" | "OK"
message: String        // Log text
```

**Layout:**

1. **Screen Header**
   - Brand: "TAIL" (bone, Space Grotesk Bold, 22sp)
   - Meta: "LIVE · {log_count} LINES" (with pulsing dot) — e.g., "LIVE · 1.2k LINES"

2. **Filter Chip Row** (Horizontal scroll)
   - Padding: 16dp horiz, 10dp vert
   - Chips: ALL, TRACE, DEBUG, INFO, WARN, ERROR, SHARE
   - Active chip: filled lime (signal), text lime
   - Inactive chip: textDim text, no fill
   - Spacing: 6dp between chips
   - SHARE chip: accent color (lime), triggers shareLogs()

3. **Log List** (LazyColumn, reversed layout)
   - Each LogEntry renders as LogEntryRow
   - Reversed: newest at top (index 0)
   - Content padding: 16dp start/end, 8dp top, 80dp bottom
   - Auto-scroll to top when new logs arrive (animateScrollToItem(0))

4. **LogEntryRow** (One row per log)
   - Vertical padding: 2dp
   - Layout (Row):
     - Timestamp (logTs style, 54dp width): "HH:MM:SS"
     - Level badge (labelMono, 32dp width): "ERR" | "WRN" | "INF" | "DBG" | "TRC"
       - Color by level: ERROR → danger, WARN → warn, INFO → textDim, DEBUG → blueDebug (#6C8BA8), TRACE → textFaint
     - Spacer: 4dp
     - Message (logMsg style, textFaint, multi-line, fillMaxWidth)
   - Top alignment (logs may wrap to multiple lines)

5. **Fade-Out Overlay** (Bottom 50dp)
   - Gradient: transparent → bg (warm black)
   - Prevents bottom nav from obscuring last logs

**ViewModel Methods:**
- `setFilter(level: String)` — Update filter & native log level via nativeSetLogLevel()
- `shareLogs(context)` — Export all logs to text file, launch share intent
- `copyEntry(context, entry)` — Copy one log line to clipboard
- `copyAll(context)` — Copy all visible logs to clipboard
- `clearLogs()` — Wipe log buffer

**Side Effects:**
- Polls nativeGetLogs() every 500ms, stores last seq, appends new entries
- Filters by level (LEVEL_ORDER: TRACE < DEBUG < INFO < WARN < ERROR)

---

### 3.3 Settings Screen

**State Variables:**
```swift
profiles: StateFlow<List<VpnProfile>>
activeProfileId: StateFlow<String?>
config: StateFlow<VpnConfig>           // Merged active profile + global prefs
pingResults: StateFlow<Map<String, Int?>>    // profileId → latencyMs
pinging: StateFlow<Set<String>>         // profileIds currently pinging
profileSubscriptions: StateFlow<Map<String, String?>>  // Profile → sub text
autoStartOnBoot: StateFlow<Boolean>
languageOverride: StateFlow<String?>    // "en" | "ru" | null
theme: StateFlow<String>                // "system" | "dark" | "light"
```

**Layout:**

1. **Screen Header**
   - Brand: "SETTINGS"
   - Meta: Version & git tag (e.g., "1.0.0-abc123")

2. **Endpoints Section**
   - Label: "ENDPOINTS · 04" (number of profiles, 2-digit format)
   - ProfileCard for each profile
   - + Add button (dashed card)

3. **ProfileCard** (GhostCard, active variant highlighted)
   - Active card: lime left edge glow (2dp center + 6dp dim outer @ 0.5f, 2dp bright inner)
   - Layout:
     - Top row: name (profileName, bone) | latency (hdrMeta, textDim) or ping spinner
     - Divider
     - Row: serverAddr (kvValue, textDim) | subscription status (kvValue, signal/danger/bone)
   - Click → set active
   - Long-press (if admin) → navigate to admin screen
   - Edit icon → open rename dialog

4. **Routing Section**
   - Label: "ROUTING"
   - SectionCard (GhostCard):
     - **DNS:** Shows "CUSTOM" or list of servers, click to edit
     - **Split Tunnel:** Toggle + subtitle (e.g., "5 countries selected")
     - **Per-App:** Toggle + subtitle (e.g., "20 apps excluded")

5. **Theme & Language Section**
   - **Theme Switch:** Buttons (Dark | Light | System)
   - **Language Switch:** Dropdown (English | Русский)
   - **Auto-Start:** Toggle

6. **Import Dialog** (Modal)
   - Triggered by QR scanner or manual paste
   - Text field: paste connection string (ghs://...)
   - Optional name field
   - Import button: parses, saves cert files, creates profile

---

### 3.4 Admin Screen

**State Variables:**
```swift
status: StateFlow<ServerStatus?>       // uptimeSecs, sessionsActive, serverAddr, exitIp
clients: StateFlow<List<ClientInfo>>   // All client configurations
clientStats: StateFlow<List<StatsSample>>    // per-client RX/TX history
clientLogs: StateFlow<List<DestEntry>>       // per-client DNS/destination logs
error: StateFlow<String?>
newConnString: StateFlow<String?>      // Generated conn string (shows modal if non-null)
```

**ClientInfo:**
```
name: String
tunAddr: String         // Assigned tunnel IP
fingerprint: String     // Client cert fingerprint
enabled: Boolean
isAdmin: Boolean
connected: Boolean      // Currently has active session
bytesRx: Long
bytesTx: Long
createdAt: String
lastSeenSecs: Long
expiresAt: Long?
```

**Layout:**

1. **Screen Header**
   - Brand: profile.serverName or "ADMIN"
   - Meta: "ONLINE · {uptimeSecs_formatted}"

2. **Server Status Card** (GhostCard)
   - Exit IP (kvValue)
   - Active Sessions count
   - Uptime (formatted duration)

3. **Clients List** (LazyColumn)
   - ClientRow for each client
   - Each row:
     - Name (clientName, bone) + fingerprint (host style, textFaint)
     - Divider
     - Stats row: bytesRx/TX (kvValue), connected indicator (pulsing dot if connected)
     - Actions: edit name, toggle enabled, view stats, set expiry, delete (long-press confirms)

4. **Add Client Button** (GhostFab)
   - Dialog: enter name, days (default 30)
   - Confirm → createClient() → shows ConnStringDialog

5. **ConnStringDialog** (Modal)
   - Displays generated ghs:// URL
   - Copy button → clipboard
   - QR code display
   - Share button

6. **Client Details Dialog** (Modal, tap a client)
   - Expandable stats chart (RX/TX over time)
   - Destination log (DNS names, IPs, ports)
   - Scroll through recent activity

**ViewModel Methods:**
- `init(profile, profilesStore)` — Build mTLS client, fetch server status & clients
- `refresh()` — Re-fetch status & client list via /api/server and /api/clients
- `createClient(name, expiryDays)` — POST /api/clients
- `deleteClient(name)` — DELETE /api/clients/{name}
- `toggleEnabled(name, currentEnabled)` — PATCH /api/clients/{name}
- `setExpiry(name, unixTs)` — PATCH /api/clients/{name}

**Admin API Endpoints:**
- `GET /api/me` → `{is_admin: bool}`
- `GET /api/server` → `{uptime_secs, sessions_active, server_addr, exit_ip}`
- `GET /api/clients` → `[{name, tun_addr, fingerprint, enabled, is_admin, connected, bytes_rx, bytes_tx, created_at, last_seen_secs, expires_at}]`
- `GET /api/clients/{name}/stats` → `[{ts, bytes_rx, bytes_tx}]`
- `GET /api/clients/{name}/logs` → `[{ts, dst, port, proto, bytes}]`
- `POST /api/clients` → `{name, tun_addr, cert_pem, key_pem}`
- `PATCH /api/clients/{name}` → `{enabled: bool, expires_at: long}`
- `DELETE /api/clients/{name}` → `{}`

---

## 4. Reusable Components

### 4.1 GhostCard

```swift
// GhostCard(modifier, bg, border, active, content)
// Default bg: bgElev, border: hair
// If active: adds lime left glow (18%–82% of height)
// Border: 1dp rounded corners (6dp)
```

**Visual:**
- Rounded rectangle (6dp corners)
- 1dp border in hair/hairBold color
- Gradient background (active: lime 4% opacity from left, inactive: solid bgElev)
- Left edge glow (if active): 6dp dim outer line (signalDim), 2dp bright center (signal)

### 4.2 GhostFab

```swift
// GhostFab(text, outline, onClick)
// If outline: transparent bg, signal border
// If filled: signal bg, bone text
```

**Visual:**
- Rounded pill shape
- Padding: 16dp horiz, 12dp vert
- Text: fabText style (Departure Mono, Medium, 11sp, +0.2em spacing)
- Tap animation: subtle scale

### 4.3 GhostToggle

Toggle switch with lime on state.

```swift
// GhostToggle(checked, onToggle)
```

### 4.4 GhostChip

Pill-shaped filter button.

```swift
// GhostChip(text, active, onClick, accent)
// Default accent: signal
// If active: filled with accent @ 20%, text accent color
// If inactive: text textDim, no fill
```

### 4.5 ScopeChart

Canvas-based oscilloscope trace.

```swift
// ScopeChart(rxSamples: [Float], txSamples: [Float])
// Height: 90dp, fills width
// RX trace: signal (lime) + fill gradient
// TX trace: warn (orange), no fill
// Grid: 3 horizontal lines @ 25% intervals
```

### 4.6 MuxBars

Animated bar chart (8 bars, 70dp height).

```swift
// MuxBars(heights: [Float])
// Values 0..1, normalized
// Gradient: signal (top) → signalDim (bottom)
// Gap: 4dp between bars
// Animated every 700ms while connected
```

### 4.7 PulseDot

Animated pulsing circle (1.6s cycle).

```swift
// PulseDot(modifier, color, size)
// Default: 5dp, signal lime
// Alpha: 1f → 0.25f (reverse)
```

### 4.8 ScreenHeader

Top fixed header with brand + meta.

```swift
// ScreenHeader(brand: String, meta: @Composable () -> Unit)
// Brand: Space Grotesk Bold 22sp, bone color
// Meta: right-aligned, custom composable (often HeaderMeta + PulseDot)
```

### 4.9 HeaderMeta

Small text + optional pulsing dot.

```swift
// HeaderMeta(text, pulse)
// Text: textFaint color
// Dot: signal lime, pulses if pulse=true
```

### 4.10 DashedHairline

Thin dashed divider (used in KV cards).

```swift
// DashedHairline()
// Height: 1dp, dashes: 4f on / 4f off
```

---

## 5. Data Model & Storage

### 5.1 VpnProfile

```kotlin
data class VpnProfile(
    val id: String,                      // UUID
    val name: String,
    val serverAddr: String,              // host:port
    val serverName: String,              // SNI
    val insecure: Boolean,               // Skip cert verify (rare)
    val certPath: String,                // File path to client cert
    val keyPath: String,                 // File path to client key
    val certPem: String?,                // Inline PEM (survives app updates)
    val keyPem: String?,
    val tunAddr: String,                 // e.g., "10.7.0.2/24"
    // Per-profile overrides (null = use global defaults)
    val dnsServers: List<String>?,
    val splitRouting: Boolean?,
    val directCountries: List<String>?,
    val perAppMode: String?,             // "none" | "allowed" | "disallowed"
    val perAppList: List<String>?,       // Package names
    // Cached admin data
    val cachedExpiresAt: Long?,          // Unix timestamp (ms)
    val cachedEnabled: Boolean?,
    val cachedIsAdmin: Boolean?,
    val cachedAdminServerCertFp: String?, // SHA-256 hex
)
```

### 5.2 PreferencesStore Keys (DataStore)

```
server_addr: String
server_name: String
insecure: Boolean
cert_path: String
key_path: String
tun_addr: String
dns_servers: String            // comma-separated
theme: String                  // "system" | "dark" | "light"
split_routing: Boolean
direct_countries: String       // comma-separated
per_app_mode: String
per_app_list: String           // comma-separated
auto_start_on_boot: Boolean
was_running: Boolean           // Internal: user-intent flag
last_tunnel_params: String     // JSON backup of last started config
language_override: String      // "en" | "ru" | null
```

### 5.3 Connection String Format (ghs://)

```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1

Example:
ghs://LS0tLS1C...@vpn.example.com:6443?sni=vpn.example.com&tun=10.7.0.2%2F24&v=1
```

**Parsing:**
1. Extract base64url userinfo (before @)
2. Decode to PEM (cert + newline + key)
3. Extract host:port, sni, tun from query params
4. Validate: 2 PEM blocks (CERTIFICATE + PRIVATE KEY)

---

## 6. Service Layer & State Management

### 6.1 VpnState (State Machine)

```kotlin
sealed class VpnState {
    object Disconnected
    object Connecting
    data class Connected(val since: Instant, val serverName: String)
    data class Error(val message: String)
    object Disconnecting
}
```

**Transitions:**
- Disconnected → (user taps Connect) → Connecting
- Connecting → (service ready) → Connected
- Connecting → (error) → Error
- Connected → (user taps Disconnect) → Disconnecting
- Disconnecting → Disconnected
- Connected/Connecting → (network loss) → Error
- Error → (user retry or timeout) → Disconnected

### 6.2 GhostStreamVpnService Intent Contract

**Starting the VPN:**
```kotlin
Intent(context, GhostStreamVpnService::class.java).apply {
    action = GhostStreamVpnService.ACTION_START
    putExtra(GhostStreamVpnService.EXTRA_SERVER_ADDR, "vpn.example.com:6443")
    putExtra(GhostStreamVpnService.EXTRA_SERVER_NAME, "vpn.example.com")
    putExtra(GhostStreamVpnService.EXTRA_INSECURE, false)
    putExtra(GhostStreamVpnService.EXTRA_CERT_PATH, "/path/to/client.crt")
    putExtra(GhostStreamVpnService.EXTRA_KEY_PATH, "/path/to/client.key")
    putExtra(GhostStreamVpnService.EXTRA_TUN_ADDR, "10.7.0.2/24")
    putExtra(GhostStreamVpnService.EXTRA_DNS_SERVERS, "8.8.8.8,1.1.1.1")
    putExtra(GhostStreamVpnService.EXTRA_SPLIT_ROUTING, false)
    putExtra(GhostStreamVpnService.EXTRA_DIRECT_CIDRS, "/path/to/cidrs.txt")
    putExtra(GhostStreamVpnService.EXTRA_PER_APP_MODE, "none")
    putExtra(GhostStreamVpnService.EXTRA_PER_APP_LIST, "")
}
context.startForegroundService(intent)
```

**Stopping the VPN:**
```kotlin
Intent(context, GhostStreamVpnService::class.java).apply {
    action = GhostStreamVpnService.ACTION_STOP
}
context.startService(intent)
```

### 6.3 Native Bridge Methods

**From ViewModel/Service:**
```kotlin
GhostStreamVpnService.nativeGetStats(): String?        // JSON: {bytes_rx, bytes_tx, pkts_rx, pkts_tx, connected}
GhostStreamVpnService.nativeGetLogs(lastSeq): String?  // JSON array: [{seq, ts, level, msg}]
GhostStreamVpnService.nativeSetLogLevel(level: String) // "trace" | "debug" | "info" | "warn" | "error"
```

---

## 7. Admin mTLS & API

### 7.1 AdminHttpClient

Builds OkHttp client with:
- Client cert + key from profile PEM files
- Server cert pinned by SHA-256 (TOFU: pin on first handshake)
- Hostname verification disabled (server CN = 10.7.0.1, but we connect to 10.7.0.1)

```kotlin
val outcome = AdminHttpClient.build(
    certPemPath = profile.certPath,
    keyPemPath = profile.keyPath,
    pinnedFp = profile.cachedAdminServerCertFp,  // null on first connect
)
val client = outcome.client
val fpRef = outcome.serverCertFpRef  // Reference to updated fp after handshake
```

**Gateway URL:** Derived from profile.tunAddr (e.g., "10.7.0.2/24" → "10.7.0.1:8080")

### 7.2 Admin API Response Shapes

**GET /api/me**
```json
{
  "is_admin": true,
  "name": "alice",
  "tun_addr": "10.7.0.2/24"
}
```

**GET /api/server**
```json
{
  "uptime_secs": 86400,
  "sessions_active": 5,
  "server_addr": "vpn.example.com:6443",
  "exit_ip": "203.0.113.45"
}
```

**GET /api/clients**
```json
[
  {
    "name": "alice",
    "tun_addr": "10.7.0.2/24",
    "fingerprint": "sha256:abcd...",
    "enabled": true,
    "is_admin": true,
    "connected": true,
    "bytes_rx": 1000000,
    "bytes_tx": 500000,
    "created_at": "2024-01-01T00:00:00Z",
    "last_seen_secs": 30,
    "expires_at": 1735689600
  }
]
```

**POST /api/clients** (request)
```json
{
  "name": "bob",
  "expires_at": 1735689600
}
```

**PATCH /api/clients/{name}**
```json
{
  "enabled": false,
  "expires_at": 1735689600
}
```

---

## 8. Custom UI Behaviors

### 8.1 Scope Window (Dashboard)

Tap the scope label (top-right of scope card) to cycle time window:
- 60s (1m)
- 300s (5m)
- 1800s (30m)
- 3600s (1h)
- Loop back to 60s

Buffers clear when window changes. Samples are rolling delta (bytes/sec).

### 8.2 Profile Ping

Long-press or tap a profile card to ping its serverAddr. Shows latency (green) or error (red). Cached for session.

### 8.3 Theme & Language Persistence

- Theme: PreferencesStore.theme (Flow) → read on each recompose
- Language: PreferencesStore.languageOverride → applied via AppCompatDelegate.setApplicationLocales() before Activities inflated
- Changes take effect immediately (recompose) or require restart (language)

### 8.4 Split Tunnel UI

Toggle split tunnel → shows country picker (FlagEmoji + CountryName). Multiple selection. Loads country lists from disk on Settings startup.

### 8.5 Per-App UI

Toggle per-app → mode picker (All through VPN | Exclude apps | Include apps). Then shows app list with checkboxes (PackageManager installed apps).

---

## 9. Layout Specifics

### 9.1 Spacing & Padding Constants

| Element | Padding | Gap |
|---------|---------|-----|
| Screen content (horiz) | 18–22dp | — |
| Card padding (horiz) | 14dp | — |
| Card padding (vert) | 10dp | — |
| Row spacing | — | 16dp |
| Chip spacing | — | 6dp |
| Section spacing | — | 24dp |
| FAB bottom margin | — | 12dp |
| Bottom nav height | ~56dp | — |
| Scope/Mux card height | 90–70dp | — |

### 9.2 Animations

- **Tab navigation:** Spring (dampingRatio=0.72, stiffness=Medium-Low)
- **Bottom nav pill:** Spring (dampingRatio=0.72)
- **Glyph scale on nav active:** Spring (dampingRatio=0.65, stiffness=Medium)
- **Label fade on nav:** Tween (180ms)
- **State headline:** AnimatedContent fade + slideInVertically (offset = height/3)
- **Mux bars:** Updated every 700ms (not smooth animation, discrete updates)
- **Pulsing dot:** Tween (1600ms, repeat reverse)

---

## 10. Pixel-Perfect Conversion Checklist

For each screen/component, ensure:

- [ ] Font families & weights match exactly (Space Grotesk/JetBrains/Departure)
- [ ] Font sizes in sp converted to pt (roughly 1:1 for standard density)
- [ ] Letterspacings in em preserved (e.g., -0.02em = -20% of font size)
- [ ] Color hex codes exact match (both dark & light modes)
- [ ] Padding/margin values match (in dp → pt conversion, 1dp ≈ 1pt @ 1x)
- [ ] Border radius 6dp on cards
- [ ] Hair dividers 1dp
- [ ] Pulsing dot 1.6s cycle
- [ ] Animated indicators (pill, glyph scale) use same spring/tween specs
- [ ] Bottom nav floating capsule with shadow (12dp elevation)
- [ ] CardModifier active state: left glow (signalDim outer 6dp + signal inner 2dp, 18%–82% height)

---

**End of Specification**

*This document is complete and self-contained. A Swift developer can implement every screen, component, and interaction using only this spec.*
