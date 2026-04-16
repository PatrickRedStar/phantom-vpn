---
name: VPN protocols & transports landscape 2026
description: Comprehensive reference on all major VPN/proxy protocols and transports as of April 2026, Russian TSPU blocking mechanics, performance physics, why gRPC→xHTTP migration
type: reference
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
# Контекст

Собрано 2026-04-11 в ходе исследования под задачу найти «грааль» для GhostStream — оригинальный VPN-протокол, который выживет блокировку VLESS/Hysteria2 в РФ. Все факты проверены через web search (не внутренняя память). Источники: статьи Habr 990144, X-Core docs, AmneziaWG 2.0 release (март 2026), Windscribe/NymVPN announcements, исследования TrojanProbe (2024), TSPU incident reports 2025-2026.

---

# 1. Механики блокировки ТСПУ (апрель 2026)

## Смена парадигмы 2024 → 2026

ТСПУ переехала с blacklist-based (совпадение с известной сигнатурой → блок) на **heuristic-based** (набор аномалий → блок). Это значит: клон существующего протокола больше не спасает — новый протокол палится по общим паттернам, а не по специфичным байтам.

## Конкретные активные правила в РФ (по состоянию на апрель 2026)

### 🔴 15-20KB TCP lockout (самое важное, март 2026)

На мобильных операторах (Мегафон, Билайн, МТС) ТСПУ **замораживает** TCP-соединение к иностранному IP если внутри него передано больше 15-20 KB. Не RST, не FIN — просто zero-window, пакеты перестают доходить.

**Что убивает:**
- gRPC stream-one
- xHTTP stream-one
- VLESS + XTLS Vision (одно большое соединение)
- Hysteria2 (UDP/443 тоже под влиянием)
- WireGuard (UDP, но ещё и handshake magic byte)

**Что выживает:** много коротких TCP-соединений по <10 KB, packet-up паттерны, короткий HTTP long-poll.

### 🔴 Heuristic: «TLS 1.3 + active hammering → DROP»

ТСПУ ищет паттерн: TLS handshake → немедленно высокий pps. Реальный браузер: handshake → HTML (мало) → параллельные картинки → долгая пауза. VPN: handshake → 100% link instantly. Лечится шейпингом первых 5-10 секунд нового коннекта (mimicry warmup).

### 🔴 IP↔DNS correlation (2025+)

ТСПУ сопоставляет SNI в ClientHello с глобальной DNS-базой. Если клиент отправляет SNI=`apple.com`, но IP не принадлежит Apple → блок. **Это убивает REALITY**. Не копируй REALITY в GhostStream.

### 🟠 JA3/JA4 fingerprint

Если TLS-стек не похож ни на один распространённый браузер/мобильное приложение — подозрение. Rustls с default настройками палится. okhttp (Android), NSURLSession (iOS), boringssl (Chrome), nss (Firefox) — у всех свои JA4.

### 🟠 UDP/443 приоритизация

Мобильные операторы агрессивно режут QUIC. Не stateful, но rate-limit. Лечение: не использовать UDP/443. Это убивает весь Hysteria2 стек.

### 🟠 Entropy heuristic

TCP с энтропией Шеннона ≈8 (идеальный рандом) и ноль видимых заголовков → подозрение на AEAD-прокси. Реальный HTTPS имеет «провалы» энтропии на каждом TLS record header. Shadowsocks, Mieru (без mimicry обёртки), VMess палятся здесь.

### 🟢 Порты 47000+

Зона слабой фильтрации. ТСПУ не включает эвристики там, потому что «обычно ничего нет». Но mobile operators могут иначе.

### 🟢 Empty SNI

Связки с пустым SNI проходят. Правда легко детектить: «коннект к IP без SNI → подозрение в следующей итерации правил».

---

# 2. Сравнительная таблица протоколов

| Протокол | Транспорт | Статус РФ 2026 | Скорость | Скрытность | Главная уязвимость |
|---|---|---|---|---|---|
| **WireGuard** | UDP | 🔴 Заблокирован | line rate | 0 | Magic byte `01 00 00 00` в handshake |
| **AmneziaWG 1.x** | UDP | 🟡 Работает частично | ~WG-5% | низкая | Статический junk, UDP |
| **AmneziaWG 2.0** (03/2026) | UDP | 🟢 Работает | ~WG-5% | высокая (dynamic + мимикрия QUIC/DNS/SIP) | Всё равно UDP/443 на мобиле |
| **Trojan** | TLS/TCP | 🟡 | высокая | средняя | TrojanProbe (2024) — active probe определяет behavior |
| **Hysteria v1** | QUIC/UDP | 🔴 | — | — | Устаревший |
| **Hysteria2 + Brutal** | QUIC/UDP | 🔴 «крайне нестабилен» | теор. огромная | QUIC initial палится | UDP/443, Brutal CC тоже эвристика |
| **Hysteria2 Masquerade** | QUIC + fake H3 | 🔴 | = H2 | ALPN=h3 ничего не спасает | Тот же UDP |
| **Hysteria2 Salamander** | QUIC + XOR-obfs | 🔴 | = H2 | entropy OK, но UDP виден | UDP/443 |
| **Shadowsocks 2022** | TCP/UDP | 🔴 | очень высокая (AEAD) | 0 (полный рандом) | Отсутствие TLS-мимикрии |
| **Mieru** | TCP | 🟡 малоизвестен | высокая (XChaCha20) | средняя (fragmentation + padding) | Нет HTTPS-внешнего слоя |
| **NaiveProxy** | HTTP/2 CONNECT через Chromium | 🟢 **стабильно работает** | средняя (H2 overhead) | **лучшая** (real Chromium JA3/JA4) | Медленнее VLESS; HoL blocking |
| **VLESS + XTLS Vision + REALITY** | TLS/TCP | 🟡 работает, REALITY под угрозой | максимальная (zero-copy splicing) | была max | IP↔DNS correlation (2025+) |

## Ключевые выводы по протоколам

1. **Всё UDP мертво на мобиле РФ** — Hysteria2, QUIC-Masquerade, WireGuard. Не использовать.
2. **REALITY больше не магия** — IP↔DNS correlation лечится только multi-origin.
3. **NaiveProxy — золотой стандарт стелса**, но архитектурно single connection → HoL blocking + медленный.
4. **AmneziaWG 2.0** — единственный живой WG-flavor, но требует UDP.
5. **Trojan** — decent, но TrojanProbe (2024 paper) показал что active probe определяет подмену.

---

# 3. Сравнительная таблица транспортов

| Транспорт | Пропускная | Латентность | Скрытность | Главный вопрос |
|---|---|---|---|---|
| Чистый TCP | line rate | низкая | 0 | Любая мимикрия поверх |
| TLS 1.3 | line rate | низкая | средняя (JA4 палит) | Нужна аутентичная TLS-стат |
| xTLS + REALITY | line rate (splicing) | низкая | была max, теперь средняя | IP↔DNS correlation |
| mKCP + dTLS | средняя (FEC overhead) | очень низкая | низкая | Оптимизирован под lossy, не стелс |
| **gRPC** | средняя 150-300 Mbit/s | средняя (H2 framing) | хорошая | **LEGACY. Xray team мигрирует с gRPC на xHTTP** |
| WebSocket | средняя | средняя | хорошая | Overhead на фреймы, HoL |
| **xHTTP packet-up** | **высокая** | низкая | **очень хорошая** | Best против 15-20KB лимита |
| **xHTTP stream-up** | высокая | низкая | хорошая | 2 long connections |
| xHTTP stream-one | высочайшая (как gRPC без overhead) | низкая | хорошая | Ломается на 15-20KB |
| DNS TT | очень низкая | высокая | максимальная | Не для видео |
| CDN fronting | высокая | средняя | максимальная (IP Cloudflare) | Требует доверия к CDN, блок целыми префиксами |
| SNI fronting | высокая | низкая | высокая | Устарело: CDN отвергают mismatched SNI/Host |

## gRPC vs xHTTP — ВЕРДИКТ

**НЕ использовать gRPC.** Официальная позиция Xray team (2024-2025): xHTTP — замена gRPC. gRPC страдает от:
1. Protobuf framing overhead 5-10%
2. Единый bidirectional stream → HoL blocking
3. Пробивает 15-20KB TSPU limit
4. Специфичные headers (`content-type: application/grpc`, gRPC trailers) легко распознать

**xHTTP packet-up** атакует 15-20KB limit архитектурно. **Это и есть направление для грааля.**

---

# 4. Физика скорости VPN

```
throughput = min( crypto_ceiling, syscall_rate × pkt_size, cwnd × 1/RTT )
```

## Что разгоняет
- **Zero-copy splicing** (xTLS Vision): inner TLS не пере-шифруется, +60-80%
- **Batch io_uring + IORING_OP_WRITEV**: 8-40× меньше syscall'ов
- **UDP без ретрансмитов** (WG, QUIC): один слой recovery vs TCP-over-TCP ×2-3 штраф
- **TUN multiqueue с flow-hash**: один flow → один core → нет reorder → нет retransmit шторма
- **Brutal CC** (H2): игнорирует потери (работает в UDP, вреден в TCP-over-TCP)
- **GRO/GSO** large MTU: одна big write вместо 40 маленьких

## Что тормозит
- Per-packet syscall (ceiling ~20k pps ≈ 240 Mbit/s)
- Мало CPU cores × много TLS streams (ghoststream v0.17.2 на 2-core с N_STREAMS=4)
- Один TCP в оба направления (gRPC, stream-one, VLESS single): HoL blocking в TLS record layer
- Per-packet copy в BytesMut (ghoststream tun_uring.rs:98-99)
- Round-robin multiqueue (ghoststream tun_uring.rs:219-230) ломает flow affinity

## Почему VLESS+Vision быстрее всех:
Zero-copy splicing работает ТОЛЬКО для L4 proxy (inner TCP). L3 VPN (наш случай) так не умеет — TUN принципиально требует rewrap.

## Почему Hysteria2 теоретически быстрее WG:
Brutal CC + QUIC multiplexing на идеальной сети. В реальной РФ-мобиле UDP режется, бесполезно.

## Почему gRPC медленнее xHTTP:
gRPC = один bidirectional H2 stream = HoL в рамках одного потока. xHTTP packet-up разбивает направления, HoL исчезает параллелизмом коннектов.

---

# 5. Исследования traffic shaping (2024-2025)

- Constant bandwidth utilization + uniform packet sizes = 95%+ VPN detection accuracy
- Padding countermeasure costs 5-15% bandwidth
- Warmup mimicry (только первые 5-10 сек) не ест steady-state пропускную

---

# 6. Ключевые references к исходникам/источникам

- TrojanProbe paper (2024) — active probing Trojan fingerprint
- habr 990144 — «Почему VLESS обходит блокировки в РФ» (2025)
- AmneziaWG 2.0 release notes (март 2026) — Windscribe, NymVPN adopted
- Xray xHTTP docs — официальная замена gRPC
- TSPU mobile incident reports 2025-2026 — 15-20KB lockout
