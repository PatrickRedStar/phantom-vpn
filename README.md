# PhantomVPN 👻

PhantomVPN — это кастомный VPN протокол, который маскирует свой трафик под WebRTC/SRTP (видеозвонки). Это позволяет успешно обходить системы DPI (Deep Packet Inspection) и ТСПУ, так как трафик выглядит как обычный зашифрованный H.264 видеопоток поверх QUIC/HTTP3.

## Особенности
* Транспорт: **QUIC/UDP** (ALPN `h3` — выглядит как HTTP/3, обычно порт 443 или 8443).
* Маскировка: TLS 1.3 + QUIC + шейпинг пакетов под кодек **H.264** (I/P-кадры).
* Криптография: **TLS 1.3** на уровне QUIC + **Noise Protocol IK** (ChaCha20-Poly1305, BLAKE2s) поверх control stream для аутентификации клиента.
* Аутентификация клиента: **mTLS** — клиент предъявляет сертификат, подписанный серверным CA.
* Шейпинг трафика: Имитация распределения кадров **H.264** (30 fps, GOP=60, I-кадры 15–50 KB, P-кадры ~1–4 KB).
* Кроссплатформенный клиент: **Linux** (`/dev/net/tun`), **macOS** (`utun`/`AF_SYSTEM`), **Android** (JNI + TUN).
* Встроенная панель управления: HTTP Admin API на туннельном IP (10.7.0.1:8080), доступен только через VPN.

---

## One-click deploy на сервер

Каноничный способ развернуть/обновить сервер:

```bash
cd phantom-vpn
bash ./scripts/deploy.sh root@<server-host> ~/.ssh/personal
```

Пример:

```bash
bash ./scripts/deploy.sh root@89.110.109.128 ~/.ssh/personal
```

Что делает `scripts/deploy.sh`:

- локально собирает `phantom-server` и `phantom-keygen`;
- копирует бинарники и `keys.py` в `/opt/phantom-vpn`;
- на пустом хосте создаёт `/opt/phantom-vpn/config` и ставит runtime-зависимости;
- унифицирует systemd на `phantom-server.service` (legacy `phantom-vpn.service` отключается);
- запускает/перезапускает сервис и печатает health-check;
- проверяет `keys.py` командой `python3 /opt/phantom-vpn/keys.py --help`.

Политика синка конфига:

- если локально есть `config/server.toml` — он перезаписывает `/opt/phantom-vpn/config/server.toml` на хосте;
- если `config/server.toml` нет, но есть `config/server.example.toml` — синкается только шаблон, а `server.toml` создаётся на хосте только если ещё отсутствует.

Dry run:

```bash
bash ./scripts/deploy.sh root@<server-host> ~/.ssh/personal --dry-run
```

Управление ключами на сервере:

```bash
ssh root@<server-host> "python3 /opt/phantom-vpn/keys.py --server-config /opt/phantom-vpn/config/server.toml --keyring /opt/phantom-vpn/config/clients.json"
```

---

## 🛠 Установка зависимостей

Для сборки проекта потребуется **Rust**:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

Склонируйте репозиторий и перейдите в него:
```bash
cd phantom-vpn
```

---

## 🔑 Генерация ключей

VPN использует асимметричную криптографию. Сначала сгенерируйте ключи:
```bash
cargo run --release --bin phantom-keygen
```
Вывод будет выглядеть так:
```text
=== Server Keys ===
Private: <SERVER_PRIVATE_KEY>
Public:  <SERVER_PUBLIC_KEY>

=== Client Keys ===
Private: <CLIENT_PRIVATE_KEY>
Public:  <CLIENT_PUBLIC_KEY>

=== Shared Secret (Optional PSK) ===
Secret:  <SHARED_SECRET>
```
Сохраните эти значения.

---

## 🖥 Настройка и запуск Сервера (Linux)

Сервер работает только на Linux, так как использует стандартный TUN интерфейс и `iptables` для NAT.

1. Отредактируйте конфиг сервера `config/server.toml`:
   ```toml
   [network]
   listen_addr = "0.0.0.0:8443"
   tun_name    = "tun0"
   tun_addr    = "10.7.0.1/24"
   tun_mtu     = 1380
   wan_iface   = "eth0" # Укажите ваш внешний сетевой интерфейс (например, ens3 или eth0)

   [keys]
   server_private_key = "<SERVER_PRIVATE_KEY>"
   server_public_key  = "<SERVER_PUBLIC_KEY>"
   shared_secret      = "<SHARED_SECRET>"
   ```

2. Соберите серверный бинарник:
   ```bash
   cargo build --release -p phantom-server
   ```

3. Запустите сервер (требуются права root для создания `tun0` и правил `iptables`):
   ```bash
   sudo ./target/release/phantom-server -c config/server.toml -v
   ```
   *Для работы в фоне используйте `nohup` или создайте systemd-сервис.*

---

## 💻 Настройка и запуск Клиента (macOS / Linux)

Для клиентской машины нужно указать публичный ключ сервера и ключи самого клиента.

1. Отредактируйте конфиг клиента `config/client.toml`:
   ```toml
   [network]
   server_addr = "IP_АДРЕС_СЕРВЕРА:8443"
   tun_name    = "tun0"
   tun_addr    = "10.7.0.2/24"
   tun_mtu     = 1380
   default_gw  = "10.7.0.1"

   [keys]
   client_private_key = "<CLIENT_PRIVATE_KEY>"
   client_public_key  = "<CLIENT_PUBLIC_KEY>"
   server_public_key  = "<SERVER_PUBLIC_KEY>"
   shared_secret      = "<SHARED_SECRET>"
   ```

2. Соберите клиент под вашу платформу:
   **Для macOS:**
   ```bash
   cargo build --release -p phantom-client-macos
   ```
   **Для Linux:**
   ```bash
   cargo build --release -p phantom-client-linux
   ```

3. Запустите клиент (потребуется ввод пароля `sudo` для настройки маршрутизации и `utun`/`tun` интерфейса):
   **На macOS:**
   ```bash
   sudo ./target/release/phantom-client-macos -c config/client.toml -vv
   ```
   **На Linux:**
   ```bash
   sudo ./target/release/phantom-client-linux -c config/client.toml -vv
   ```

В отдельном окне терминала можно запустить:
```bash
# Проверка связности:
ping 10.7.0.1

# Проверка маскировки IP (трафик идет через сервер):
curl https://ifconfig.me
```

---

## ⚡️ Тестирование скорости (iperf3)

Чтобы проверить пропускную способность туннеля, используйте утилиту `iperf3`.

**На сервере:**
```bash
# Установите iperf3
apt install iperf3

# Запустите iperf3 в режиме сервера, слушая на IP туннеля
iperf3 -s -B 10.7.0.1
```

**На клиенте:**
```bash
# Установите iperf3 (на macOS через Homebrew: brew install iperf3)
iperf3 -c 10.7.0.1 -P 4
```
Флаг `-P 4` запускает тест в 4 параллельных потока для максимальной нагрузки на туннель.
