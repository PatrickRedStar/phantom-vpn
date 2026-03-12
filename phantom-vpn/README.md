# PhantomVPN 👻

PhantomVPN — это кастомный VPN протокол, который маскирует свой трафик под WebRTC/SRTP (видеозвонки). Это позволяет успешно обходить системы DPI (Deep Packet Inspection) и ТСПУ, так как трафик выглядит как обычный зашифрованный H.264 видеопоток по UDP.

## Особенности
* Транспорт: **UDP** (порт 3478, стандартный для STUN/WebRTC).
* Маскировка: Пакеты заворачиваются в фейковые заголовки **SRTP**.
* Криптография: **Noise Protocol (IK)** + **ChaCha20-Poly1305** для 0-RTT рукопожатия и быстрого шифрования.
* Шейпинг трафика: Имитация распределения кадров (I-frames и P-frames) кодека **H.264**.
* Кроссплатформенный клиент: Поддержка **Linux** (через `/dev/net/tun`) и **macOS** (через `utun` / `AF_SYSTEM`).

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
   listen_addr = "0.0.0.0:3478"
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
   server_addr = "IP_АДРЕС_СЕРВЕРА:3478"
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
