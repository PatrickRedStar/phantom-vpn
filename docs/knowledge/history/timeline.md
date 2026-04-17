---
updated: 2026-04-17
---

# Timeline проекта

163 коммита · 66 тегов · 7 эпох развития (2026-03-12 → 2026-04-17).

Цель документа — **понимать откуда что пришло**. Если код смущает, ищи коммит в этой таблице: контекст в сообщении коммита + ADR (`decisions/`), если было крупное решение.

---

## Эпоха 1 — Foundation (2026-03-12 — 2026-03-13)

**Старт проекта.** Первые сборки, keygen, install.py auto-provisioning, базовый Linux клиент на TUN.

| Коммит | Событие |
|--------|---------|
| `998f307` | Первый коммит (скелет). |
| `9fb2b79` | install.py auto-provisioner + graceful shutdown. |
| `96ed7f5` | Починили `phantom-keygen` build target. |
| `e1daf1d` | TCP checksum recalc для MSS clamping. |
| `e43d8d1` | Nonce-based transport sequencing + recovery at client address changes. |
| `6f0e521` | Policy-based routing чтобы не потерять SSH при full-tunnel. |
| `3f5697d` | WireGuard-style policy rules для клиентского роутинга. |
| `4e691fb` | Preserve host management traffic в full-tunnel режиме. |
| `c19cd53` | Интерактивный client key manager (keys.py). |
| `e3f22c4` | **Fix:** install `ring` CryptoProvider at startup (rustls 0.23 panic). |
| `a55965c` | **Fix:** teardown NAT перед setup при старте (iptables дубликаты). |
| `e5aea9c` | Skip IPv6 пакеты при регистрации клиентской сессии. |

---

## Эпоха 2 — QUIC Transport & Optimization (2026-03-13 — 2026-03-16)

**12x throughput: 14 → 172 Mbit/s → далее. opt-v1…opt-v12.** QUIC датаграммы → reliable streams → multi-stream → H.264 shaping → io_uring TUN → zero-copy. В конце этой эпохи Noise layer удалён, остался только mTLS.

| Коммит | Событие |
|--------|---------|
| `237eb42` | **Migrate QUIC datagrams → reliable streams** с H.264 batch plaintext. |
| `f4c0ac7` | Fix panic в `build_batch_plaintext` + server batch overflow. |
| `a5719ee` | **perf: 12x throughput improvement (14 → 172 Mbit/s).** |
| `f66c589` | **perf:** pipeline TX — decouple encrypt from QUIC write. |
| `a0f7b00` | **perf:** N=4 parallel QUIC data streams — устранение head-of-line blocking. |
| `c908d5e` | **Remove Noise encryption, switch to mTLS.** Это ADR 0002. |
| `ace1089` | **perf:** BBR → unlimited congestion controller. |
| `f16f1b2` | **perf:** zero-copy batch processing. |
| `5c158d8` | **perf:** io_uring TUN I/O — batch syscalls. |
| `011260b` | **feat:** H.264 traffic shaping (mask VPN as video call). |
| `76f744c` | **feat:** REALITY-style fallback для DPI active probing. |
| `b21294b` | multiqueue TUN (IFF_MULTI_QUEUE). |
| `cc5d61e` | **perf:** collapse async pipeline — 2 hops instead of 3. |
| `5a72d6e` | **Revert** pipeline collapse (регрессия 117 → 102 Mbit/s). Хороший урок: не каждая оптимизация срабатывает. |

---

## Эпоха 3 — Productization (Android + Admin) (2026-03-20 — 2026-03-22)

**Android клиент появился.** JNI bridge, Kotlin VpnService, Compose UI. Параллельно — fingerprint allowlist, base64 conn_string, admin HTTP panel, subscriptions, passive DNS cache.

| Коммит | Событие |
|--------|---------|
| `b3ac95d` | **feat: Android client (JNI + Kotlin VpnService).** |
| `f18d873` | CI: GitHub Actions release workflow. |
| `02a44ab` | **refactor:** move project from subdir to repo root. |
| `df0b33a` | Android: mTLS client cert/key support. |
| `bfa88ac` | keys.py rewrite для mTLS client cert management. |
| `a2281f1` | Android: connection string import. |
| `dbece60` | Fix: foregroundServiceType=specialUse (Android 14). |
| `9c8f53d` | **feat:** IP-based split routing + per-app VPN. |
| `b451fc4` | **feat:** fingerprint-based allowlist + musl cross-compile. |
| `c32ce91` | **feat:** base64 connection string auth across all platforms. |
| `e8453dd` | Android UI improvements: per-app, split routing info, connect ring. |
| `b964760` | **feat:** DNS resolution for hostname + remove phantom CA from conn string. |
| `228d644` | Android: multi-profile connections (v2rayTun style). |
| `174c083` | Android: auto-reconnect on VPN drop + увеличить QUIC idle timeout. |
| `2c6a555` | Server: **SNAT exit_ip support** — вторичный IP для выхода. |
| `823be5d` | **feat: admin HTTP panel (server + Android).** |
| `f7ab983` | Admin panel polish: dest logging, time-series stats, filters. |
| `4ecafd4` | **feat:** passive DNS cache — resolve IPs to hostnames. |
| `3ba9e75` | **feat:** subscription system — expiry per client. |
| `e81de7a` | **feat(macos):** native SwiftUI menu bar app (первая iteration, позже заброшена). |
| `452303a` | **Android v0.9.0:** ping, subscription status, log hierarchy, debug share. |
| `218a424` | docs: расширить CLAUDE.md — полная документация для агентов. |
| `0b84c9e` | **Android v0.10.0:** TV pairing via QR code. |

---

## Эпоха 4 — Android UX overhaul (2026-03-25)

**v0.14.x — аудит, UX, split-routing стабильность. iOS первая попытка** (заброшена — вернётся в Эпоху 7).

| Коммит | Событие |
|--------|---------|
| `7c4315c` | Android v0.14.0 — аудит и улучшения UX. |
| `d744855` | Android v0.14.1 — UX overhaul + split-routing стабильность. |
| `5509b09` | **feat(ios):** first iOS app + CI release pipeline. |
| `cddd3c1` — `df6208b` | iOS CI fixes (signing, bundle ID, SwiftUI iOS 16 compat). |

---

## Эпоха 5 — H2 Transport + OpenWrt (2026-03-29 — 2026-04-12)

**Ключевой переход: QUIC → HTTP/2 over TLS over TCP.** Новое железо: multi-stream с handshake negotiation, TX pipeline parallelism, RU relay (SNI passthrough), OpenWrt портирование для роутеров (MIPS, mipsel, arm64, arm).

| Коммит | Событие |
|--------|---------|
| `1be0781` | **feat(h2): HTTP/2 transport with full optimization pipeline (v0.15.4).** Это ADR 0003. |
| `f071d51` | Checkpoint v0.17.1 — H2 multi-stream + RU relay + TX ceiling diagnosis. |
| `21fab98` | **Server: parallel per-stream batch loops (v0.17.2)** — download 138 → 625 Mbit/s. |
| `a79f2bd` | v0.18.1: multi-stream handshake negotiation + zombie session eviction. |
| `8a3f50a` | v0.18.2: heartbeat frames + telegram admin bot. |
| `e4bd3a8` | v0.18.3: TUN txqueuelen 10000 + client TX drain/flush. |
| `1e1233d` | Core: `tun_simple` fallback для kernel без io_uring. |
| `adb4ed6` | **feat: phantom-client-openwrt** — минимальный VPN daemon для роутеров. |
| `6e65dfc` | OpenWrt: netifd protocol handler. |
| `80c74fc` | OpenWrt: LuCI protocol page. |
| `a563648` | CI: cross-compilation workflow (4 архитектуры). |
| `d3ba972` | **fix:** security & reliability audit — 15 bugfixes (H1-H4, M1-M6, L1-L5). |
| `4ca8f75`–`48103b6` | MIPS build CI: musl.cc → zigbuild → cross-rs. |

---

## Эпоха 6 — Breaking v0.19 + QUIC removal (2026-04-15)

**Ломающий релиз:** base64-JSON conn_string заменён на `ghs://` URL. Admin mTLS стал dynamic (`is_admin` в keyring). QUIC код окончательно удалён.

| Коммит | Событие |
|--------|---------|
| `c722d0e` | TLS: всегда включать webpki roots в client trust store. |
| `36295c0` | Android: cure VPN service 'coma' на network switch + auto-start на boot. |
| `f4377ca` | **v0.19.0 — ghs:// conn_string + dynamic admin mTLS (breaking).** ADR 0004. |
| `00f66f2` | Android: park reconnect on network loss + bot reply-keyboard nav. |
| `2dab535` | Android: release TUN fd первым на stop (даже при reconnect). |
| `624600f` | Android v0.19.3: pre-resolve server hostname через underlying network. |
| `04913e9` | **v0.19.4 — remove dead QUIC stack, fix DNS parser, io_uring panics.** |
| `3b47c5d` | docs: обновить после v0.19.4 + multi-agent workflow. |
| `726bda2` | docs: GUI agents для macOS / Windows / Linux desktop. |
| `04717ac` | **Android v0.20.0** — full UI redesign, swipe nav, Ghost-styled dialogs. |
| `d166646` | **Android v0.21.0** — Android 16 (SDK 36), inline PEM certs, UX fixes. |

---

## Эпоха 7 — Runtime unification + iOS rebirth (2026-04-16 — 2026-04-17)

**Главное событие v0.22.0:** извлечён `client-core-runtime` — unified tunnel runtime для всех платформ. iOS переписан с нуля на новую инфраструктуру (PhantomKit package + NEPacketTunnelProvider + Rust FFI). Репо реорганизован: `apps/` + `server/` + `crates/`.

| Коммит | Событие |
|--------|---------|
| `b10fda6` | **Scaffold iOS client** (SwiftUI + NEPacketTunnelProvider + Rust FFI). |
| `484b1c2` | **refactor:** reorganize repo — apps/ server/ layout. |
| `3803987` | refactor: move config/ + scripts/ into server/. |
| `f2c0169` | refactor: ghoststream-install.sh → apps/openwrt/, drop .cargo. |
| `1b5266c` | **refactor(core): extract client-core-runtime** — unified tunnel runtime (Phase 1). ADR 0005. |
| `8753a8f` | Phase 3: apple ffi consumes client-core-runtime + gui-ipc. |
| `aeb1fde` | Phase 2: linux helper + cli consume client-core-runtime. |
| `7f44240` | Phase 4: android jni consumes client-core-runtime, listener-based. |
| `173f076` | Phase 5: PhantomKit local Swift package (models + storage + FFI bridge). |
| `5779870` | Phase 6: PacketTunnelProvider — profileId IPC + IPv6 killswitch. |
| `2f4fa5d` | Phases 7-8: VpnStateManager snapshot + VpnTunnelController profileId. |
| `8e52f15` | Phase 10: i18n — Localizable.strings RU baseline + EN placeholder. |
| `d5b4912` | Phase 9: iOS UI — real StatusFrame, Admin reachable, split-routing wired. |
| `929d7d7` | docs: CLAUDE.md architecture + apps/ios/README.md (Phase 12). |
| `6b7c00a` | **v0.22.0 — tunnel-runtime consolidation + iOS full parity.** |

---

## Как использовать timeline

1. **Смущает старая решение в коде?** Ищи соответствующий коммит → `git show <hash>` даст полный контекст.
2. **Планируется крупное изменение?** Сперва посмотри, нет ли похожего опыта в прошлом (как `5a72d6e` revert pipeline collapse).
3. **ADR-worthy решение:** если изменение меняет направление архитектуры (как mTLS замена Noise, H2 замена QUIC, conn_string URL) — пишем ADR в `decisions/`.

Живой список тегов: `git tag --sort=-creatordate`. Живая история: `git log --oneline`.
