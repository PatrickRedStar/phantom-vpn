//! Linux-only helper implementation.

mod dns;
mod ipv6;
mod logsink;
mod socket;
mod tun;
mod tunnel;

use anyhow::Context;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{watch, Mutex};

use ghoststream_gui_ipc::{Request, Response, StatusFrame};

pub fn run() -> anyhow::Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        eprintln!("ghoststream-helper: must run as root (spawned via pkexec).");
        eprintln!("    Try: pkexec /usr/bin/ghoststream-helper");
        std::process::exit(1);
    }

    let target_uid: u32 = std::env::var("PKEXEC_UID")
        .or_else(|_| std::env::var("SUDO_UID"))
        .ok()
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| anyhow::anyhow!(
            "PKEXEC_UID / SUDO_UID not set; helper must be spawned by pkexec / sudo"))?;
    let target_gid: u32 = std::env::var("PKEXEC_GID")
        .or_else(|_| std::env::var("SUDO_GID"))
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(target_uid);

    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(num_cpus())
        .thread_name("ghs-helper")
        .build()
        .context("tokio runtime")?;

    rt.block_on(async_main(target_uid, target_gid))
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get().clamp(2, 8))
        .unwrap_or(4)
}

async fn async_main(target_uid: u32, target_gid: u32) -> anyhow::Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();

    // Install tracing subscriber that forwards events into a broadcaster the
    // GUI can subscribe to after `SubscribeLogs`.
    logsink::install();

    tracing::info!(target: "helper", "starting; uid={} gid={}", target_uid, target_gid);

    let (status_tx, status_rx) = watch::channel(StatusFrame::default());
    let tunnel_manager = Arc::new(tunnel::Manager::new(status_tx));

    let socket_path = ghoststream_gui_ipc::socket_path_for_uid_runtime(target_uid);
    let listener = socket::bind(&socket_path, target_uid, target_gid)
        .with_context(|| format!("bind {}", socket_path.display()))?;
    tracing::info!(path = %socket_path.display(), "helper socket bound");

    // Signal handler.
    {
        let tm = tunnel_manager.clone();
        let sp = socket_path.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigint = signal(SignalKind::interrupt()).unwrap();
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = sigint.recv() => {}
                _ = sigterm.recv() => {}
            }
            tracing::info!("signal received, exiting");
            tm.disconnect().await;
            let _ = std::fs::remove_file(&sp);
            std::process::exit(0);
        });
    }

    // Idle-exit watchdog: quit after 5 min with no client (no active tunnel).
    {
        let tm = tunnel_manager.clone();
        let sp = socket_path.clone();
        tokio::spawn(async move {
            // initial grace
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                let idle = tm.client_count() == 0 && !tm.is_connected();
                if idle {
                    tracing::info!("idle, exiting");
                    tm.disconnect().await;
                    let _ = std::fs::remove_file(&sp);
                    std::process::exit(0);
                }
            }
        });
    }

    // Accept loop — each connection gets its own serve task. Multi-client OK;
    // the last Connect wins (tunnel manager arbitrates).
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(?e, "accept failed");
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                continue;
            }
        };
        tracing::info!("GUI connected");
        tunnel_manager.inc_clients();
        let tm = tunnel_manager.clone();
        let status_rx = status_rx.clone();
        let log_rx = logsink::subscribe();
        tokio::spawn(async move {
            serve_client(stream, tm.clone(), status_rx, log_rx).await;
            tm.dec_clients();
            tracing::info!("GUI disconnected");
        });
    }
}

async fn serve_client(
    stream: tokio::net::UnixStream,
    tunnel_manager: Arc<tunnel::Manager>,
    mut status_rx: watch::Receiver<StatusFrame>,
    mut log_rx: logsink::LogReceiver,
) {
    let (rd, wr) = stream.into_split();
    let mut rd = BufReader::new(rd);
    let wr = Arc::new(Mutex::new(wr));

    // Status fan-out.
    let status_task = {
        let wr = wr.clone();
        tokio::spawn(async move {
            // Send initial snapshot immediately.
            let frame = status_rx.borrow_and_update().clone();
            if !send_resp(&wr, &Response::Status(frame)).await { return; }
            while status_rx.changed().await.is_ok() {
                let frame = status_rx.borrow_and_update().clone();
                if !send_resp(&wr, &Response::Status(frame)).await { return; }
            }
        })
    };

    // Log subscription gate — flipped on by `SubscribeLogs`.
    let log_on = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let log_task = {
        let wr = wr.clone();
        let on = log_on.clone();
        tokio::spawn(async move {
            while let Some(lf) = log_rx.recv().await {
                if !on.load(std::sync::atomic::Ordering::Relaxed) { continue; }
                if !send_resp(&wr, &Response::LogLine(lf)).await { return; }
            }
        })
    };

    // Request loop.
    let mut line = String::new();
    loop {
        line.clear();
        match rd.read_line(&mut line).await {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) => { tracing::warn!(?e, "client read"); break; }
        }
        let trimmed = line.trim();
        if trimmed.is_empty() { continue; }

        let req: Request = match serde_json::from_str(trimmed) {
            Ok(r) => r,
            Err(e) => {
                send_resp(&wr, &Response::Error { message: format!("bad request: {}", e) }).await;
                continue;
            }
        };

        let resp = match req {
            Request::Connect { profile } => {
                match tunnel_manager.connect(profile).await {
                    Ok(()) => Response::Ok,
                    Err(e) => Response::Error { message: format!("{:#}", e) },
                }
            }
            Request::Disconnect => {
                tunnel_manager.disconnect().await;
                Response::Ok
            }
            Request::GetStatus => Response::Status(tunnel_manager.current_status()),
            Request::SubscribeLogs => {
                log_on.store(true, std::sync::atomic::Ordering::Relaxed);
                Response::Ok
            }
            Request::Shutdown => {
                tunnel_manager.disconnect().await;
                send_resp(&wr, &Response::Bye).await;
                std::process::exit(0);
            }
        };
        if !send_resp(&wr, &resp).await { break; }
    }

    status_task.abort();
    log_task.abort();
}

async fn send_resp(wr: &Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>, r: &Response) -> bool {
    let s = match serde_json::to_string(r) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let mut g = wr.lock().await;
    if g.write_all(s.as_bytes()).await.is_err() { return false; }
    if g.write_all(b"\n").await.is_err() { return false; }
    true
}
