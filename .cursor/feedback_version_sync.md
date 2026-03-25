---
name: version_sync
description: Always sync versionCode/versionName in build.gradle.kts and git tag when releasing
type: feedback
---

При каждом новом теге (v0.X.Y) обязательно обновлять:
1. `android/app/build.gradle.kts` — `versionCode` (инкремент) и `versionName = "X.Y.Z"`
2. Версия отображается в "О приложении" через `BuildConfig.VERSION_NAME` — обновляется автоматически

**Why:** Пользователь указал что блок "О приложении" должен всегда соответствовать тегу.

**How to apply:** Перед `git tag vX.Y.Z` и `git commit` — проверить build.gradle.kts, обновить versionName и versionCode.

Таблица соответствия (для расчёта versionCode):
- v0.8.0 → versionCode 6
- v0.8.1 → versionCode 7
- v0.8.2 → versionCode 8
- v0.8.3 → versionCode 9
- v0.8.4 → versionCode 10 (пропущен — был помечен с versionCode=9, ошибка)
- v0.8.5 → versionCode 11
- v0.8.6 → versionCode 12
- v0.8.7 → versionCode 13
- v0.8.8 → versionCode 14
- v0.8.9 → versionCode 15
- v0.9.0 → versionCode 16 (текущий)
