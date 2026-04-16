---
name: Play Market release plan
description: План выхода в Google Play — чеклист технических и организационных задач, аккаунт куплен 2026-04-16
type: project
originSessionId: f9ca864a-3ae5-464d-a18e-c93a3af847e6
---
Google Play Console аккаунт куплен 2026-04-16, на проверке.

**Why:** пользователь хочет автоматический pipeline для деплоя в Play Market.

**How to apply:** при работе над релизами учитывать что нужен AAB (не APK), release signing, и автодеплой.

## Чеклист

- [x] Google Play Console аккаунт ($25) — куплен 2026-04-16, на проверке
- [ ] Создать release keystore (.jks) — хранить вне репо, backup обязателен
- [ ] signingConfigs + bundleRelease в build.gradle.kts
- [ ] targetSdk/compileSdk → 36 (Android 16, решено пользователем)
- [ ] Включить R8 + ProGuard rules (JNI .so, OkHttp, Compose)
- [ ] Privacy Policy — текст + хостинг на URL (обязателен для VPN)
- [ ] Store listing: название, описания, скриншоты, feature graphic 1024x500
- [ ] Data Safety Declaration в Console
- [ ] Content Rating (IARC опросник)
- [ ] Service Account (Google Cloud) для API → GitHub Secrets
- [ ] gradle-play-publisher плагин в build.gradle.kts + CI pipeline
- [ ] Первый ручной релиз через Console (обязателен)
- [ ] Далее — автодеплой через CI при git tag v*
