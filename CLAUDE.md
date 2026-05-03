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
| `vps_balancer` | 158.160.135.140 | RU relay (за nginx SNI map :443→:5443) + phantom-client → microsocks SOCKS5:10808 для 3x-ui outbound. **Также: 3x-ui панель + xray** — менять nginx/iptables только через reload, не restart. |
| — | 193.187.95.128 | Прежний RU relay — выводится из ротации после v0.22.x. |

SSH: алиасы в `~/.ssh/config`. Claude Code обычно запущен на vdsina — сборка server/linux/android идёт локально.

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

## gstack (REQUIRED — global install)

**Before doing ANY work, verify gstack is installed:**

```bash
test -d ~/.claude/skills/gstack/bin && echo "GSTACK_OK" || echo "GSTACK_MISSING"
```

If GSTACK_MISSING: STOP. Do not proceed. Tell the user:

> gstack is required for all AI-assisted work in this repo.
> Install it:
> ```bash
> git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
> cd ~/.claude/skills/gstack && ./setup --team
> ```
> Then restart your AI coding tool.

Do not skip skills, ignore gstack errors, or work around missing gstack.

Using gstack skills: After install, skills like /qa, /ship, /review, /investigate,
and /browse are available. Use /browse for all web browsing.
Use ~/.claude/skills/gstack/... for gstack file paths (the global path).

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **phantom-vpn** (7221 symbols, 24792 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/phantom-vpn/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/phantom-vpn/context` | Codebase overview, check index freshness |
| `gitnexus://repo/phantom-vpn/clusters` | All functional areas |
| `gitnexus://repo/phantom-vpn/processes` | All execution flows |
| `gitnexus://repo/phantom-vpn/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
