---
name: Orchestration Guide
description: How to invoke multi-agent system for GhostStream development
type: reference
---

# Оркестрация GhostStream Multi-Agent System

**Для крупных задач (>5 файлов или ≥3 независимых файловых зон) — всегда использовать
параллельных субагентов.** См. CLAUDE.md → "Мульти-агентный workflow".

## Агенты и их зоны

| Агент | Файл роли | Зона ответственности |
|-------|-----------|----------------------|
| Architect | agents/architect.md | cross-crate API, wire format, JNI контракт (только чтение) |
| Secretary | agents/secretary.md | memory, tasks, CHANGELOG |
| Validator | agents/validator.md | cargo check, JNI сигнатуры, сборка |
| Dev-Server | agents/dev_server.md | crates/server/ |
| Dev-Linux | agents/dev_linux.md | crates/client-linux/ (CLI) |
| Dev-Linux-GUI | agents/dev_linux_gui.md | apps/linux-gui/ (Slint/GTK4) |
| Dev-Android | agents/dev_android.md | android/ + crates/client-android/ |
| Dev-macOS-GUI | agents/dev_macos_gui.md | apps/macos/ + crates/client-macos/ (SwiftUI + NEPacketTunnelProvider) |
| Dev-Windows-GUI | agents/dev_windows_gui.md | apps/windows/ + crates/client-windows/ (Slint/WinUI3 + Wintun) |

## Как запускать параллельно

**Критически важно:** несколько `Agent` блоков в одном сообщении = параллель. Серия
вызовов = медленнее в N раз. Non-overlapping файловые зоны обязательны (иначе
merge conflicts).

### Пример для крупной задачи (v0.19.4)

Один tool-call с 4 параллельными блоками:
```
Agent(subagent_type="Dev-Server",       prompt="...crates/server/...")
Agent(subagent_type="general-purpose",  prompt="...crates/core/ + client-common/...")
Agent(subagent_type="Dev-Android",      prompt="...android/ + client-android/...")
Agent(subagent_type="general-purpose",  prompt="...docs + config + scripts...")
```

После merge — главный агент:
1. Прогоняет `cargo check --workspace` и `cargo test`
2. Фиксит cross-crate compile errors (субагенты их пропускают)
3. Деплоит бинарь, поднимает systemd unit
4. Обновляет CHANGELOG + memory

### Задача на один компонент

```
1. [Architect] (опционально) — проверить риски, выдать план
2. [Dev-X] — реализовать
3. [Validator] — cargo check, тесты
4. [Secretary] — обновить CHANGELOG / memory
```

Для мелких правок (1 файл, <50 строк) — субагенты не нужны, делать инлайн.

## Стандартный промпт для агента

Subагенты **не видят беседы** — всё в prompt:

```
Ты — [Роль] GhostStream VPN проекта.
Прочитай свою роль: .claude/agents/<role>.md
Прочитай CLAUDE.md: /opt/github_projects/phantom-vpn/CLAUDE.md

Контекст: [что уже сделано, что сломано, что надо]
Задача:   [точные файлы + строки + что изменить + что проверить]

Работаешь ТОЛЬКО в своей зоне. Не меняй файлы вне зоны без явного указания.
В конце верни: список изменённых файлов + краткое описание.
```

## Выполненные крупные вехи

- [x] v0.19.4 — удалён весь QUIC stack (−870 строк), 4 bug fixes, renaming QuicConfig→TlsConfig
- [x] v0.18.0 — mimicry warmup, fakeapp, multi-stream handshake negotiation
- [x] v0.17.2 — parallel per-stream batch loops (138→625 Mbit/s)
- [x] v0.17.0 — H2/TLS multi-stream, nginx SNI-passthrough relay
- [x] v0.15 — первый H2+TLS transport
- [x] Android: com.ghoststream.vpn ребрендинг, Jetpack Compose UI, admin panel, QR scanner
- [x] Connection string `ghs://` URL-формат (v0.19+, legacy base64-JSON отвергается)

## Текущие приоритеты

См. `memory/project_v019_priorities.md`:
- Priority 1 Stealth: detection vectors 11/13 (timing jitter, connection migration)
- Priority 2 UX: Android Clone profile
- Priority 3 Research: buffer pool, telemetry endpoint
