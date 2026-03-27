---
name: macOS UI Migration Plan
description: Plan to apply new GhostStream HTML design (VPN_UI.html) to macOS SwiftUI app
type: project
---

## macOS UI Migration Plan (after Android is done)

**Why:** New global UI release based on HTML mockup at `/home/spongebob/Загрузки/VPN_UI.html`. Android done first.

**How to apply:** Implement after Android v0.12.0 is merged and tested.

### Current macOS structure
```
phantom-vpn-macos/Sources/PhantomVPN/Views/
  ContentView.swift      — MenuBarExtra root, tab switcher
  ConnectionTab.swift    — Main connection view
  ProfilesTab.swift      — Profile management
  LogsTab.swift          — Rust log viewer
  AdminPanelView.swift   — Admin HTTP API
  SubscriptionView.swift — Subscription status
```

### Target design (from HTML mockup)

**ContentView.swift:**
- Remove bottom tab bar → single-screen with ghost mascot + cubes
- Colors: bg `#090B16`, accent `#7C6AF7`, teal `#22D3A0`
- MenuBarExtra window: ~360×780 equivalent (or menu bar proportioned)

**ConnectionTab.swift → rewrite as main view:**
- Ghost mascot (ghost_mascot.webp) as clickable connect/disconnect
- Connected: float animation (translateY 0→-7), glow radial (teal #22D3A0)
- Connecting: ring spin + breathe scale animation, blue glow (#60A5FA)
- Disconnected: dim (opacity 0.78), grayscale
- ConnectionPill below ghost (green/blue/gray pill with animated dot)
- State hint text when disconnected
- Timer (monospace, always visible, dim when disconnected)
- ServerCard: flag emoji + host + subscription · QUIC
- Stats 2×2: Download (cyan icon), Upload (violet), Session (orange), Packets (teal)
- Cubes 2×2: Logs cube (blue), Settings cube (purple)

**Navigation:**
- No tab bar — Logs and Settings open as SwiftUI sheets
- `.sheet(isPresented: $showLogs)` → LogsTab content
- `.sheet(isPresented: $showSettings)` → ProfilesTab + settings content
- Admin accessible from Settings sheet → AdminPanelView as nested sheet

**ProfilesTab.swift → SettingsSheet:**
- Section "Подключения": profile list with ping badges, QR/Admin/Delete buttons
- Section "DNS": presets (Google/Cloudflare/AdGuard/Quad9) + badge
- Section "Сеть": insecure toggle
- Section "Маршрутизация": split routing toggle
- Section "Оформление": dark/light/auto theme picker
- Section "Поддержка": debug share button

**LogsTab.swift → LogsSheet:**
- Same content, now appears as sheet over main view
- Filter chips: ALL/TRACE/DEBUG/INFO/WARN

**Flag emoji:**
- Use `https://ipinfo.io/{ip}/country` (free HTTPS API)
- Convert 2-letter code to emoji: regional indicator symbols
- Cache in UserDefaults per IP

**Color constants (Swift):**
```swift
static let pageBg = Color(hex: "090B16")
static let accentPurple = Color(hex: "7C6AF7")
static let accentTeal = Color(hex: "22D3A0")
static let blueDebug = Color(hex: "60A5FA")
static let cardBg = Color.white.opacity(0.05)
static let cardBorder = Color.white.opacity(0.09)
static let textPrimary = Color(hex: "F0EFFF")
static let textSecondary = Color(hex: "F0EFFF").opacity(0.6)
static let textTertiary = Color(hex: "F0EFFF").opacity(0.35)
static let statDl = Color(hex: "06B6D4")
static let statUl = Color(hex: "8B5CF6")
static let statSe = Color(hex: "FB923C")
static let statPk = Color(hex: "22D3A0")
```

### Key challenges for macOS
- MenuBarExtra window sizing (fixed width ~360dp)
- SwiftUI sheet presentation inside MenuBarExtra window
- Ghost mascot animation with SwiftUI Animation (.easeInOut repeatForever)
- Country flag via URLSession async/await (same ipinfo.io endpoint)
