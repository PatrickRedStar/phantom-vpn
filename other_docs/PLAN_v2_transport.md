# План: GhostStream v2 — HTTP/2 транспорт

## Контекст

ТСПУ дросселит QUIC/UDP на потребительских каналах до ~80 Mbps. VLESS+TLS (TCP) даёт 567 Mbps на том же канале. Цель — добавить TCP/TLS+HTTP/2 транспорт, чтобы **убрать зависимость от RU-хоста** и получить 400+ Mbps напрямую с телефона.

Просто обернуть данные в TCP/TLS = клон VLESS. Наша задача — сделать **следующую эволюцию**, устойчивую к будущей блокировке.

### Чем GhostStream HTTP/2 отличается от VLESS

| | VLESS | GhostStream v2 |
|---|---|---|
| Внутри TLS | Бинарный VLESS-заголовок (UUID+version) — **детектируется** | Настоящие HTTP/2 фреймы (HEADERS+DATA) — **неотличим от HTTPS** |
| Шейпинг | Нет — бёрсты случайного размера | Адаптивный (H.264 для QUIC, web-pattern для HTTP/2) |
| Мультиплексинг | 1 поток внутри TLS | 8 HTTP/2 стримов (как gRPC / реальное веб-приложение) |
| Fallback (REALITY) | Проксирует на реальный сайт | Отдаёт реальный HTTP/2 контент (настраиваемый) |
| Транспорт | Только TCP | QUIC (DC↔DC) + HTTP/2 (телефон) — auto-switch |
| DPI-профиль | "зашифрованный туннель" | "веб-приложение с gRPC/streaming API" |

---

## Архитектура

```
Телефон ──TCP/TLS──→ [HTTP/2 стримы] ──→ phantom-server ──→ TUN ──→ интернет
                     POST /v1/tunnel/0..7
                     Content-Type: application/grpc
                     DATA frames = [4B len][batch]

DC-клиент ──QUIC──→ [8 QUIC streams] ──→ phantom-server ──→ TUN ──→ интернет
                    (без изменений)
```

Сервер слушает **оба** транспорта одновременно:
- UDP:8443 → QUIC (существующий)
- TCP:443 → TLS+HTTP/2 (новый)

Общее: session map, TUN dispatch, admin API, batch format, шейпер — всё переиспользуется.

---

## Фаза 0: Извлечение общих типов сессий

**Цель:** Отвязать session management от QUIC, чтобы HTTP/2 мог использовать те же структуры.

### `crates/server/src/session.rs` (НОВЫЙ)

Переносим из `quic_server.rs`:
- `DestEntry`, `StatsSample` — структуры логирования
- `VpnSession` (бывший `QuicSession`) — **убираем** `connection: quinn::Connection`, **добавляем** `close_tx: Mutex<Option<oneshot::Sender<()>>>` для transport-agnostic shutdown
- `VpnSessionMap = Arc<DashMap<IpAddr, Arc<VpnSession>>>`
- `ClientAllowList`, `load_allow_list()`, `cert_fingerprint()`
- `cleanup_task()` — вызывает `close_tx.send(())` вместо `connection.close()`
- `tun_dispatch_loop()` — уже transport-agnostic
- DNS parsing helpers

### `crates/server/src/quic_server.rs` (ИЗМЕНИТЬ)

- Удалить перенесённые типы, импортировать из `session.rs`
- В `handle_connection`: создать `oneshot::channel`, передать `close_tx` в `VpnSession`, в фоне ждать `close_rx` → `connection.close()`
- `session_batch_loop`, `session_write_loop`, `stream_rx_loop` — остаются здесь (QUIC-specific)

### `crates/server/src/admin.rs` (ИЗМЕНИТЬ)

- `session.connection.close(...)` → `session.close_tx.lock().unwrap().take().map(|tx| tx.send(()))`
- Импорты: `VpnSessionMap` из `session.rs`

### `crates/server/src/main.rs` (ИЗМЕНИТЬ)

- `pub mod session;`
- Использовать `session::new_session_map()`

---

## Фаза 1: HTTP/2 сервер

### Зависимости

```toml
# crates/server/Cargo.toml — добавить:
h2           = "0.4"
tokio-rustls = { version = "0.26", features = ["ring"] }

# crates/core/Cargo.toml — добавить:
h2           = "0.4"
tokio-rustls = { version = "0.26", features = ["ring"] }
```

### `crates/core/src/h2_transport.rs` (НОВЫЙ)

Общие константы и TLS config builders:

```rust
pub const H2_TUNNEL_PATH: &str = "/v1/tunnel/";  // + stream index
pub const H2_TUNNEL_MSS: u16 = 1360;             // TCP overhead < QUIC

/// TLS server config для HTTP/2 (ALPN=["h2"], mTLS optional)
pub fn make_h2_server_tls(certs, key, client_ca) -> rustls::ServerConfig

/// TLS client config для HTTP/2 (ALPN=["h2"])
pub fn make_h2_client_tls(skip_verify, server_ca, client_identity) -> rustls::ClientConfig
```

Логика та же что `make_server_config` / `make_client_config` в `quic.rs`, но возвращает `rustls::ServerConfig` / `rustls::ClientConfig` (не Quinn-обёртки), ALPN = `["h2"]`.

### `crates/server/src/h2_server.rs` (НОВЫЙ)

```rust
pub async fn run_h2_accept_loop(
    listener:     TcpListener,
    tls_acceptor: TlsAcceptor,
    tun_tx:       mpsc::Sender<Vec<u8>>,
    sessions:     VpnSessionMap,
    tun_network:  Ipv4Addr,
    tun_prefix:   u8,
    allow_list:   ClientAllowList,
)
```

**Логика:**
1. `listener.accept()` → TCP stream
2. `tls_acceptor.accept()` → TLS stream + извлечение client cert
3. Нет cert → REALITY fallback (отдать реальный HTTP/2 контент)
4. Есть cert → проверка fingerprint → `h2::server::Builder` с большими окнами:
   - `initial_window_size(16MB)`, `initial_connection_window_size(32MB)`
5. Принимаем 8 стримов `POST /v1/tunnel/{0-7}` → отвечаем `200 OK`
6. Создаём `VpnSession`, спауним `session_batch_loop` (из `quic_server.rs` — переиспользуем!)
7. Per-stream TX: `h2::SendStream::send_data(Bytes, false)` — аналог `write_chunk`
8. Per-stream RX: `h2::RecvStream::data()` → буферизуем → парсим `[4B len][batch]`

**REALITY fallback (HTTP/2):**
- Отвечаем `200 OK` с `text/html`, отдаём статический сайт
- В отличие от текущего hardcoded HTML — конфигурируемая директория со статикой

### `crates/server/src/main.rs` (ИЗМЕНИТЬ)

После bind QUIC endpoint, добавить:
```rust
let h2_tls = phantom_core::h2_transport::make_h2_server_tls(certs, key, client_ca)?;
let h2_listener = TcpListener::bind("0.0.0.0:443").await?;  // TCP:443, не конфликтует с UDP
tokio::spawn(h2_server::run_h2_accept_loop(h2_listener, ...));
```

### `crates/core/src/config.rs` (ИЗМЕНИТЬ)

```rust
pub struct ServerConfig {
    // ...existing...
    #[serde(default)]
    pub h2: Option<H2Config>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct H2Config {
    pub listen_addr: Option<String>,   // default: "0.0.0.0:443"
    pub enabled: Option<bool>,         // default: true
}
```

---

## Фаза 2: Linux клиент HTTP/2

### Зависимости

```toml
# crates/client-common/Cargo.toml — добавить:
h2           = "0.4"
tokio-rustls = { version = "0.26", features = ["ring"] }
```

### `crates/client-common/src/h2_handshake.rs` (НОВЫЙ)

```rust
pub async fn connect_h2(
    server_addr: SocketAddr,
    server_name: &str,
    tls_config: Arc<rustls::ClientConfig>,
) -> Result<(h2::client::SendRequest<Bytes>, JoinHandle<()>)>

pub async fn open_tunnel_streams(
    send_req: &mut h2::client::SendRequest<Bytes>,
    n: usize,
) -> Result<Vec<(h2::SendStream<Bytes>, h2::RecvStream)>>
```

Логика:
1. `TcpStream::connect` → `TlsConnector::connect` → TLS stream
2. `h2::client::handshake(tls_stream)` → `(SendRequest, Connection)`
3. Спаун `connection.await` в фоне
4. Для каждого стрима: `POST /v1/tunnel/{i}` → получить `(SendStream, RecvStream)`

### `crates/client-common/src/h2_tunnel.rs` (НОВЫЙ)

```rust
/// RX: HTTP/2 DATA frames → TUN
pub async fn h2_stream_rx_loop(
    mut recv: h2::RecvStream,
    tun_tx: mpsc::Sender<Vec<u8>>,
) -> Result<()>
```

Отличие от QUIC RX: `h2::RecvStream::data()` возвращает `Bytes` чанки (не read_exact). Нужна буферизация:
1. `recv.data().await` → `Some(chunk)`
2. `recv.flow_control().release_capacity(chunk.len())?`
3. Append в `BytesMut` буфер
4. Парсить полные фреймы `[4B len][batch]` из буфера
5. Walk batch → MSS clamp → tun_tx (идентично QUIC RX)

```rust
/// TX: TUN → HTTP/2 DATA frames
pub async fn h2_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<h2::SendStream<Bytes>>,
) -> Result<()>
```

Та же архитектура что `quic_stream_tx_loop`:
1. Dispatcher по flow hash → per-stream каналы
2. Per-stream: `collect_and_batch()` (переиспользовать! тот же шейпер)
3. Write loop: `send.reserve_capacity(len)` → `send.send_data(Bytes, false)`

### `crates/client-linux/src/main.rs` (ИЗМЕНИТЬ)

Добавить `--transport h2` CLI флаг. Branch на transport mode:
- `"quic"` → существующий код
- `"h2"` → TCP connect + SO_MARK + TLS + h2 handshake + h2 tunnel loops

### `crates/core/src/config.rs` (ИЗМЕНИТЬ)

```rust
pub struct ClientConfig {
    // ...existing...
    /// Transport: "quic" (default) | "h2"
    pub transport: Option<String>,
}
```

### Тест: vps_balancer

```bash
# Изменить /etc/phantom-vpn/client.toml на vps_balancer:
transport = "h2"

# Перезапустить клиент
systemctl restart phantom-client.service

# Speedtest
iperf3 -c 10.7.0.1 -t 10 -P 4
speedtest-cli --simple
```

---

## Фаза 3: Android клиент HTTP/2

### Зависимости

```toml
# crates/client-android/Cargo.toml — добавить:
h2           = "0.4"
tokio-rustls = { version = "0.26", features = ["ring"] }
socket2      = "0.5"
```

### `crates/client-android/src/lib.rs` (ИЗМЕНИТЬ)

1. `nativeStart()` — добавить параметр `transport: JString`
2. Для H2 mode: создать TCP сокет через `libc::socket()`, вызвать `VpnService.protect(fd)`, затем connect в async
3. В `run_tunnel()`: branch на transport → использовать `h2_handshake` + `h2_tunnel` из client-common

```rust
// На JNI-потоке (до спауна async):
let tcp_fd = unsafe { libc::socket(AF_INET, SOCK_STREAM, 0) };
env.call_method(&this, "protect", "(I)Z", &[JValue::Int(tcp_fd)])?;

// В async tunnel:
let socket = unsafe { socket2::Socket::from_raw_fd(tcp_fd) };
socket.set_nonblocking(true)?;
socket.connect(&server_addr.into())?;
let tcp = tokio::net::TcpStream::from_std(socket.into())?;
// → TLS → h2 → tunnel loops
```

### Android Kotlin (ИЗМЕНИТЬ)

- `GhostStreamVpnService.kt`: добавить `transport: String` в `external fun nativeStart`
- `VpnProfile.kt`: добавить `val transport: String = "h2"` (default h2 для телефона)
- `ConnStringParser.kt`: парсить `"transport"` из JSON
- `SettingsScreen.kt`: UI-селектор транспорта (опционально)

---

## Фаза 4: Auto-negotiation (будущее)

Клиент пробует QUIC → измеряет throughput за 5 сек → если < 100 Mbps → переключается на HTTP/2. Периодически перепроверяет.

Не входит в текущую реализацию — сначала стабилизируем ручной выбор.

---

## Фаза 5: gRPC protobuf-контейнер (опциональный тюнинг, будущее)

Обернуть VPN-батчи в настоящий gRPC length-prefixed message format:

```
Текущий:   [4B batch_len][batch_plaintext]
gRPC:      [1B compressed=0][4B msg_len][4B batch_len][batch_plaintext]
```

Overhead: +5 байт на фрейм (ничтожно). Зато трафик становится **валидным gRPC** при глубокой инспекции — DPI видит стандартные gRPC-сообщения, а не произвольные бинарные блоки. В связке с `Content-Type: application/grpc+proto` и правильными HTTP/2 HEADERS — полная мимикрия под gRPC-сервис.

Когда делать: после стабилизации HTTP/2 транспорта, если DPI начнёт анализировать содержимое HTTP/2 DATA frames.

---

## Файлы: сводка

| Файл | Действие | Фаза |
|------|----------|------|
| `crates/server/src/session.rs` | НОВЫЙ — общие типы сессий | 0 |
| `crates/server/src/quic_server.rs` | ИЗМЕНИТЬ — убрать общие типы | 0 |
| `crates/server/src/admin.rs` | ИЗМЕНИТЬ — VpnSession.close_tx | 0 |
| `crates/core/src/h2_transport.rs` | НОВЫЙ — TLS config для HTTP/2 | 1 |
| `crates/server/src/h2_server.rs` | НОВЫЙ — HTTP/2 accept + tunnel | 1 |
| `crates/server/src/main.rs` | ИЗМЕНИТЬ — spawn обоих listeners | 1 |
| `crates/core/src/config.rs` | ИЗМЕНИТЬ — H2Config, transport | 1 |
| `crates/core/Cargo.toml` | ИЗМЕНИТЬ — h2, tokio-rustls | 1 |
| `crates/server/Cargo.toml` | ИЗМЕНИТЬ — h2, tokio-rustls | 1 |
| `crates/client-common/src/h2_handshake.rs` | НОВЫЙ — TCP/TLS/H2 connect | 2 |
| `crates/client-common/src/h2_tunnel.rs` | НОВЫЙ — RX/TX loops | 2 |
| `crates/client-common/Cargo.toml` | ИЗМЕНИТЬ — h2, tokio-rustls | 2 |
| `crates/client-linux/src/main.rs` | ИЗМЕНИТЬ — transport flag | 2 |
| `crates/client-android/src/lib.rs` | ИЗМЕНИТЬ — transport param, TCP socket | 3 |
| `crates/client-android/Cargo.toml` | ИЗМЕНИТЬ — h2, tokio-rustls, socket2 | 3 |
| Android Kotlin (4 файла) | ИЗМЕНИТЬ — transport в профиле/JNI | 3 |

---

## Верификация

### Фаза 0+1 (сервер):
```bash
# curl без клиентского серта → REALITY fallback
curl -k --http2 https://89.110.109.128:443/

# curl с клиентским сертом → 200 OK + stream hangs
curl -k --http2 --cert client.crt --key client.key \
  -X POST https://89.110.109.128:443/v1/tunnel/0
```

### Фаза 2 (Linux клиент):
```bash
# На vps_balancer: transport = "h2" в client.toml
iperf3 -c 10.7.0.1 -t 10 -P 4 -R  # target: >400 Mbps
speedtest-cli --simple               # target: >400 Mbps download
```

### Фаза 3 (Android):
```bash
# На телефоне: подключиться через GhostStream (transport=h2)
adb shell curl -o /dev/null -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=50000000
# target: >40 MB/s = 320+ Mbps (vs текущие 6.8 MB/s через QUIC)
```
