# GhostStream OpenWrt Client — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Создать клиент GhostStream для OpenWrt роутеров с полноценной LuCI интеграцией и one-liner установкой.

**Architecture:** Новый Rust crate `client-openwrt` — минимальный VPN-демон без io_uring (plain read/write TUN). Интегрируется в OpenWrt как netifd protocol handler с LuCI proto page. Установка через shell-скрипт, который определяет архитектуру и скачивает нужный бинарник из GitHub Releases.

**Tech Stack:** Rust (musl static), shell (netifd proto handler), JavaScript (LuCI protocol module), UCI (конфигурация), fw4/nftables (firewall).

**Spec:** `docs/superpowers/specs/2026-04-12-ghoststream-openwrt-design.md`

---

## File Structure

### New files

| File | Purpose |
|------|---------|
| `crates/core/src/tun_simple.rs` | Plain read/write TUN I/O (fallback без io_uring) |
| `crates/client-openwrt/Cargo.toml` | Crate manifest для OpenWrt клиента |
| `crates/client-openwrt/src/main.rs` | Точка входа: парсинг args, запуск tunnel |
| `openwrt/proto/ghoststream.sh` | netifd protocol handler |
| `openwrt/luci/htdocs/luci-static/resources/protocol/ghoststream.js` | LuCI proto page |
| `openwrt/luci/root/usr/share/rpcd/acl.d/luci-proto-ghoststream.json` | RPCD ACL для LuCI |
| `ghoststream-install.sh` | One-liner инсталлятор |
| `.github/workflows/openwrt.yml` | CI: cross-компиляция 4 архитектур |

### Modified files

| File | Change |
|------|--------|
| `crates/core/Cargo.toml` | Feature flag `io-uring-tun` (default), `tun-simple` |
| `crates/core/src/lib.rs` | Условный экспорт `tun_simple` модуля |
| `Cargo.toml` (workspace) | Добавить `client-openwrt` в members |

---

## Task 1: Feature flag io_uring в phantom-core + tun_simple модуль

**Files:**
- Modify: `crates/core/Cargo.toml`
- Modify: `crates/core/src/lib.rs`
- Create: `crates/core/src/tun_simple.rs`

- [ ] **Step 1: Добавить feature flags в core/Cargo.toml**

```toml
# В секции [features] (добавить):
[features]
default = ["io-uring-tun"]
io-uring-tun = ["io-uring"]

# Изменить секцию зависимости io-uring:
[target.'cfg(target_os = "linux")'.dependencies]
io-uring = { version = "0.7", optional = true }
```

- [ ] **Step 2: Обновить lib.rs — условный экспорт**

В `crates/core/src/lib.rs` заменить:
```rust
#[cfg(target_os = "linux")]
pub mod tun_uring;
```
На:
```rust
#[cfg(all(target_os = "linux", feature = "io-uring-tun"))]
pub mod tun_uring;

#[cfg(target_os = "linux")]
pub mod tun_simple;
```

- [ ] **Step 3: Создать tun_simple.rs**

Создать `crates/core/src/tun_simple.rs`:

```rust
//! Simple read/write TUN I/O — no io_uring dependency.
//! Compatible with any Linux kernel >= 3.x.
//! Same API as tun_uring::spawn() for drop-in replacement.

use std::io::{Read, Write};
use std::os::unix::io::{FromRawFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use bytes::{Bytes, BytesMut};
use tokio::sync::mpsc;

const BUF_SIZE: usize = 2048;

pub fn spawn(
    tun_fd: RawFd,
    channel_size: usize,
) -> anyhow::Result<(mpsc::Receiver<Bytes>, mpsc::Sender<Bytes>)> {
    let (read_tx, read_rx) = mpsc::channel::<Bytes>(channel_size);
    let (write_tx, write_rx) = mpsc::channel::<Bytes>(channel_size);
    let stop = Arc::new(AtomicBool::new(false));

    {
        let stop = stop.clone();
        let fd = tun_fd;
        std::thread::Builder::new()
            .name("tun-read".into())
            .spawn(move || {
                if let Err(e) = reader_loop(fd, read_tx, stop) {
                    tracing::error!("TUN reader: {}", e);
                }
            })?;
    }

    {
        let stop = stop.clone();
        let fd = tun_fd;
        std::thread::Builder::new()
            .name("tun-write".into())
            .spawn(move || {
                if let Err(e) = writer_loop(fd, write_rx, stop) {
                    tracing::error!("TUN writer: {}", e);
                }
            })?;
    }

    Ok((read_rx, write_tx))
}

fn reader_loop(
    fd: RawFd,
    tx: mpsc::Sender<Bytes>,
    stop: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut buf = vec![0u8; BUF_SIZE];

    tracing::info!("TUN simple reader started");

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        let n = match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // Non-blocking fd: brief sleep then retry
                std::thread::sleep(std::time::Duration::from_micros(100));
                continue;
            }
            Err(e) => return Err(e.into()),
        };

        if n >= 20 && (buf[0] >> 4) == 4 {
            let mut bm = BytesMut::with_capacity(n);
            bm.extend_from_slice(&buf[..n]);
            if tx.blocking_send(bm.freeze()).is_err() {
                break;
            }
        }
    }

    // Prevent double-close: leak the fd since we don't own it
    std::mem::forget(file);
    Ok(())
}

fn writer_loop(
    fd: RawFd,
    mut rx: mpsc::Receiver<Bytes>,
    stop: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };

    tracing::info!("TUN simple writer started");

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        let pkt = match rx.blocking_recv() {
            Some(p) => p,
            None => break,
        };

        if let Err(e) = file.write_all(&pkt) {
            if e.kind() == std::io::ErrorKind::WouldBlock {
                continue;
            }
            return Err(e.into());
        }

        // Drain queued packets (batch write)
        for _ in 0..31 {
            match rx.try_recv() {
                Ok(pkt) => {
                    let _ = file.write_all(&pkt);
                }
                Err(_) => break,
            }
        }
    }

    std::mem::forget(file);
    Ok(())
}
```

- [ ] **Step 4: Проверить компиляцию с обоими feature flags**

```bash
cd /opt/github_projects/phantom-vpn
# С io_uring (default) — существующий код не ломается
cargo check -p phantom-core
# Без io_uring — tun_simple компилируется
cargo check -p phantom-core --no-default-features
```

Expected: оба проходят без ошибок.

- [ ] **Step 5: Коммит**

```bash
git add crates/core/src/tun_simple.rs crates/core/Cargo.toml crates/core/src/lib.rs
git commit -m "feat(core): add tun_simple fallback for kernels without io_uring"
```

---

## Task 2: Crate client-openwrt — минимальный VPN-демон

**Files:**
- Modify: `Cargo.toml` (workspace root)
- Create: `crates/client-openwrt/Cargo.toml`
- Create: `crates/client-openwrt/src/main.rs`

- [ ] **Step 1: Добавить crate в workspace**

В корневом `Cargo.toml`, в секцию `[workspace] members`, добавить:
```toml
"crates/client-openwrt",
```

- [ ] **Step 2: Создать Cargo.toml**

Создать `crates/client-openwrt/Cargo.toml`:

```toml
[package]
name    = "phantom-client-openwrt"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "ghoststream"
path = "src/main.rs"

[dependencies]
phantom-core          = { path = "../core", default-features = false }
phantom-client-common = { path = "../client-common" }
tokio                 = { version = "1", features = ["full"] }
tracing               = "0.1"
tracing-subscriber    = { version = "0.3", features = ["env-filter"] }
anyhow                = "1"
libc                  = "0.2"
rustls                = { version = "0.23", features = ["ring", "std"] }
serde_json            = "1"
bytes                 = "1"

[profile.release]
opt-level    = "z"
lto          = true
strip        = true
codegen-units = 1
panic        = "abort"
```

- [ ] **Step 3: Создать main.rs**

Создать `crates/client-openwrt/src/main.rs`:

```rust
//! GhostStream OpenWrt client — minimal VPN daemon for routers.
//! Uses plain read()/write() TUN I/O (no io_uring).
//! Designed for netifd protocol handler integration.

#[cfg(target_os = "linux")]
mod openwrt {
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::net::SocketAddr;
    use std::os::unix::io::{AsRawFd, IntoRawFd};

    use anyhow::Context;
    use tokio::signal;
    use tokio::sync::watch;

    use bytes::Bytes;
    use client_common::{tls_connect, tls_rx_loop, tls_tx_loop, write_handshake};
    use client_common::helpers::{load_server_ca, load_tls_identity, parse_conn_string};
    use phantom_core::wire::{flow_stream_idx, n_data_streams};
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};

    const TUNSETIFF: libc::c_ulong = 0x400454CA;
    const IFF_TUN:   libc::c_short = 0x0001;
    const IFF_NO_PI: libc::c_short = 0x1000;

    #[repr(C)]
    struct Ifreq {
        ifr_name:  [libc::c_char; libc::IFNAMSIZ],
        ifr_flags: libc::c_short,
        _pad:      [u8; 22],
    }

    // ─── CLI args (no clap — minimal binary) ─────────────────────────────

    struct OpenwrtArgs {
        conn_string: String,
        tun_name: String,
        mtu: u32,
    }

    fn parse_args() -> anyhow::Result<OpenwrtArgs> {
        let args: Vec<String> = std::env::args().collect();
        let mut conn_string = None;
        let mut tun_name = "gs0".to_string();
        let mut mtu = 1350u32;

        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--conn-string" => {
                    i += 1;
                    conn_string = Some(args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--conn-string requires a value"))?
                        .clone());
                }
                "--tun-name" => {
                    i += 1;
                    tun_name = args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--tun-name requires a value"))?
                        .clone();
                }
                "--mtu" => {
                    i += 1;
                    mtu = args.get(i)
                        .ok_or_else(|| anyhow::anyhow!("--mtu requires a value"))?
                        .parse()
                        .context("--mtu must be a number")?;
                }
                other => anyhow::bail!("Unknown argument: {}", other),
            }
            i += 1;
        }

        Ok(OpenwrtArgs {
            conn_string: conn_string
                .ok_or_else(|| anyhow::anyhow!("--conn-string is required"))?,
            tun_name,
            mtu,
        })
    }

    // ─── TUN creation ────────────────────────────────────────────────────

    fn create_tun(name: &str, mtu: u32) -> anyhow::Result<i32> {
        let file = OpenOptions::new()
            .read(true).write(true)
            .open("/dev/net/tun")
            .context("Failed to open /dev/net/tun")?;

        let mut req = Ifreq {
            ifr_name:  [0; libc::IFNAMSIZ],
            ifr_flags: IFF_TUN | IFF_NO_PI,
            _pad:      [0; 22],
        };
        let name_bytes = name.as_bytes();
        let copy_len = name_bytes.len().min(libc::IFNAMSIZ - 1);
        for (i, &b) in name_bytes[..copy_len].iter().enumerate() {
            req.ifr_name[i] = b as libc::c_char;
        }

        let ret = unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF as _, &req as *const _) };
        if ret < 0 {
            anyhow::bail!("TUNSETIFF failed: {}", io::Error::last_os_error());
        }

        // Non-blocking
        unsafe {
            let flags = libc::fcntl(file.as_raw_fd(), libc::F_GETFL, 0);
            libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        let fd = file.into_raw_fd();

        // ip link set <name> mtu <mtu> up
        // On OpenWrt, netifd proto handler configures IP address and routes.
        // We only bring the interface up with the right MTU here.
        let status = std::process::Command::new("ip")
            .args(["link", "set", name, "mtu", &mtu.to_string(), "up"])
            .status()
            .context("Failed to run 'ip link set'")?;
        if !status.success() {
            anyhow::bail!("ip link set {} up failed", name);
        }

        Ok(fd)
    }

    // ─── Main ────────────────────────────────────────────────────────────

    #[tokio::main(flavor = "current_thread")]
    pub async fn async_main() -> anyhow::Result<()> {
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Failed to install ring crypto provider");

        // Minimal logging to stderr
        tracing_subscriber::fmt()
            .with_max_level(tracing::Level::INFO)
            .with_target(false)
            .compact()
            .init();

        let args = parse_args()?;
        tracing::info!("GhostStream OpenWrt client starting...");

        let cfg = parse_conn_string(&args.conn_string)?;

        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        // Signal handler
        tokio::spawn(async move {
            let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt()).unwrap();
            let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = sigint.recv() => {}
                _ = sigterm.recv() => {}
            }
            let _ = shutdown_tx.send(true);
        });

        let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
        let gateway = cfg.network.default_gw.as_deref().unwrap_or("10.7.0.1");

        // Output JSON for netifd proto handler to parse
        let info = serde_json::json!({
            "tun_name": args.tun_name,
            "tun_addr": tun_addr,
            "gateway": gateway,
        });
        println!("{}", info);

        // Load TLS identity and CA
        let client_identity = load_tls_identity(&cfg)?;
        let server_ca = load_server_ca(&cfg)?;
        let skip_verify = cfg.network.insecure;
        if !skip_verify && server_ca.is_none() {
            anyhow::bail!("No CA certificate and insecure=false");
        }

        let raw_addr = client_common::with_default_port(
            &cfg.network.server_addr, 443,
        );
        let server_addr: SocketAddr = if let Ok(addr) = raw_addr.parse() {
            addr
        } else {
            tokio::net::lookup_host(&raw_addr).await
                .context("DNS lookup failed")?
                .next()
                .ok_or_else(|| anyhow::anyhow!("No DNS results"))?
        };

        let client_config = phantom_core::h2_transport::make_h2_client_tls(
            skip_verify, server_ca, client_identity,
        )?;

        let n_streams = n_data_streams();
        let server_name = cfg.network.server_name
            .as_deref().unwrap_or("phantom").to_string();

        // Connect TLS streams
        let mut tls_writers = Vec::with_capacity(n_streams);
        let mut tls_readers = Vec::with_capacity(n_streams);
        for idx in 0..n_streams {
            let (r, mut w) = tls_connect(
                server_addr, server_name.clone(), client_config.clone(),
            ).await.with_context(|| format!("stream {}: connect failed", idx))?;
            write_handshake(&mut w, idx as u8, n_streams as u8).await?;
            tracing::info!("Stream {}: connected", idx);
            tls_readers.push(r);
            tls_writers.push(w);
        }

        tracing::info!("All {} TLS streams up", n_streams);

        // Create TUN
        let tun_fd = create_tun(&args.tun_name, args.mtu)?;

        // Use tun_simple (no io_uring)
        let (mut tun_pkt_rx, tun_pkt_tx) =
            phantom_core::tun_simple::spawn(tun_fd, 4096)?;
        tracing::info!("TUN simple handler started");

        // Per-stream TX channels
        let mut tx_senders: Vec<tokio::sync::mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
        let mut tx_receivers = Vec::with_capacity(n_streams);
        for _ in 0..n_streams {
            let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(2048);
            tx_senders.push(tx);
            tx_receivers.push(rx);
        }

        let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

        // Dispatcher: TUN reader → per-stream channel via flow hash
        let tx_senders_clone = tx_senders.clone();
        let n_s = n_streams;
        tokio::spawn(async move {
            while let Some(pkt) = tun_pkt_rx.recv().await {
                let idx = flow_stream_idx(&pkt, n_s);
                let _ = tx_senders_clone[idx].try_send(pkt);
            }
        });
        drop(tx_senders);

        // RX forwarder
        let tun_write_tx = tun_pkt_tx.clone();
        tokio::spawn(async move {
            while let Some(pkt) = rx_sink_rx.recv().await {
                if tun_write_tx.send(pkt).await.is_err() {
                    return;
                }
            }
        });
        drop(tun_pkt_tx);

        // TX + RX tasks
        let mut handles = Vec::new();
        for (idx, (w, rxc)) in tls_writers.into_iter().zip(tx_receivers).enumerate() {
            handles.push(tokio::spawn(async move {
                let _ = tls_tx_loop(w, rxc).await;
                tracing::warn!("stream {}: tx ended", idx);
            }));
        }
        for (idx, r) in tls_readers.into_iter().enumerate() {
            let sink = rx_sink_tx.clone();
            handles.push(tokio::spawn(async move {
                let _ = tls_rx_loop(r, sink).await;
                tracing::warn!("stream {}: rx ended", idx);
            }));
        }
        drop(rx_sink_tx);

        tracing::info!("Tunnel active");

        // Wait for shutdown or tunnel death
        let mut shutdown_rx_clone = shutdown_rx.clone();
        tokio::select! {
            _ = async { shutdown_rx_clone.changed().await } => {
                tracing::info!("Shutdown signal");
            }
            _ = async {
                for h in &mut handles { let _ = h.await; }
            } => {
                tracing::warn!("Tunnel died");
            }
        }

        for h in handles { h.abort(); }
        tracing::info!("GhostStream exit");
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    openwrt::async_main()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("GhostStream OpenWrt client requires Linux");
    std::process::exit(1);
}
```

- [ ] **Step 4: Проверить компиляцию**

```bash
cargo check -p phantom-client-openwrt
```

Expected: PASS

- [ ] **Step 5: Проверить размер (x86_64)**

```bash
cargo build --release -p phantom-client-openwrt
ls -lh target/release/ghoststream
```

Expected: ≤ 3 MB

- [ ] **Step 6: Коммит**

```bash
git add crates/client-openwrt/ Cargo.toml
git commit -m "feat: add phantom-client-openwrt crate — minimal VPN daemon for routers"
```

---

## Task 3: netifd protocol handler

**Files:**
- Create: `openwrt/proto/ghoststream.sh`

- [ ] **Step 1: Создать proto handler**

Создать `openwrt/proto/ghoststream.sh`:

```sh
#!/bin/sh
# GhostStream netifd protocol handler
# Install to: /lib/netifd/proto/ghoststream.sh

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_ghoststream_init_config() {
    proto_config_add_string 'connection_string'
    proto_config_add_int 'mtu'
    available=1
}

proto_ghoststream_setup() {
    local config="$1"
    local iface="$2"

    local connection_string mtu
    json_get_vars connection_string mtu

    [ -z "$connection_string" ] && {
        echo "GhostStream: connection_string is required" >&2
        proto_notify_error "$config" "NO_CONNECTION_STRING"
        proto_block_restart "$config"
        return 1
    }

    [ -z "$mtu" ] && mtu=1350

    local tun_name="gs-${config}"

    # Start daemon, capture first line (JSON with tun params)
    proto_run_command "$config" /usr/bin/ghoststream \
        --conn-string "$connection_string" \
        --tun-name "$tun_name" \
        --mtu "$mtu"

    # Wait briefly for TUN to appear
    local waited=0
    while [ ! -d "/sys/class/net/${tun_name}" ] && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if [ ! -d "/sys/class/net/${tun_name}" ]; then
        echo "GhostStream: TUN ${tun_name} did not appear" >&2
        proto_notify_error "$config" "TUN_FAILED"
        proto_kill_command "$config"
        return 1
    fi

    # Parse tun_addr from connection string using jsonfilter
    # The daemon outputs JSON on stdout; we extract from conn string directly
    local tun_json
    tun_json=$(echo "$connection_string" | base64 -d 2>/dev/null)
    local tun_addr
    tun_addr=$(echo "$tun_json" | jsonfilter -e '@.tun' 2>/dev/null)
    [ -z "$tun_addr" ] && tun_addr="10.7.0.2/24"

    local ip_addr="${tun_addr%%/*}"
    local prefix="${tun_addr##*/}"
    local gateway
    gateway=$(echo "$ip_addr" | awk -F. '{printf "%s.%s.%s.1", $1, $2, $3}')

    proto_init_update "$tun_name" 1
    proto_add_ipv4_address "$ip_addr" "$prefix"
    proto_add_ipv4_route "0.0.0.0" 0 "$gateway"

    # DNS: use gateway as DNS server (server-side resolver)
    proto_add_dns_server "$gateway"

    proto_send_update "$config"
}

proto_ghoststream_teardown() {
    local config="$1"
    proto_kill_command "$config"
}

add_protocol ghoststream
```

- [ ] **Step 2: Коммит**

```bash
mkdir -p openwrt/proto
git add openwrt/proto/ghoststream.sh
git commit -m "feat(openwrt): add netifd protocol handler"
```

---

## Task 4: LuCI protocol page

**Files:**
- Create: `openwrt/luci/htdocs/luci-static/resources/protocol/ghoststream.js`
- Create: `openwrt/luci/root/usr/share/rpcd/acl.d/luci-proto-ghoststream.json`

- [ ] **Step 1: Создать LuCI JS protocol module**

Создать `openwrt/luci/htdocs/luci-static/resources/protocol/ghoststream.js`:

```javascript
'use strict';
'require uci';
'require form';
'require network';

network.registerProtocol('ghoststream', {
    getI18n: function() {
        return _('GhostStream VPN');
    },

    getIfname: function() {
        return this._ubus('l3_device') || 'gs-%s'.format(this.sid);
    },

    getOpkgPackage: function() {
        return 'ghoststream';
    },

    isFloating: function() {
        return true;
    },

    isVirtual: function() {
        return true;
    },

    getDevices: function() {
        return null;
    },

    containsDevice: function(ifname) {
        return (network.getIfnameOf(ifname) == this.getIfname());
    },

    renderFormOptions: function(s) {
        var o;

        o = s.taboption('general', form.TextValue, 'connection_string', _('Connection String'),
            _('Base64-encoded connection string from the VPN server. Paste the full string here.'));
        o.rows = 3;
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'mtu', _('MTU'),
            _('Maximum Transmission Unit for the tunnel interface.'));
        o.datatype = 'range(1280, 1500)';
        o.default = '1350';
        o.rmempty = true;
    }
});
```

- [ ] **Step 2: Создать RPCD ACL**

Создать `openwrt/luci/root/usr/share/rpcd/acl.d/luci-proto-ghoststream.json`:

```json
{
    "luci-proto-ghoststream": {
        "description": "Grant access to GhostStream VPN protocol",
        "read": {
            "ubus": {
                "network.interface.ghoststream*": [ "status", "dump" ]
            },
            "uci": [ "network" ]
        },
        "write": {
            "uci": [ "network" ]
        }
    }
}
```

- [ ] **Step 3: Коммит**

```bash
mkdir -p openwrt/luci/htdocs/luci-static/resources/protocol
mkdir -p openwrt/luci/root/usr/share/rpcd/acl.d
git add openwrt/luci/
git commit -m "feat(openwrt): add LuCI protocol page for GhostStream"
```

---

## Task 5: Install скрипт

**Files:**
- Create: `ghoststream-install.sh`

- [ ] **Step 1: Создать инсталлятор**

Создать `ghoststream-install.sh`:

```sh
#!/bin/sh
# GhostStream VPN — one-liner installer for OpenWrt
# Usage: sh <(wget -O - https://raw.githubusercontent.com/PatrickRedStar/phantom-vpn/refs/heads/master/ghoststream-install.sh)

set -e

REPO="PatrickRedStar/phantom-vpn"

echo "==============================="
echo " GhostStream VPN Installer"
echo "==============================="
echo ""

# ─── Check OpenWrt ────────────────────────────────────────────────────

if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: This script is designed for OpenWrt only."
    exit 1
fi

. /etc/openwrt_release
echo "OpenWrt: $DISTRIB_DESCRIPTION"
echo "Target:  $DISTRIB_TARGET"

# ─── Detect architecture ─────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    mips|mipsel)   BINARY="ghoststream-mipsel" ;;
    aarch64)       BINARY="ghoststream-aarch64" ;;
    armv7l|armv7)  BINARY="ghoststream-armv7" ;;
    x86_64)        BINARY="ghoststream-x86_64" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        echo "Supported: mipsel, aarch64, armv7, x86_64"
        exit 1
        ;;
esac
echo "Architecture: $ARCH → $BINARY"
echo ""

# ─── Get latest release URL ──────────────────────────────────────────

RELEASE_URL="https://github.com/$REPO/releases/latest/download"

# ─── Download binary ─────────────────────────────────────────────────

echo "Downloading ghoststream binary..."
wget -q -O /tmp/ghoststream "$RELEASE_URL/$BINARY"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download $BINARY"
    echo "Check: https://github.com/$REPO/releases"
    exit 1
fi
chmod +x /tmp/ghoststream

# Quick sanity check
if ! /tmp/ghoststream --help >/dev/null 2>&1; then
    echo "ERROR: Binary is not compatible with this system"
    rm -f /tmp/ghoststream
    exit 1
fi

install -m 0755 /tmp/ghoststream /usr/bin/ghoststream
rm -f /tmp/ghoststream
echo "  → /usr/bin/ghoststream installed"

# ─── Install netifd proto handler ─────────────────────────────────────

echo "Installing netifd protocol handler..."
wget -q -O /lib/netifd/proto/ghoststream.sh \
    "$RELEASE_URL/ghoststream.sh"
chmod +x /lib/netifd/proto/ghoststream.sh
echo "  → /lib/netifd/proto/ghoststream.sh installed"

# ─── Install LuCI protocol page ──────────────────────────────────────

echo "Installing LuCI interface..."
mkdir -p /www/luci-static/resources/protocol
wget -q -O /www/luci-static/resources/protocol/ghoststream.js \
    "$RELEASE_URL/ghoststream.js"

mkdir -p /usr/share/rpcd/acl.d
wget -q -O /usr/share/rpcd/acl.d/luci-proto-ghoststream.json \
    "$RELEASE_URL/luci-proto-ghoststream.json"
echo "  → LuCI protocol page installed"

# ─── Ask for connection string ────────────────────────────────────────

echo ""
echo "Enter your GhostStream connection string"
echo "(base64 string from your VPN provider):"
echo ""
printf "> "
read -r CONN_STRING

if [ -z "$CONN_STRING" ]; then
    echo ""
    echo "No connection string provided."
    echo "You can configure it later in LuCI:"
    echo "  Network → Interfaces → Add new interface → GhostStream VPN"
    echo ""
else
    # ─── Create network interface ─────────────────────────────────────

    echo ""
    echo "Creating GhostStream interface..."

    uci set network.ghoststream0=interface
    uci set network.ghoststream0.proto='ghoststream'
    uci set network.ghoststream0.connection_string="$CONN_STRING"
    uci set network.ghoststream0.mtu='1350'
    uci commit network

    # ─── Firewall zone ────────────────────────────────────────────────

    echo "Configuring firewall..."

    uci set firewall.gs_zone=zone
    uci set firewall.gs_zone.name='ghoststream'
    uci set firewall.gs_zone.input='REJECT'
    uci set firewall.gs_zone.output='ACCEPT'
    uci set firewall.gs_zone.forward='REJECT'
    uci set firewall.gs_zone.masq='1'
    uci set firewall.gs_zone.mtu_fix='1'
    uci set firewall.gs_zone.network='ghoststream0'

    uci set firewall.gs_fwd=forwarding
    uci set firewall.gs_fwd.src='lan'
    uci set firewall.gs_fwd.dest='ghoststream'

    uci commit firewall

    echo "  → Firewall zone 'ghoststream' created"
    echo "  → LAN → GhostStream forwarding enabled"
fi

# ─── Restart services ────────────────────────────────────────────────

echo ""
echo "Restarting services..."
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/network reload >/dev/null 2>&1

echo ""
echo "==============================="
echo " Installation complete!"
echo "==============================="
echo ""
echo "Manage via LuCI: Network → Interfaces → GHOSTSTREAM0"
echo "Or via CLI:"
echo "  ifup ghoststream0     # start VPN"
echo "  ifdown ghoststream0   # stop VPN"
echo "  logread -e ghoststream # view logs"
echo ""
```

- [ ] **Step 2: Коммит**

```bash
git add ghoststream-install.sh
git commit -m "feat(openwrt): add one-liner install script"
```

---

## Task 6: GitHub Actions — cross-компиляция

**Files:**
- Create: `.github/workflows/openwrt.yml`

- [ ] **Step 1: Создать workflow**

Создать `.github/workflows/openwrt.yml`:

```yaml
name: Build OpenWrt Client

on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  build-openwrt:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - target: mipsel-unknown-linux-musl
            name: ghoststream-mipsel
          - target: aarch64-unknown-linux-musl
            name: ghoststream-aarch64
          - target: armv7-unknown-linux-musleabihf
            name: ghoststream-armv7
          - target: x86_64-unknown-linux-musl
            name: ghoststream-x86_64

    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}

      - name: Install cross
        run: cargo install cross --git https://github.com/cross-rs/cross

      - name: Build
        run: cross build --release --target ${{ matrix.target }} -p phantom-client-openwrt

      - name: Strip binary
        run: |
          STRIP_BIN=""
          case "${{ matrix.target }}" in
            mipsel*) STRIP_BIN="mipsel-linux-gnu-strip" ;;
            aarch64*) STRIP_BIN="aarch64-linux-gnu-strip" ;;
            armv7*) STRIP_BIN="arm-linux-gnueabihf-strip" ;;
            x86_64*) STRIP_BIN="strip" ;;
          esac
          if command -v $STRIP_BIN >/dev/null 2>&1; then
            $STRIP_BIN target/${{ matrix.target }}/release/ghoststream || true
          fi

      - name: Check size
        run: ls -lh target/${{ matrix.target }}/release/ghoststream

      - name: Rename artifact
        run: cp target/${{ matrix.target }}/release/ghoststream ${{ matrix.name }}

      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.name }}
          path: ${{ matrix.name }}

  release-openwrt:
    needs: build-openwrt
    runs-on: ubuntu-latest
    if: startsWith(github.ref, 'refs/tags/')
    permissions:
      contents: write

    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          path: artifacts

      - name: Prepare release files
        run: |
          mkdir -p release-files
          # Binaries
          for dir in artifacts/ghoststream-*; do
            name=$(basename "$dir")
            cp "$dir/$name" "release-files/$name"
            chmod +x "release-files/$name"
          done
          # Proto handler + LuCI files
          cp openwrt/proto/ghoststream.sh release-files/
          cp openwrt/luci/htdocs/luci-static/resources/protocol/ghoststream.js release-files/
          cp openwrt/luci/root/usr/share/rpcd/acl.d/luci-proto-ghoststream.json release-files/

      - name: Create/Update Release
        uses: softprops/action-gh-release@v2
        with:
          files: release-files/*
          append_body: true
          body: |
            ## OpenWrt Client
            Install: `sh <(wget -O - https://raw.githubusercontent.com/${{ github.repository }}/refs/heads/master/ghoststream-install.sh)`
```

- [ ] **Step 2: Коммит**

```bash
git add .github/workflows/openwrt.yml
git commit -m "ci: add cross-compilation workflow for OpenWrt (4 architectures)"
```

---

## Task 7: Локальная сборка и smoke test

- [ ] **Step 1: Собрать x86_64 бинарник локально**

```bash
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-client-openwrt
ls -lh target/release/ghoststream
```

Expected: бинарник ≤ 3 MB

- [ ] **Step 2: Проверить --help / аргументы**

```bash
target/release/ghoststream --conn-string "test" 2>&1 || true
```

Expected: ошибка парсинга connection string (не "unknown argument")

- [ ] **Step 3: Проверить что client-linux не сломался**

```bash
cargo build --release -p phantom-client-linux
cargo test -p phantom-core
```

Expected: оба проходят

- [ ] **Step 4: Финальный коммит**

```bash
git add -A
git commit -m "feat(v0.19.0): GhostStream OpenWrt client — netifd proto + LuCI + 4-arch installer"
```
