---
updated: 2026-04-17
---

# gitnexus — code graph via MCP

gitnexus — MCP-сервер, который строит семантический граф кода через tree-sitter и отдаёт его Claude Code'у в виде инструментов (`gitnexus_query`, `gitnexus_impact`, `gitnexus_callers`, ...). Это **основной инструмент навигации по коду** — быстрее и точнее, чем grep.

Размер графа на данный момент:
- **3129 символов** (функции, структуры, traits, методы)
- **9364 связей** (calls, implements, references)
- **262 execution flows** (предвычисленные call chains через hot paths)

Хранилище — SQLite в `.gitnexus/` корня репо. Персистентный индекс, обновляется post-commit hook'ом.

---

## Install

**Глобально через npm:**
```bash
npm install -g gitnexus@latest
```

MCP config в `~/.claude.json` под проектом:
```json
{
  "projects": {
    "/Users/p.kurkin/Documents/phantom-vpn": {
      "mcpServers": {
        "gitnexus": {
          "type": "stdio",
          "command": "gitnexus",
          "args": ["mcp"]
        }
      }
    }
  }
}
```

**Важно — НЕ использовать `npx gitnexus@latest mcp`.** На cold start npx тянет tree-sitter deps (~300 пакетов, 30+ секунд) → MCP handshake у Claude Code по таймауту → tools не подключаются. Только прямой бинарь (`command: "gitnexus"`).

Troubleshooting missing tools — [../troubleshooting.md](../troubleshooting.md#mcp-gitnexus-missing-tools).

---

## Когда использовать

### Always Do

| Ситуация | Команда |
|---|---|
| Незнакомая часть кода | `gitnexus_query({query: "<concept>"})` |
| «Кто вызывает X?» | `gitnexus_callers({target: "<symbol>"})` |
| «Что вызывает X?» | `gitnexus_callees({target: "<symbol>"})` |
| Перед правкой функции | `gitnexus_impact({target: "<symbol>", direction: "upstream"})` |
| Нужен полный контекст узла (сигнатура, файл, строка) | `gitnexus_node({id: "<symbol>"})` |

### When Debugging

- `gitnexus_query({query: "...what is happening..."})` — семантический поиск.
- `gitnexus_context({query: "...", max_tokens: 4000})` — соберёт клубок связанных кусков кода (больше, чем `query`).
- Если gitnexus вернул пусто — `detect_changes` покажет, на каком commit был проиндексирован граф (если старый — см. «Keeping the index fresh»).

### When Refactoring

- **Перед переименованием** → `gitnexus_impact` с `direction: "upstream"` + `direction: "downstream"`, прочитать HIGH/CRITICAL warnings.
- **Массовое переименование** → `gitnexus_rename({old_name: "...", new_name: "..."})` обновляет граф после того, как я уже переименовал в коде (sanity check, не замена sed).
- **Сложный граф-запрос** (чего нет в стандартных инструментах) → `gitnexus_cypher({query: "MATCH ..."})`. Neo4j Cypher-like синтаксис.

### Never Do

- **Не заменять чтением файлов через Read**, когда вопрос — «кто вызывает эту функцию». Read не видит весь граф, gitnexus видит.
- **Не стэкать дубли кодграфа** — codegraph/code-review-graph/подобное создают overlap ≥80% и раздувают контекст. gitnexus — единственный. См. `memory/feedback_graph_tooling.md`.
- **Не верить устаревшему индексу**. После крупного рефакторинга прогнать `gitnexus analyze` или проверить `detect_changes`.

---

## Tools quick reference

| Tool | Назначение |
|---|---|
| `gitnexus_query` | Семантический поиск по графу (natural language → top-K релевантных узлов) |
| `gitnexus_context` | Собрать связанный контекст вокруг темы (больше, чем query, для understanding) |
| `gitnexus_impact` | Blast radius: `direction: "upstream"` — кто сломается, `"downstream"` — что перестанет работать |
| `gitnexus_callers` / `gitnexus_callees` | Прямые вызовы (один hop) |
| `gitnexus_node` | Полный дамп одного узла: сигнатура, файл, строка, связи |
| `gitnexus_detect_changes` | Что изменилось между последним индексом и HEAD |
| `gitnexus_rename` | Обновить граф после переименования (я сам переименовал в коде → он пересчитывает) |
| `gitnexus_cypher` | Произвольный graph query на Cypher-like языке |

---

## Impact risk levels

`gitnexus_impact` возвращает затронутые узлы с distance от target:

| Distance | Уровень риска | Что это значит |
|---|---|---|
| `d=1` | **WILL BREAK** | Прямо вызывает target. Правка сигнатуры обязательно сломает компиляцию |
| `d=2` | **LIKELY BREAK** | Вызывает то, что вызывает target. Вероятно сломается или будет неверное поведение |
| `d=3` | **MAY NEED TESTING** | Далёкий transitive caller. Компиляция пройдёт, но логика может отъехать |

Правило: **HIGH/CRITICAL warnings читаем все, независимо от distance.** Они помечены отдельно, это не просто близость в графе.

---

## Resources (MCP)

Вызываются как `gitnexus://...` URI:

- `gitnexus://repo/phantom-vpn/context` — обзор репо (crates, entry points, доминантные паттерны).
- `gitnexus://repo/phantom-vpn/clusters` — тематические кластеры узлов (например, «TLS», «handshake», «session management»).
- `gitnexus://repo/phantom-vpn/processes` — список 262 execution flows (hot paths, pre-computed).
- `gitnexus://repo/phantom-vpn/process/{name}` — полный chain конкретного flow.

---

## Self-check before finishing

Перед завершением задачи, затронувшей код, пройти по чек-листу:

1. **Прочитал ли я impact output?** Если `gitnexus_impact` выдал HIGH/CRITICAL — я на них отреагировал (починил/протестировал/задокументировал).
2. **Не делаю ли я работу grep'ом там, где был бы query?** Если искал «концепт» через Grep — это симптом, лучше передеать через `gitnexus_query`.
3. **После правки сигнатуры — обновил ли я всех callers?** Список — из `gitnexus_callers({target: "<renamed>"})`.
4. **Индекс свежий?** После значимых правок — `gitnexus analyze` (или post-commit hook срабатывает автоматически).

---

## Keeping the index fresh

Индекс хранится в `.gitnexus/` в корне репо. Метаданные — `.gitnexus/meta.json` (tracks last-indexed commit).

**Автоматически:** post-commit hook запускает `npx gitnexus analyze` после каждого коммита. Проверить, что хук стоит — `.git/hooks/post-commit`.

**Вручную:**
```bash
# Обычный reindex (incremental если возможно)
gitnexus analyze

# С embeddings (если они уже были в индексе — check meta.json)
gitnexus analyze --embeddings
```

Проверить, использовать ли `--embeddings`:
```bash
cat .gitnexus/meta.json | grep -i embed
```

Если в meta.json есть поле про embeddings — значит их поддерживаем, и переиндексацию нужно запускать с `--embeddings`, иначе они потеряются.

---

## Связанное

- MCP setup история и фикс — `~/.claude/projects/.../memory/project_mcp_setup.md`.
- Правило «один кодграф» — `~/.claude/projects/.../memory/feedback_graph_tooling.md`.
- Главный индекс vault — [../README.md](../README.md).
- Архитектурный контекст (что именно описывает граф) — [../architecture/_index.md](../architecture/_index.md).
