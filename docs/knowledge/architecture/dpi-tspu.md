---
updated: 2026-07-05
---

# ТСПУ / DPI — модель детекта и стратегия обхода

Как российский ТСПУ (техническое средство противодействия угрозам, инлайн-DPI на
каждом ISP по закону о суверенном рунете) детектит VPN/proxy, чем это подтверждается
эмпирически, почему GhostStream палится и что с этим делать.

> Источник данных: deep-research 2026-07-05 (academic + net4people/ntc.party + XTLS
> issues) + натурные тесты с реального устройства (Samsung S25 Ultra, MegaFon LTE,
> Дагестан, `adb` через `--interface rmnet_data0`). Полный отчёт и заметки —
> в истории сессии; ключевые пруфы ниже.

## TL;DR

ТСПУ **не** сверяет SNI с IP (это миф) и **не** блокирует зарубежные IP на L3 огулом.
Детект — **многофакторный** и работает по двум осям: **(1) насколько трафик похож на
честный HTTPS к обычному серверу** и **(2) куда идёт первый хоп — в РФ или за рубеж**.
Комбинация решает исход: honest-TLS на свой домен = живёт; очевидный протокол
(WireGuard) = throttle к РФ / kill за рубеж; подозрительный TLS (raw-fingerprint,
N параллельных коннектов) = freeze.

**Робастный ответ — каскад через российский whitelisted-ASN VPS** (у GhostStream уже
есть: RU-relay). На этом honest-канале выживание решают **браузерный uTLS-fingerprint**
и **один мультиплексированный коннект вместо N параллельных**.

## 0. ПОПРАВКА 2026-07-31 — троттл оказался лимитом на IP, а не DPI-детектом

Всё, что ниже про fingerprint/поведение/SNI как причину **низкой скорости GhostStream**, —
опровергнуто прямым измерением. Разделы 1-2 (механизмы детекта, развенчанные мифы) остаются
верными как модель ТСПУ в целом; неверна была атрибуция **нашего** симптома.

Измерено с того же телефона и той же линии (MegaFon), обычным одиночным HTTPS-скачиванием
с python-сервера — **без GhostStream, без mux, без mTLS, без padding**:

| Путь до relay `89.169.175.55` | Скорость |
|---|---|
| с NL-сервера (`.128`) | 57 МБ/с |
| из домашней сети пользователя | 34 МБ/с |
| **с мобильной сети** | **15 КБ/с** |
| _мобильная сеть → `mirror.yandex.ru`, тот же момент_ | _5,06 МБ/с_ |

Контрольные срезы: honest SNI (`relay.bikini-bottom.com`, имя резолвится в тот же IP,
валидный LE-серт) — **15 КБ/с**; порт 9443 вместо 443 — **15 КБ/с**; четыре свежих коннекта
подряд — по 15 КБ/с каждый с первой секунды, без начального всплеска; 60 с на одном коннекте —
901 КБ ровным потоком, то есть это **rate limit, а не volume-freeze**.

**Вывод: оператор режет трафик к конкретному IP `89.169.175.55` до ~15 КБ/с.** Не зависит от
порта, SNI, протокола, числа коннектов и fingerprint. VM и её маршруты здоровы (57/34 МБ/с в
другие стороны). Соседний RU-хост в другом диапазоне Yandex Cloud (`158.160.135.140`) на этой
же линии даёт мегабайты — там работает v2raytun.

### Развязка — реле переехало на `.140`, стало 6 МБ/с

Перевёл клиентский профиль на реле `158.160.135.140` (там уже стоял `phantom-relay` за
nginx, `expected_sni` совпадал; понадобилось только `upstream_addr :443 → :8443`). Результат
с той же мобильной линии: **6,0-6,4 МБ/с** через туннель, выход `91.84.109.85` (AMS, NL).
Против 15 КБ/с через `.55` — рост в ~400×. То есть режется именно адрес `89.169.175.55`,
а не подсеть Yandex Cloud и не наш протокол.

### Второй дефект, вскрывшийся сразу за первым: IPv6 + Private DNS strict

После переезда туннель качал 6 МБ/с **по IP**, но любое имя не резолвилось
(`ping: unknown host`). Причина — наша:

- `tun0` получает только link-local IPv6 (`fe80::…`), глобального v6 нет;
- при этом `::/0` **захвачен** в туннель (`default dev tun0`) — killswitch против v6-утечки;
- на устройстве включён **Private DNS strict** (`private_dns_mode=hostname`,
  `xbox-dns.ru`), и его `ValidatedPrivateDnsAddresses` содержат v6-адреса;
- TCP к DoT-серверу по IPv6 падает мгновенно (`connect=0.000000`), по IPv4 работает
  (`connect=0.062`). В strict-режиме резолвер fail-closed → DNS умирает целиком.

На Wi-Fi это не проявлялось: домашняя сеть отдаёт только ULA-v6 без v6-интернета, поэтому
Android брал IPv4. Итого симптом «VPN не работает» = сломанный DNS, а не скорость.

Обходится мгновенно: Private DNS → «Автоматически» (DNS туннеля 8.8.8.8/1.1.1.1 идут в NL).
Правильное решение в коде — либо давать `tun0` ULA-v6 адрес, либо выносить адреса
Private-DNS-сервера в direct-список. Выбор между приватностью и работающим DNS — за владельцем.

Следствия для стратегии в разделе 5:
- **Рычаг #1 (uTLS fingerprint) — не решает эту проблему.** Эмпирика «boring chrome/firefox не
  помогли» объясняется не «аппроксимацией отпечатка», а тем, что причина была вне TLS.
- **Гипотеза SNI↔IP mismatch — опровергнута.** Honest SNI даёт ту же скорость.
- **Реально работает только смена IP реле** (новый публичный адрес, другой диапазон, либо
  IPv6 — у обоих серверов его сейчас нет). Это операция в консоли провайдера, не правка кода.
- Правильный первый шаг в диагностике «медленно» — **измерить сырой HTTPS до того же IP с той
  же линии** и сравнить с известно-быстрой целью. Это 2 минуты и снимает весь класс гипотез
  про протокол. Мы вместо этого месяц перебирали fingerprint, mux, padding и mTLS.

## 1. Механизмы детекта (подтверждённые)

| Механизм | Триггер | Действие | Где бьёт |
|---|---|---|---|
| **Foreign-ASN + volume-freeze** | dest в Hetzner/DO/OVH/зарубеж-хостинг + **>~15-20 КБ на одном TLS-коннекте** | «заморозка» потока (тихий drop пакетов, **без RST**) | прямой коннект на зарубежный VPS; хендшейк проходит, туннель умирает как пошли данные |
| **Мобильный IP/CIDR whitelist** | dest-IP не в allow-list оператора (MegaFon/MTS/…), особенно в «учения»/шатдауны | drop пакетов к IP независимо от SNI/протокола | любой зарубежный VPS в whitelist-окне |
| **TLS connection velocity** | **>3 одновременных TLS-хендшейка к одному endpoint за 60с** | freeze ~120с; смена fingerprint после freeze → ~600с на все TLS | N параллельных коннектов к одному хосту/SNI |
| **uTLS ClientHello fingerprint** | JA3/JA4 классифицируется независимо от SNI/IP | suspicious→freeze | `chrome/safari/ios` — **подозрительны**; `firefox/android/okhttp/edge/qq` — **терпимы**. Смена fingerprint восстанавливает мёртвый коннект на том же IP/SNI/порту |
| **ASN/subnet reputation** | сожжённые подсети/домены | drop/freeze | REALITY на зарубежные бренды (microsoft/apple) — блок; домашние высокочастотные SNI (eh.vk.com, ads.x5.ru) — стабильнее |
| **Behavioral TLS policing** | proxy-подобный устойчивый bidirectional поток на :443 | freeze циклами ~60с | длинные bulk-туннели; обычный HTTPS-браузинг не трогает |
| **SNI-blocklist** | SNI в чёрном списке | RST сразу после ClientHello | заблокированные домены (не bikini-bottom пока) |
| **ECH** | outer SNI `cloudflare-ech.com` + ECH-extension вместе | drop | ECH в РФ **провоцирует** блок, а не помогает |

Ключевое: **SNI-фильтр и IP-фильтр — независимые слои**. «Любой SNI работает на
whitelisted IP без корреляции» — поэтому domain-fronting не «палится по SNI≠IP», он
просто не нужен (на whitelisted IP и так всё проходит), а на не-whitelisted — дропается
IP независимо от SNI.

## 2. Что НЕ является механизмом (развенчано)

- **«ТСПУ сверяет домен-под-который-косишь и реальный IP» — миф.** Ни один источник
  не описывает passive-DNS-корреляцию или активный резолв SNI как deployed-правило.
  Люди с SelfSteal (SNI==домен==свой IP, валидный серт) всё равно ловили freeze.
  GFW (более продвинутый цензор) режет QUIC чисто по SNI, **игнорируя IP**.
  Наблюдение «честный домен живёт, REALITY-на-чужой-SNI дохнет» — **верное**, но
  причина не SNI↔IP, а foreign-ASN + volume + fingerprint + reputation.
- **«Зарубежный IP блокируется на L3» — неверно.** Живой зарубежный VPS (poland,
  Hostkey PL) с честным TLS отвечает с MegaFon за 175мс (см. эмпирику). Блокирует
  не «зарубежность IP», а *foreign-ASN + объём/поведение* или *whitelist-окно*.
- **mTLS — не палевный признак.** В TLS 1.3 `CertificateRequest`/клиентский серт
  зашифрованы; сервер к тому же `allow_unauthenticated()`. Пассивно невидим.

## 3. Эмпирика 2026-07-05 (MegaFon LTE, raw cellular)

| Тест | SNI | IP назначения | Результат |
|---|---|---|---|
| google (контроль) | www.google.com | Google CDN | ✅ TCP+TLS+200 |
| honest → poland (live foreign) | poland.bikini-bottom.com | 82.38.66.138 (PL, Hostkey) | ✅ TCP+TLS+200 за 175мс |
| mismatch → poland (domain-front) | www.microsoft.com | 82.38.66.138 | TCP ок, TLS `UNRECOGNIZED_NAME` **от сервера** (не ТСПУ) |
| honest → vdsina NL **:443** | tls.nl2.bikini-bottom.com | 89.110.109.128 (NL) | ⛔ SYN проходит, TLS не завершается — **фильтрация по IP:порт на RU-стороне** (см. поправку ниже) |
| honest → vdsina NL **:8443** | tls.nl2.bikini-bottom.com | 89.110.109.128 (NL) | ✅ TCP+TLS+200 за ~150 мс, серт валиден |
| → relay | tls.nl2.bikini-bottom.com | 89.169.175.55 (RU Yandex) | ✅ TCP+TLS+200, стабильно 6/6 |
| **12 параллельных TLS** → relay | одна SNI | 89.169.175.55 | ✅ **все 12 прошли**, линия не замёрзла |

**Вывод эмпирики: на этапе установки соединения не блокируется НИЧЕГО** — ни зарубежный
IP, ни SNI-mismatch, ни honest-TLS, ни даже 12 параллельных к RU-relay (чистый Yandex
ASN снисходителен). Значит блок GhostStream — **на устойчивом потоке** (fingerprint +
поведение), а не на handshake.

ASN участников: relay `89.169.175.55` и balancer `158.160.135.140` — **RU, Yandex.Cloud
AS200350** (whitelisted-friendly). poland `82.38.66.138` — PL Hostkey. vdsina
`89.110.109.128` — NL, **жив**.

> **Поправка 2026-07-31 — «vdsina мёртв» было неверно.** Хост жив (uptime 14 суток,
> `phantom-server.service` active). Из РФ фильтруются **ровно порты 22 и 443** этого IP:
> SYN проходит, дальше тишина без RST. Порты 80/3443/8443/8444 того же IP отвечают
> нормально; контрольные `1.1.1.1:443` и `google:443` с тех же хостов — за 60-160 мс.
> На самом хосте `ufw inactive`, в `iptables -S` нет DROP/REJECT для 22/443 — значит
> фильтрация не хостовая. Проверено с двух независимых RU-хостов (`.55`, `.140`).
>
> Практическое следствие: **upstream реле к NL-exit обязан быть `:8443`**, не `:443`.
> Ложный диагноз «сервер мёртв» вывел NL-exit из ротации примерно на месяц —
> первичный симптом (TCP timeout на :443 + мёртвый SSH) выглядел как падение хоста,
> и вторая гипотеза не проверялась. Урок: при «хост мёртв» пробивать **несколько
> портов**, а не только тот, что используется.

### Throughput A/B — решающее доказательство (тот же тест, живой GhostStream)

Поднял GhostStream (профиль s25, `phone→relay .55→exit poland .138`), прогнал bulk:

| Что качаю (bulk) | ASN назначения | Скорость |
|---|---|---|
| Yandex mirror (сырьё, мимо туннеля) | Yandex AS200350 | **5.76 МБ/с (~46 Мбит/с)**, 115 МБ |
| **GhostStream туннель** → relay .55 | **тот же Yandex AS200350** | **~13 КБ/с** (0.1 Мбит/с) |
| Hetzner DE (сырьё) | Hetzner (foreign hosting) | **0 Б/с — блэкхол, TCP не встаёт** |
| Cloudflare (сырьё) | Cloudflare (foreign CDN) | 62 Б/с (задушен) |

GhostStream в момент нагрузки сам рапортует `health:"degraded", bandwidth_class:"throttled"`;
на idle возвращается в `normal`. **Режим падения — не блок, а жёсткий ТРОТТЛ** (как WG,
только сильнее: ~0.1 Мбит/с против 20-30 у WG).

**Изоляция причины:** канал MegaFon быстрый (46 Мбит/с к Yandex). GhostStream идёт на
relay в **том же Yandex ASN** — и всё равно режется в 3500×. Единственное отличие от
быстрого Yandex-mirror — **природа трафика**: proxy-туннель (rustls-fingerprint +
8 параллельных TLS + устойчивый bidirectional). Значит троттлит **behavioral/fingerprint
proxy-классификатор**, НЕ ASN и НЕ handshake. Это ровно то, что рабочий VLESS+TCP
пользователя обходит браузерным fingerprint'ом + одним mux-коннектом, а GhostStream — нет.
Foreign-ASN блок тоже подтверждён (Hetzner=0) → «direct-to-foreign» и WG-на-зарубеж мертвы
по этой причине.

### Эксперименты с рычагами 2026-07-05 (build+install+adb harness)

Собрал tunable-клиент (policy пушится файлом `/data/local/tmp/gs_policy.json` без пересборки,
см. ADR 0014) и прогнал рычаги на живом устройстве (MegaFon, туннель→relay .55→poland,
цель Cloudflare через туннель; сырая линия для сравнения):

| Конфиг | Скорость через туннель | Δ к baseline |
|---|---|---|
| Baseline (N=8, дефолты) | ~11–13 КБ/с | — |
| **N=2** (streams.count=2) | 12.7 КБ/с | нет эффекта |
| **Padding** (target 1300) | 11.4 КБ/с | нет эффекта |
| **N=2 + padding + fast heartbeat** | 10.8 КБ/с | нет эффекта |
| _сырая линия (Yandex, мимо туннеля)_ | _1.1–3.3 МБ/с_ | _×100–250_ |

**Вердикт (эмпирический, не теоретический):** ни число коннектов (#2), ни padding (#3),
ни heartbeat — **не двигают throttle**. N=2 к тому же ниже порога «>3 хендшейков/60с», но
всё равно душится. Значит троттл — **классификационный (TLS fingerprint / proxy-эвристика
на устойчивом потоке), а не по количеству коннектов или размеру пакетов**. Это совпадает с
полевыми данными [F3] (смена fingerprint chrome→firefox воскрешает мёртвый коннект на том же
IP/SNI). → **Единственный рычаг, который реально снимет троттл, — #1 uTLS браузерный
ClientHello.** #2 (single-conn mux) и #3 (padding) как решение проблемы троттла **исключены
эмпирически** (полезны как гигиена, но не лечат).

**Почему #1 не сделан сразу:** rustls не даёт GREASE/порядок расширений; нужен uTLS-движок
(BoringSSL через `boring`/`tokio-boring`).

### uTLS-эксперименты + v2raytun reference 2026-07-05 (продолжение)

Реализован boring-путь клиентского TLS (policy-gated, `TransportPolicy.fingerprint`;
rustls остаётся дефолтом). Boring собирается под android (cmake), хендшейк работает
end-to-end (mTLS + TLS-in-TLS до poland). Замеры (туннель→relay .55→poland, цель CF):

| Fingerprint клиента | Скорость туннеля |
|---|---|
| rustls (дефолт) | ~11–13 КБ/с |
| boring chrome/okhttp-family (stock, GREASE) | ~12 КБ/с |
| boring firefox (cipher/curve-набор Firefox) | ~11 КБ/с |
| **v2raytun VLESS/TCP (тот же линк, ТОТ ЖЕ exit poland .138)** | **3.7–5.9 МБ/с** |

**Решающий вывод (reference-based):** смена ClientHello-fingerprint (chrome→firefox через
boring) **троттл НЕ снимает**. Но v2raytun-VLESS на **той же линии и том же exit** даёт
**3.7–5.9 МБ/с (×300-500)** → троттл **beatable, и виноваты не линия/exit/fingerprint/
streams/padding**, а то, чем GhostStream **отличается** от VLESS в конструкции туннеля:

1. **mTLS — ведущая гипотеза.** GhostStream шлёт клиентский сертификат (mTLS); VLESS —
   нет (auth = UUID внутри потока, TLS server-only). Это **объясняет, почему смена
   ClientHello не помогла**: аномалия не в ClientHello (JA3/JA4), а в сообщении
   `Certificate` клиента во flight'е — публичные сайты mTLS не делают, и это структурный
   признак «не браузер→сайт», который fingerprint ClientHello не меняет.
2. **Точный uTLS.** Моя boring-firefox — аппроксимация (BoringSSL≠NSS на уровне
   extension-order/record); v2raytun использует настоящую Go-utls (byte-exact). JA4-
   классификатор мог не принять аппроксимацию.
3. **single-conn.** VLESS/TCP — один коннект; GhostStream — N (тест N=2 не помог, но не в
   комбинации с boring).

### mTLS-тест + SNI-consistency (продолжение, on-device)

Проверена гипотеза «mTLS = причина»: клиент — policy `mtls:false` (не шлёт клиентский
серт), сервер — тест-правка (certless→VPN по env `PHANTOM_TEST_CERTLESS_FP`, задеплоено на
poland через compose.override, потом откачено). Туннель поднялся certless (лог сервера
«TEST: certless TLS → VPN», «Authenticated VPN client stream 7/8»), данные пошли.
**Результат: 12.7 / 11.5 КБ/с — как baseline. Убирание mTLS троттл НЕ снимает.**

**Полная таблица исключённого (всё on-device, все ~11-12 КБ/с, при v2raytun 3.7-5.9 МБ/с):**
rustls-fingerprint, boring-chrome, boring-firefox, streams=2, padding, heartbeat, **mTLS-off**.

**DNS-разбор быстрого vs медленного (ключевое отличие после исключения всего выше):**

| | коннект-IP | SNI | SNI резолвится в | итог |
|---|---|---|---|---|
| v2raytun VLESS (**3.7-5.9 МБ/с**) | 158.160.135.140 | balancer.bikini-bottom.com | **158.160.135.140** | **SNI==IP (honest)** |
| GhostStream (**~11 КБ/с**) | 89.169.175.55 (relay) | poland.bikini-bottom.com | **82.38.66.138** | **SNI≠IP (mismatch)** |

**Новая ведущая гипотеза — SNI↔IP mismatch (domain-fronting-паттерн), созданный
raw-passthrough реле.** GhostStream-relay `.55` копирует байты на poland без терминации
TLS, а клиент шлёт SNI poland-домена (резолвится в .138 ≠ .55). v2raytun/xray на `.140`
ТЕРМИНИРУЕТ TLS на СВОём домене (SNI==IP==.140) — honest. Возможна и репутация самого
`.55`; обе причины лечатся одинаково. _(Это частично воскрешает изначальную SNI↔IP-догадку:
на уровне блока SNI/IP — независимые фильтры (net4people), но на уровне ТРОТТЛА mismatch,
похоже, штрафуется.)_

**Следующий шаг (единственный не-исключённый, #4 ADR 0014): relay терминирует TLS на своём
RU-домене** (`relay.bikini-bottom.com`→.55, свой серт, SNI==IP==.55) и реоригинирует
relay→poland — ровно как xray на .140. Тогда phone↔relay = honest TLS-сессия к домену
самого relay. Проверить тем же харнессом (нужна правка+деплой phantom-relay на хост .55).
Вторично: byte-exact uTLS (Go-utls/`fingerprint.raw`), single-conn mux. Каждый — device-smoke.

**Харнесс (готов, переиспользуемый):** `ship-android --bump` собирает+ставит (профиль
автопровизится из `/data/local/tmp/gs_profiles.json` через debug-хук ProfilesStore);
рычаги пушатся `/data/local/tmp/gs_policy.json` без пересборки; boring-fingerprint —
пересборка (компилируется). Замер: `curl` bulk через туннель vs сырьё Yandex.
Тест-скаффолдинг (policy-loader без cfg-гейта в client-android, ProfilesStore seed-хук,
boring `insecure_skip_verify=true`) — убрать/feature-gate перед release.

## 4. Почему GhostStream детектится (ранжировано)

Активный профиль: `phone → relay 89.169.175.55:443 (RU) → exit 82.38.66.138:8443
(poland, живой)`, SNI=`poland.bikini-bottom.com`. Relay — raw `copy_bidirectional`
(TLS end-to-end phone↔exit). Значит на phone↔relay линии ТСПУ видит коннект к **RU
Yandex** (хороший ASN) — volume-freeze (foreign-ASN) не применяется. Остаются:

1. **rustls ClientHello fingerprint** — не браузер вообще (хуже `chrome`, который уже
   подозрителен). Полевые данные: смена fingerprint в одиночку воскрешает мёртвый
   коннект. **Главный подозреваемый.**
2. **N=ядра параллельных TLS-коннектов** к одному relay/SNI → правило «>3 хендшейка/60с»,
   особенно в связке с плохим fingerprint.
3. **Поведение**: устойчивый bulk-туннель, без data-path padding (shaper снят) →
   proxy-подобный профиль под behavioral policing.
4. **SNI-гигиена**: `poland.bikini-bottom.com` — VPN-ассоциированный single-tenant
   домен, резолвится в зарубеж. Пока не SNI-blocked, но «сжигаемый».

НЕ причина: SNI↔IP mismatch, «зарубежный exit» (он релеится, ТСПУ его не видит), mTLS.

## 5. Стратегия обхода

**P0 (максимальный рычаг):**

1. **Браузерный, ТЕРПИМЫЙ uTLS-fingerprint, обновляемый с сервера.** Заменить
   стоковый rustls-hello на реальный браузерный ClientHello — сегодня `firefox`/
   `android`/`okhttp`, **не `chrome`** (терпимый набор со временем инвертируется →
   профиль fingerprint должен пушиться сервером без релиза клиента). В Rust: `boring`
   (BoringSSL) или FFI/uTLS. Самое дешёвое и самое результативное изменение.
2. **Один TLS-коннект + внутренний mux вместо N параллельных TCP+TLS.** Снимает
   velocity-freeze. «Стримы = ядрам» сохраняется как логические mux-стримы внутри
   одного коннекта. Первый хоп — RU-relay, поэтому per-session volume-freeze
   (foreign-ASN) не бьёт → mux здесь чистый выигрыш (снимает противоречие mux vs
   volume-freeze).

**P1:**

3. **Relay — честный TLS-endpoint на СВОЁМ RU-домене** (SNI==домен-relay==IP-relay,
   валидный серт), терминировать TLS на relay и реоригинировать relay→exit. Вместо
   passthrough `poland.bikini-bottom.com` (зарубеж-резолв, single-tenant). Тогда
   phone-side коннект = как рабочий VLESS+TCP пользователя (honest own-domain на RU-IP).
4. **RU-relay обязателен** (никогда direct-to-foreign на мобиле). Уже так; держать
   relay на чистом whitelisted RU-ASN (Yandex ✓).
5. **Шейпинг**: держать поток браузероподобным, избегать чисто-однонаправленного bulk;
   вернуть немного padding/pacing.

**P2 (устойчивость):**

6. Fallback-порт ≠ 443 (policing #546 был только на 443) — минус камуфляж, плюс
   достижимость.
7. XHTTP-подобный split up/down транспорт как альтернативный профиль.
8. Свежие/ротируемые SNI+IP (сожжённые дохнут, чистые пробивают).

## Источники (кратко)

Academic: GFW.report USENIX'23 (fully-encrypted detection), USENIX'24 (TLS-in-TLS),
USENIX'25 (QUIC SNI), TSPU IMC'22. Community/primary: net4people/bbs #490/#516/#546/#417,
XTLS/Xray-core #6293/#4035/#4900/#5332, ntc.party. Практика: Habr 990206/990208/1027276,
computerscot (SelfSteal). Эмпирика: натурные adb-тесты 2026-07-05 (см. историю сессии).

Связано: [transport.md](transport.md), [handshake.md](handshake.md),
[ADR 0002 (Noise→mTLS)](../decisions/0002-noise-to-mtls.md),
[ADR 0003 (H2/TLS/TCP)](../decisions/0003-h2-tls-tcp.md).
