---
name: Orchestration Guide
description: How to invoke multi-agent system for GhostStream development
type: reference
---

# Оркестрация GhostStream Multi-Agent System

## Агенты и их файлы

| Агент | Файл | Зона ответственности |
|-------|------|----------------------|
| Архитектор | agents/architect.md | cross-crate API, wire format, JNI контракт |
| Секретарь | agents/secretary.md | memory, tasks, CHANGELOG |
| Валидатор | agents/validator.md | cargo check, JNI сигнатуры, сборка |
| Dev-Server | agents/dev_server.md | crates/server/ |
| Dev-Linux | agents/dev_linux.md | crates/client-linux/ |
| Dev-macOS | agents/dev_macos.md | crates/client-macos/ |
| Dev-Android | agents/dev_android.md | android/ + crates/client-android/ |

## Как загружать агента

В начале каждого Agent-промпта добавлять:
```
Прочитай файл роли: /home/spongebob/.claude/projects/-home-spongebob-project-ghoststream/memory/agents/<agent>.md
Прочитай контекст проекта: /home/spongebob/project/ghoststream/CLAUDE.md
Работай строго в рамках своей зоны ответственности.
```

## Схема запуска задачи

### Задача затрагивает один компонент
```
1. [Архитектор] — проверить риски и выдать план
2. [Dev-X] — реализовать в worktree
3. [Валидатор] — проверить
4. [Секретарь] — обновить задачи и память
```

### Задача затрагивает несколько компонентов (например, новая JNI функция)
```
1. [Архитектор] — план: что меняется в Rust, что в Kotlin
2. ПАРАЛЛЕЛЬНО (worktree изоляция):
   - [Dev-Android JNI] → crates/client-android/src/lib.rs
   - [Dev-Android UI]  → android/ Kotlin код
3. [Валидатор] — проверить оба worktree
4. merge + [Секретарь]
```

### Параллельный запуск разных компонентов
```
Одновременно (независимые задачи):
- [Dev-Server]  worktree A
- [Dev-Android] worktree B
- [Dev-Linux]   worktree C
```

## Worktree naming convention
```
feature/server-<краткое-описание>
feature/android-<краткое-описание>
feature/linux-<краткое-описание>
feature/macos-<краткое-описание>
feature/jni-<краткое-описание>
```

## Стандартный промпт для запуска агента
```
Ты — [Роль] GhostStream VPN проекта.
Прочитай свою роль: [путь к файлу роли]
Прочитай CLAUDE.md: /home/spongebob/project/ghoststream/CLAUDE.md

Задача: [описание задачи]

Работаешь ТОЛЬКО в своей зоне ответственности.
Не меняй файлы вне своей зоны без явного указания.
В конце верни: список изменённых файлов + краткое описание что сделал.
```

## Выполненные задачи
- [x] Android: Jetpack Compose + Material 3 UI
- [x] Android: nativeGetStats() / nativeGetLogs() JNI
- [x] Android: настраиваемые DNS серверы (пресеты + кастомные)
- [x] Android: QR-сканер (CameraX + ML Kit)
- [x] Android: ребрендинг → com.ghoststream.vpn
- [x] Android: vpnInterface fd management (dup() вместо detachFd)
- [x] Android: таймер сессии + 4 карточки статистики
- [x] Все платформы: base64 connection string авторизация (v0.7.0)
- [x] Сервер: fingerprint-based client allowlist + SIGHUP hot-reload (v0.6.1)
- [x] Android: IP-based split routing + per-app VPN (v0.5.0)

## Текущие задачи (обновлять через Секретаря)
(пусто — ожидает новых задач от пользователя)
