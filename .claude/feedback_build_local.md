---
name: build_locally_only
description: All builds must happen locally, server is only for deploying binaries — no repo on server
type: feedback
---

Сборка только локально. На сервер кидать только готовые бинарники.

**Why:** Пользователь не хочет держать репозиторий на сервере, не хочет собирать там.

**How to apply:** Установить cargo/rustup/NDK локально. Для деплоя — только `scp` бинарника на сервер. Не использовать `rsync crates/` на сервер, не запускать `cargo build` на сервере.
