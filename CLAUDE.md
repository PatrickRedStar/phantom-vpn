# GhostStream / PhantomVPN — Claude Code Instructions

## Как работать с пользователем (главное правило)

Пользователь — SRE, **не разработчик**, и это пет-проект для отдыха.

- **Полная автономия в коде.** Задачи приходят абстрактно («почини», «сделай», «глючит X») — сам разбирайся, сам находи причину, сам чини, сам проверяй. Не спрашивай про технические детали, реализацию, названия функций, выбор библиотек — это твоя зона.
- **К пользователю приходить только с бизнес-развилками**: что важнее (скорость vs скрытность), тратить ли деньги (новый VPS), менять ли поведение продукта, риск сломать работающее. Формулировать развилку без кода, на языке последствий.
- **Отвечать максимально кратко.** Итог в 1–3 предложения, без разбора шагов, без технических подробностей. Развёрнуто — только если пользователь явно попросил.
- **Серверная часть — исключение**: про топологию, хосты, сеть, деплой можно говорить чуть подробнее (пользователь в этом разбирается), но тоже без занудства — проект для расслабления.
- **Не усложняй.** Всегда самое простое решение, которое работает: минимум кода, минимум абстракций, минимум новых зависимостей. Сложность — только когда без неё реально никак, и это надо уметь обосновать одной фразой.

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
| **gitnexus** (MCP) | Код-граф: callers, callees, blast radius, execution flows. |
| **docs/knowledge/** | Смысл: ADR, invariants, глоссарий, платформы, инциденты, история. |
| **memory/** | Personal pointers Claude между сессиями. Автозагружается. |
| `tools/ship-android.sh` | Android тестовый билд: Rust + Kotlin + clean install на устройство. Не собирать руками через gradle/adb. |
| `apps/macos/scripts/ship-macos.sh` | macOS релиз: archive → notarize → dmg → staple → Downloads. |

Использование gitnexus: [docs/knowledge/tools/gitnexus.md](docs/knowledge/tools/gitnexus.md).
gstack CLI (обязателен): [docs/knowledge/tools/gstack.md](docs/knowledge/tools/gstack.md).

## Перед тем как что-то делать

1. **Архитектурный вопрос / правка ≥50 строк / ≥2 crate'а** → открой [docs/knowledge/README.md](docs/knowledge/README.md). Там карта **"трогаешь X → читай Y"**.
2. **Правка функции/метода** → `gitnexus_impact({target: "<symbol>", direction: "upstream"})`. Прочитай HIGH/CRITICAL warnings.
3. **Незнакомая часть кода** → `gitnexus_query({query: "<concept>"})` вместо grep.
4. **Сборка / деплой / релиз** → [docs/knowledge/build.md](docs/knowledge/build.md).
5. **Ошибка / странное поведение** → [docs/knowledge/troubleshooting.md](docs/knowledge/troubleshooting.md).
6. **Крупная задача (>5 файлов, ≥3 зон)** → [docs/knowledge/workflow.md](docs/knowledge/workflow.md) — мульти-агентный workflow.
7. **macOS правка cross-process boundary** (PacketTunnelProvider / VpnTunnelController / Keychain / PhantomBridge / client-apple / entitlements) → после fix ОБЯЗАТЕЛЬНО прогнать `apps/macos/scripts/smoke-test.sh` ДО следующего audit/round. Static checks lie на macOS sandbox + system extension boundary — единственный надёжный gate это real Connect. Постмортем: [incidents/2026-05-17-cert-pem-keychain-regression.md](docs/knowledge/incidents/2026-05-17-cert-pem-keychain-regression.md). ADR: [0009-cert-pem-providerConfiguration.md](docs/knowledge/decisions/0009-cert-pem-providerConfiguration.md).

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
| `vdsina` | 89.110.109.128 | **NL exit** — `phantom-server.service` (systemd) на `:8443` + admin API `10.7.0.1:8080` + nginx frontend. ⚠️ **Из РФ фильтруются порты 22 и 443** этого IP (SYN проходит, TLS/SSH молчат); `:8443` работает. Поэтому upstream реле — только `:8443`. |
| `balancer.bikini-bottom.com` | **158.160.135.140** | **БОЕВОЙ RU relay с 2026-07-31.** `phantom-relay` на `127.0.0.1:5443` за nginx-stream (`ssl_preread` уже маршрутизирует `tls.nl2.*` и `relay.*` сюда — правка nginx не нужна). Upstream `89.110.109.128:8443`. Даёт **6 МБ/с** с мобильной сети. SSH `vps_balancer` (порт 9083). ⚠️ Здесь же прод 3x-ui + xray — трогать только `phantom-relay`, nginx максимум reload. |
| `relay.bikini-bottom.com` | 89.169.175.55 | **Выведен из тракта: оператор режет этот IP до ~15 КБ/с** (проверено сырым HTTPS, любой порт/SNI; с NL и из дома тот же адрес даёт 57/34 МБ/с). Реле настроено и живо, серт автопродляется — держим как резерв, но клиентов сюда не направлять. Прежний **боевой RU relay** — `phantom-relay.service`, биндится `0.0.0.0:443` напрямую, без nginx и без docker. Passthrough → `89.110.109.128:8443`, `expected_sni = tls.nl2.bikini-bottom.com`. certbot standalone на `:80`, серт своего имени автопродляется, `renew_hook` рестартует relay (серт читается только при старте). SSH: `ssh -l spongebob 89.169.175.55 -i ~/.ssh/personal`. |
| `vps_balancer` | 158.160.135.140 | 3x-ui панель + xray + phantom-client → microsocks SOCKS5:10808. Relay-ветка здесь **мертва** (в журнале только SNI mismatch). Менять nginx/iptables только через reload, не restart. |
| — | 82.38.66.138 | poland — **выведен**, VPS не продлевается. Из тракта убран 2026-07-31. |
| — | 193.187.95.128 | Прежний RU relay — из ротации выведен. |

SSH: алиасы в `~/.ssh/config`.

**Инвариант топологии:** `клиент → relay balancer.bikini-bottom.com (158.160.135.140):443 (SNI=tls.nl2.bikini-bottom.com) → exit 89.110.109.128:8443`. Если `expected_sni` реле не совпадёт с SNI клиента — реле отдаёт fallback-серт, и **все** клиенты падают с `BadCertificate`. Это не мягкий отказ.

## Версия

Актуальную версию смотри в `git tag --sort=-v:refname | head -1` и `CHANGELOG.md` — здесь не хардкодить, устаревает.

- История версий: [docs/knowledge/history/timeline.md](docs/knowledge/history/timeline.md)
- ADR'ы: [docs/knowledge/decisions/](docs/knowledge/decisions/)

## Правила (коротко)

- **Никаких `[[wikilinks]]`** — ломают GitHub rendering. Только `[text](path.md)`.
- **Не дублируй код-граф в vault** ("функция X вызывает Y" = работа gitnexus).
- **Не пиши narrative changelog в vault** ("добавил фичу Z" = git log).
- **Не создавай пустых stub'ов** — страница появляется когда есть содержание.
- **Не стэкай дубли** gitnexus (codegraph / code-review-graph и подобные) — overlap ≥80%, только раздувают контекст.

## gstack и скиллы

gstack установлен глобально в `~/.claude/skills/gstack/` (скиллы /qa, /ship, /review, /investigate, /browse; веб-браузинг — через /browse). Если отсутствует: `git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && cd ~/.claude/skills/gstack && ./setup --team`.

Роутинг: нетривиальный баг → investigate, деплой/релиз → ship, QA → qa, ревью диффа → review. Скилл — когда задача реально ложится на его workflow; не тащить церемонию в тривиальные правки.

<!-- gitnexus:start -->
## GitNexus — код-граф (MCP)

Проект проиндексирован как **ghoststream**. Stale index → `npx gitnexus analyze` (post-commit hook делает автоматом; если есть embeddings — добавлять `--embeddings`, иначе они удалятся).

- **Перед правкой нетривиального символа** — `gitnexus_impact({target, direction: "upstream"})`; HIGH/CRITICAL — предупредить пользователя, d=1 dependents обновить обязательно.
- **Перед коммитом** — `gitnexus_detect_changes()`: scope должен совпасть с ожидаемым.
- **Незнакомый код** — `gitnexus_query({query: "<concept>"})` вместо grep; 360° по символу — `gitnexus_context({name})`.
- **Rename** — только `gitnexus_rename` (сначала `dry_run: true`), не find-and-replace.
- Трассировка флоу: ресурс `gitnexus://repo/ghoststream/process/{name}`; обзор — `gitnexus://repo/ghoststream/context`.

Детали и CLI-справка: `.claude/skills/gitnexus/*/SKILL.md`.
<!-- gitnexus:end -->
