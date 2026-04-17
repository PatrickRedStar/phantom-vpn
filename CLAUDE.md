# GhostStream / PhantomVPN — Claude Code Instructions

## Что это

Кастомный VPN-протокол, маскирующий трафик под обычный HTTPS. Проектировался для
России и стран с TSPU / активным DPI. Транспорт — **HTTP/2 поверх TLS 1.3 поверх TCP**
с мульти-стрим шардингом и mTLS.

| Платформа | Статус |
|---|---|
| Android (Kotlin + Compose) | ✅ Production |
| iOS (SwiftUI + NEPacketTunnelProvider) | ✅ Production |
| Linux (CLI + Slint GUI) | ✅ Production |
| OpenWrt (netifd + LuCI) | ✅ Production |
| Server (NL exit + RU SNI-passthrough relay) | ✅ Production |

## Что я хочу получить на выходе

- **Стабильный VPN-сервис.** Клиенты не отваливаются при переключении сетей, не требуют ручного reconnect.
- **Обход DPI.** Трафик неотличим от обычного HTTPS (SNI, нет UDP, H264-like bursts).
- **End-to-end приватность.** mTLS per client, нет общих secret'ов, нет backdoor.
- **Один Rust core на все платформы** (`client-core-runtime`) — максимум переиспользования.
- **Минимальные diff'ы** при изменениях. Не рефакторить ради рефакторинга. Не городить feature flags под гипотетические сценарии.
- **Всё важное задокументировано.** Архитектурные решения → ADR. Инциденты → постмортем.
- **Чистые релизы.** Android versionCode монотонный, тег `vX.Y.Z` → GitHub Release auto.

## Структура (высокоуровнево)

```
crates/                    # Shared Rust libs
  core/                    # wire format, TLS, tun_uring, константы
  client-common/           # H2/TLS handshake + TX/RX
  client-core-runtime/     # Unified tunnel runtime (все клиенты)
  client-{android,apple,linux}/
  server/                  # phantom-server + phantom-keygen
  relay/                   # phantom-relay (RU SNI-passthrough)
  gui-ipc/                 # canonical wire types (StatusFrame, LogFrame...)
apps/                      # Per-platform apps
  android/                 # Kotlin + Jetpack Compose
  ios/                     # SwiftUI + NEPacketTunnelProvider + PhantomKit
  linux/                   # cli + gui (Slint) + helper
  openwrt/                 # netifd proto + LuCI UI
server/                    # Серверные бинари + configs + deploy scripts
```

Подробная карта: [docs/knowledge/README.md](docs/knowledge/README.md).

## Инструменты

| Инструмент | Для чего |
|---|---|
| **gitnexus** (MCP) | Код-граф: callers, callees, blast radius, 262 execution flows. 3129 символов, 9364 связей. |
| **docs/knowledge/** | Смысл: ADR, invariants, глоссарий, платформы, инциденты, история. |
| **memory/** | Personal pointers Claude между сессиями. Автозагружается. |

Использование gitnexus: [docs/knowledge/tools/gitnexus.md](docs/knowledge/tools/gitnexus.md).
gstack CLI (обязателен): [docs/knowledge/tools/gstack.md](docs/knowledge/tools/gstack.md).

## Перед тем как что-то делать

1. **Архитектурный вопрос / правка ≥50 строк / ≥2 crate'а** → открой [docs/knowledge/README.md](docs/knowledge/README.md). Там карта **"трогаешь X → читай Y"**.
2. **Правка функции/метода** → `gitnexus_impact({target: "<symbol>", direction: "upstream"})`. Прочитай HIGH/CRITICAL warnings.
3. **Незнакомая часть кода** → `gitnexus_query({query: "<concept>"})` вместо grep.
4. **Сборка / деплой / релиз** → [docs/knowledge/build.md](docs/knowledge/build.md).
5. **Ошибка / странное поведение** → [docs/knowledge/troubleshooting.md](docs/knowledge/troubleshooting.md).
6. **Крупная задача (>5 файлов, ≥3 зон)** → [docs/knowledge/workflow.md](docs/knowledge/workflow.md) — мульти-агентный workflow.

## По окончании работы (обязательно)

| Что сделал | Что обновить |
|---|---|
| Поменял архитектуру / инвариант | `docs/knowledge/architecture/<page>.md` + `updated:` во frontmatter |
| Архитектурное решение, отказался от фичи, выбрал из альтернатив | Новый ADR: `docs/knowledge/decisions/NNNN-<slug>.md` (template — [0001](docs/knowledge/decisions/0001-remove-quic.md)) |
| Дебажил инцидент >2ч / нашёл неожиданный root cause | Постмортем: `docs/knowledge/incidents/YYYY-MM-DD-<slug>.md` |
| Ввёл новый термин / константу | Добавить в [docs/knowledge/glossary.md](docs/knowledge/glossary.md) |
| Android релиз | versionCode++ в `apps/android/app/build.gradle.kts` (таблица — [platforms/android.md](docs/knowledge/platforms/android.md)) |
| Значимый commit кода | `npx gitnexus analyze` (автоматом через post-commit hook) |
| Новая версия (tag `v*`) | Добавить запись в [docs/knowledge/history/timeline.md](docs/knowledge/history/timeline.md) |

## Хосты

| Алиас | IP | Роль |
|---|---|---|
| `vdsina` | 89.110.109.128 | NL exit — phantom-server + nginx frontend |
| — | 193.187.95.128 | RU relay — phantom-relay (SNI passthrough, НЕ терминирует TLS) |

SSH: `~/.ssh/bot` (алиасы в `~/.ssh/config`). Claude Code обычно запущен на vdsina — сборка server/linux/android идёт локально.

## Текущая версия

**v0.22.0** (2026-04-17) — iOS full parity через `client-core-runtime`.

- История версий: [docs/knowledge/history/timeline.md](docs/knowledge/history/timeline.md)
- ADR'ы: [docs/knowledge/decisions/](docs/knowledge/decisions/)
- CHANGELOG: `CHANGELOG.md`

## Правила (коротко)

- **Никаких `[[wikilinks]]`** — ломают GitHub rendering. Только `[text](path.md)`.
- **Не дублируй код-граф в vault** ("функция X вызывает Y" = работа gitnexus).
- **Не пиши narrative changelog в vault** ("добавил фичу Z" = git log).
- **Не создавай пустых stub'ов** — страница появляется когда есть содержание.
- **Не стэкай дубли** gitnexus (codegraph / code-review-graph и подобные) — overlap ≥80%, только раздувают контекст.
