---
updated: 2026-04-17
---

# OpenWrt

## Стек

Три артефакта, собранных из [apps/openwrt/](../../../apps/openwrt/):

| Артефакт | Путь | Роль |
|---|---|---|
| `phantom-client-openwrt` | [apps/openwrt/client/](../../../apps/openwrt/client/) | Rust binary (один процесс, без CLI/helper split как на Linux) |
| `ghoststream.sh` | [apps/openwrt/proto/ghoststream.sh](../../../apps/openwrt/proto/ghoststream.sh) | netifd protocol handler, кладётся в `/lib/netifd/proto/` |
| LuCI page | [apps/openwrt/luci/](../../../apps/openwrt/luci/) | Web UI для настройки (htdocs + root) |

Установка в один клик — скрипт
[`apps/openwrt/ghoststream-install.sh`](../../../apps/openwrt/ghoststream-install.sh):
детектит архитектуру, скачивает нужный binary из GitHub Release, ставит netifd
proto + LuCI, регистрирует UCI-конфиг.

```sh
wget -O /tmp/gs-install.sh \
  https://github.com/PatrickRedStar/phantom-vpn/releases/latest/download/ghoststream-install.sh && \
  sh /tmp/gs-install.sh
```

## CI — cross-compile

Workflow [`.github/workflows/openwrt.yml`](../../../.github/workflows/openwrt.yml)
собирает binary для четырёх архитектур:

| Target | Toolchain | Build method |
|---|---|---|
| `mipsel-unknown-linux-musl` | nightly | `-Z build-std` (rust-src), cross-rs |
| `aarch64-unknown-linux-musl` | stable | cargo-zigbuild |
| `armv7-unknown-linux-musleabihf` | stable | cargo-zigbuild |
| `x86_64-unknown-linux-musl` | stable | cargo-zigbuild |

## MIPS build — специфика

Самая болезненная цель, несколько критичных моментов (коммиты `3fb1d41`,
`15f5e7a`, `48103b6`):

- **`aws-lc-rs` отключён** — musl MIPS не дружит с его asm; остаётся только
  `ring` как crypto provider для rustls.
- **musl-cc toolchain** — cross-rs Docker image с musl-libc, не glibc.
- **`cargo-zigbuild` НЕ работает для mipsel** — используется классический cross-rs.
- **nightly + `-Z build-std`** — `rust-std` для mipsel-musl не распространяется как
  precompiled, приходится собирать std самим на nightly.

## Установка (UCI + netifd)

Конфиг регистрируется как netifd-интерфейс:

```sh
# /etc/config/network
config interface 'vpn'
    option proto 'ghoststream'
    option connection_string 'ghs://...'
    option mtu '1350'
```

Или CLI:

```sh
uci set network.ghoststream=interface
uci set network.ghoststream.proto=ghoststream
uci set network.ghoststream.connection_string='ghs://...'
uci commit network
ifup ghoststream
```

### Что делает `ghoststream.sh` (netifd proto)

1. `proto_ghoststream_init_config` — объявляет опции (`connection_string`, `mtu`).
2. `proto_ghoststream_setup` при `ifup`:
   - парсит tun_addr через `/usr/bin/ghoststream --print-tun-addr "$connection_string"`
   - имя TUN: `gs-<config_name>`
   - запускает daemon `ghoststream --conn-string ... --tun-name gs-... --mtu ...`
   - ждёт появления TUN в `/sys/class/net/` (до 15 сек)
   - `proto_add_ipv4_address`, `proto_add_dns_server` (gateway первым IP в /24)
   - **default route НЕ добавляется скриптом** — настраивается через LuCI
     метриками интерфейсов (VPN interface должен иметь меньший metric чем WAN).
3. `proto_ghoststream_teardown` — `proto_kill_command` убивает daemon, netifd
   сам снимает IP и DNS.

## LuCI page

Веб-страница в `apps/openwrt/luci/`:
- `htdocs/luci-static/resources/` — JS/CSS ассеты.
- `root/usr/share/` — LuCI manifest + i18n.

Показывает: connection_string (с возможностью вставить / сгенерировать), MTU,
routing metric hint, статус интерфейса.

## Архитектурные особенности

- **TUN — через `tun_simple`** (blocking read/write), не io_uring. Старые ядра
  OpenWrt (5.4+) не везде имеют working io_uring; кроме того, io_uring требует
  memlock limits, которые на embedded не настроены.
- **Один процесс** — нет split'а на CLI/helper/GUI как на Linux. OpenWrt запускает
  `phantom-client-openwrt` напрямую из netifd-скрипта, привилегии получает от
  самого netifd (root).
- **Conn-string first** — OpenWrt не работает с toml-конфигом, только `ghs://`.
  Парсинг: `ghoststream --print-tun-addr` → используется и в netifd-скрипте,
  и внутри daemon'а.
- **Route metric vs default route** — принципиальное отличие от Linux CLI:
  скрипт не добавляет default route, чтобы не ломать роутинг OpenWrt'а.
  Пользователь настраивает через LuCI metric (чем ниже, тем приоритетнее).

## Критичные pitfalls

- **Размер бинаря** — важно на MIPS-роутерах с 16 MB flash. Релизные бинари
  стрипаются (`strip = true` в Cargo.toml), чтобы уложиться в бюджет.
- **io_uring недоступен** — не пытайтесь включать `TunIo::Uring`, упадёт на
  `io_uring_setup` с ENOSYS на большинстве OpenWrt-ядер.
- **DNS server на gateway** — `ghoststream.sh` добавляет первый IP подсети как
  DNS resolver; если сервер не проксирует UDP:53, клиенты за роутером не
  резолвят имена.
- **Metric interaction с WAN** — если VPN interface metric больше WAN'а, traffic
  идёт мимо туннеля. Стандартный gotcha при установке.
- **`available=1` + `no_device=1`** в netifd — обязательно, иначе netifd ждёт
  физического интерфейса, которого у gostream нет (создаётся daemon'ом).
- **MIPS: musl tls thread-locals** — rust std нормально, но некоторые deps
  (напр. прежние версии ring) падали; фиксировано в lockfile, не ослаблять
  версии криптокрейтов без тестового rebuild под MIPS.

## Релизный процесс

OpenWrt артефакты собираются в `openwrt.yml` на каждый тег `v*` — результат
кладётся в GitHub Release как:

- `ghoststream-mipsel` / `-aarch64` / `-armv7` / `-x86_64` — бинари
- `ghoststream-install.sh` — installer, тянет binary по архитектуре

После релиза юзер обновляется тем же one-liner'ом. Теги (versionCode analogue)
не ведутся — OpenWrt берёт latest release из GitHub.

## Sources

- **OpenWrt client:** [apps/openwrt/client/](../../../apps/openwrt/client/)
- **netifd proto:** [apps/openwrt/proto/ghoststream.sh](../../../apps/openwrt/proto/ghoststream.sh)
- **LuCI UI:** [apps/openwrt/luci/](../../../apps/openwrt/luci/)
- **Installer:** [apps/openwrt/ghoststream-install.sh](../../../apps/openwrt/ghoststream-install.sh)
- **CI workflow:** [.github/workflows/openwrt.yml](../../../.github/workflows/openwrt.yml)
- **Runtime (shared):** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **gitnexus:** `gitnexus_query({query: "openwrt netifd proto"})`, `gitnexus_query({query: "tun simple fallback"})`
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
