# Memory Index

- [user_goals.md](user_goals.md) — User requirements: speed, stealth, infrastructure, constraints (no CDN)
- [research_dpi_evasion_2026.md](research_dpi_evasion_2026.md) — DPI evasion research: TSPU capabilities, VLESS/Reality internals, performance techniques, emerging threats
- [optimization_history.md](optimization_history.md) — Complete record of all optimizations: successes, failures, lessons learned, v13 speed push, H2 benchmarks (v0.15.2: 44.7/36.7 Mbps), known issues
- [feedback_build_local.md](feedback_build_local.md) — All builds must happen locally, server only for deploying binaries
- [feedback_version_sync.md](feedback_version_sync.md) — Always update versionCode/versionName in build.gradle.kts when tagging

## TSPU & Transport
- [tspu_quic_throttling.md](tspu_quic_throttling.md) — TSPU throttles QUIC ~80Mbps on consumer, SNI-IP verification, TCP not throttled (567Mbps)
- [v2_transport_plan.md](v2_transport_plan.md) — HTTP/2 transport plan: phases, key decisions, deps (h2, tokio-rustls)

## Multi-Agent System
- [agents/ORCHESTRATION.md](agents/ORCHESTRATION.md) — Схема запуска агентов, naming convention, стандартные промпты
- [agents/architect.md](agents/architect.md) — Архитектор: константы, JNI контракт, wire format
- [agents/secretary.md](agents/secretary.md) — Секретарь: memory, tasks, CHANGELOG
- [agents/validator.md](agents/validator.md) — Валидатор: cargo check, JNI сигнатуры
- [agents/dev_server.md](agents/dev_server.md) — Dev-Server: crates/server/
- [agents/dev_linux.md](agents/dev_linux.md) — Dev-Linux: crates/client-linux/
- [agents/dev_android.md](agents/dev_android.md) — Dev-Android: android/ + crates/client-android/
