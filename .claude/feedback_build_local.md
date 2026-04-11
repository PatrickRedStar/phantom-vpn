---
name: build_on_vdsina
description: Claude Code runs directly on vdsina server — cargo builds happen locally, no SSH needed for builds
type: feedback
---

Claude Code перенесён на сервер vdsina (89.110.109.128). cargo установлен локально.

**Why:** Упрощение разработки — не нужен rsync/ssh для сборки.

**How to apply:** Собирать `cargo build` напрямую в `/opt/github_projects/phantom-vpn/`. Деплой сервера: `install` бинарник в `/opt/phantom-vpn/` + `systemctl restart`. SSH ключ `~/.ssh/bot` для RU relay (193.187.95.128).
