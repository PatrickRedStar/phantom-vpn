---
updated: 2026-10-26
---

# GhostStream Knowledge Vault

Структурная база знаний для Claude Code и агентов. Дополняет gitnexus:
**gitnexus = "что вызывает что"** (код-граф), **vault = "почему мы так решили"** (смысл, ADR, инциденты, глоссарий).

Можно открывать как Obsidian vault (папка `docs/knowledge/` = корень). Ссылки —
обычные markdown (`[text](path.md)`), работают и в Obsidian, и на GitHub.

---

## Карта — что читать перед правкой

| Трогаешь | Читай |
|---|---|
| `crates/core/src/wire.rs`, batch/frame/padding | [architecture/wire-format.md](architecture/wire-format.md) |
| `crates/core/src/tls.rs`, mTLS, handshake, отказ в доступе | [architecture/handshake.md](architecture/handshake.md), [architecture/crypto.md](architecture/crypto.md) |
| DPI/ТСПУ, обход детекта, ClientHello fingerprint, SNI, relay-камуфляж | [architecture/dpi-tspu.md](architecture/dpi-tspu.md) |
| `server/server/src/vpn_session.rs`, SessionCoordinator, attach/detach | [architecture/sessions.md](architecture/sessions.md) |
| `server/server/src/main.rs`, TLS accept, nginx passthrough | [architecture/transport.md](architecture/transport.md), [platforms/server.md](platforms/server.md) |
| `server/relay/` или RU-хоп (`balancer.bikini-bottom.com`) | [platforms/server.md](platforms/server.md) (секция "Relay SNI passthrough") |
| `crates/client-common/`, `client-core-runtime/` | [architecture/transport.md](architecture/transport.md) |
| Переподключение, Stale/Degraded, фатальные ошибки, kill switch | [decisions/0018-rust-owns-reconnect.md](decisions/0018-rust-owns-reconnect.md) |
| `crates/client-android/` + `apps/android/` | [platforms/android.md](platforms/android.md) |
| `crates/client-apple/` + `apps/ios/` | [platforms/ios.md](platforms/ios.md) |
| `crates/client-apple/` + `apps/macos/` | [platforms/macos.md](platforms/macos.md) |
| `apps/linux/` (cli + gui + helper) | [platforms/linux.md](platforms/linux.md) |
| `apps/windows/` + `crates/client-windows-core/` | [platforms/windows.md](platforms/windows.md) |
| `server/server/src/admin.rs`, conn_string, подписки | [architecture/admin-api.md](architecture/admin-api.md) |
| Любое слово-жаргон (`effective_n`, `flow_stream_idx`, ...) | [glossary.md](glossary.md) |

Когда ни одна строка не подходит — загляни в [architecture/_index.md](architecture/_index.md) и [platforms/_index.md](platforms/_index.md).

---

## Правила для Claude (обязательно)

**Перед крупной правкой (≥50 строк или затрагивает ≥2 crate'а):**
1. `gitnexus_impact({target: "<symbol>", direction: "upstream"})` — blast radius
2. Прочитать релевантные страницы из карты выше
3. Только потом редактировать

**Что пишу в vault:**
- **ADR** → `decisions/NNNN-<slug>.md` — при любом архитектурном решении (удалили фичу, сменили протокол, выбрали библиотеку). Template: см. [decisions/0001-remove-quic.md](decisions/0001-remove-quic.md)
- **Incident** → `incidents/YYYY-MM-DD-<slug>.md` — после регрессии/инцидента/дебага-который-стоил-часов. Фиксирую: симптом, root cause, fix, как воспроизвести в будущем
- **Architecture update** → правлю существующую страницу, в frontmatter меняю `updated`
- **Новый термин** → добавляю в `glossary.md`

**Чего НЕ делаю:**
- Не дублирую код-граф (это gitnexus работа). Не пишу "функция X вызывает Y".
- Не пишу narrative changelog ("добавил фичу Z"). Это git log/CHANGELOG.md.
- Не создаю пустых стабов "для красоты" — страница появляется когда есть содержание.

---

## Структура

```
docs/knowledge/
├── README.md              # этот файл — индекс + правила
├── glossary.md            # термины проекта
├── build.md               # где что собирается, деплой, релизный процесс, CI
├── troubleshooting.md     # частые ошибки, команды диагностики
├── workflow.md            # мульти-агентный workflow (декомпозиция по зонам)
├── architecture/          # "как работает" (дополняет gitnexus)
│   ├── _index.md          # карта страниц этого раздела
│   ├── wire-format.md
│   ├── handshake.md
│   ├── transport.md
│   ├── sessions.md
│   ├── crypto.md
│   ├── dpi-tspu.md
│   └── admin-api.md
├── platforms/             # per-platform notes
│   ├── _index.md
│   ├── server.md
│   ├── android.md
│   ├── ios.md
│   ├── macos.md
│   ├── linux.md
│   ├── openwrt.md
│   └── windows.md
├── decisions/             # ADR-ки ("почему")
│   ├── _index.md
│   └── NNNN-<slug>.md
├── incidents/             # постмортемы
│   ├── _index.md
│   └── YYYY-MM-DD-<slug>.md
├── audits/                # bug-hunt отчёты (YYYY-MM-DD-<slug>.md)
├── history/
│   └── timeline.md        # история версий
└── tools/                 # инструментарий
    ├── gitnexus.md
    └── gstack.md
```

---

## Соглашения о формате страниц

**Frontmatter — минимум:**
```yaml
---
updated: YYYY-MM-DD     # обновляй при правках
tags: [optional]        # для Obsidian search
---
```

**Ссылки — стандартный markdown:**
- `[wire format](architecture/wire-format.md)` — межстраничные (пишутся относительно текущего файла)
- `[vpn_session.rs:120](../../server/server/src/vpn_session.rs)` — ссылки в код (Obsidian откроет, GitHub тоже)
- `[[wikilinks]]` **не используем** — ломают GitHub rendering

**Заголовки:**
- `# Title` один раз на странице (совпадает с filename)
- Дальше `##` / `###` — обычная иерархия

**Стиль:**
- Русский (как и в CLAUDE.md) — быстрее читать и писать
- Код/команды — в code blocks с языком (```rust, ```bash)
- Ссылки на конкретные строки кода — опционально `:line`

---

## Status

Vault заведён 2026-04-17, с тех пор наполняется по ходу работы. На 2026-10-26:
ADR 0001–0019 в `decisions/`, 6 постмортемов в `incidents/`, три отчёта в
`audits/` (последний — [полный аудит 2026-10-22](audits/2026-10-22-full-scan.md)
со статусом исправлений), страницы по всем платформам (`platforms/windows.md`
описывает клиент, код которого пока живёт на ветке `feature/windows-client`).

Принцип прежний: страница появляется, когда есть содержание — не заранее.
