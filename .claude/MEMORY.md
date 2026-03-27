# Memory Index

- [user_goals.md](user_goals.md) — User requirements: speed, stealth, infrastructure, constraints (no CDN)
- [research_dpi_evasion_2026.md](research_dpi_evasion_2026.md) — DPI evasion research: TSPU capabilities, VLESS/Reality internals, performance techniques, emerging threats
- [optimization_history.md](optimization_history.md) — Complete record of all optimizations: successes, failures, lessons learned, architecture bottleneck analysis
- [feedback_build_local.md](feedback_build_local.md) — All builds must happen locally, server only for deploying binaries
- [feedback_version_sync.md](feedback_version_sync.md) — Always update versionCode/versionName in build.gradle.kts when tagging; "О приложении" reads BuildConfig.VERSION_NAME

- [macos_ui_migration.md](macos_ui_migration.md) — macOS UI migration plan: apply VPN_UI.html design to SwiftUI after Android v0.12.0

## Multi-Agent System
- [agents/ORCHESTRATION.md](agents/ORCHESTRATION.md) — Схема запуска агентов, naming convention, стандартные промпты
- [agents/architect.md](agents/architect.md) — Архитектор: константы, JNI контракт, wire format
- [agents/secretary.md](agents/secretary.md) — Секретарь: memory, tasks, CHANGELOG
- [agents/validator.md](agents/validator.md) — Валидатор: cargo check, JNI сигнатуры
- [agents/dev_server.md](agents/dev_server.md) — Dev-Server: crates/server/
- [agents/dev_linux.md](agents/dev_linux.md) — Dev-Linux: crates/client-linux/
- [agents/dev_macos.md](agents/dev_macos.md) — Dev-macOS: crates/client-macos/
- [agents/dev_android.md](agents/dev_android.md) — Dev-Android: android/ + crates/client-android/
