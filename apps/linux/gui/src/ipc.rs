//! GUI-side IPC client. Talks to `ghoststream-helper` over Unix socket.

use anyhow::Context;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, Mutex};

pub use ghoststream_gui_ipc::{
    ConnectProfile, LogFrame, Request, Response, StatusFrame,
};

/// Events delivered to the UI layer.
#[derive(Debug, Clone)]
pub enum UiEvent {
    Status(StatusFrame),
    Log(LogFrame),
    /// IPC socket lost / helper exited. UI should revert to Disconnected.
    Disconnected,
    /// Helper responded with an explicit error to a request.
    Error(String),
}

/// Connection handle to the helper. `cmd_tx` posts requests; they are sent
/// over the socket in order. Responses arrive via the `UiEvent` mpsc passed
/// at construction time.
pub struct IpcClient {
    cmd_tx: mpsc::Sender<Request>,
}

impl IpcClient {
    /// Try to connect to an existing helper. Does NOT spawn the helper itself.
    pub async fn try_connect(
        events: mpsc::Sender<UiEvent>,
    ) -> anyhow::Result<Self> {
        let uid = unsafe { libc::getuid() };
        let path = socket_path(uid);
        let stream = UnixStream::connect(&path).await
            .with_context(|| format!("connect {}", path.display()))?;

        let (rd, wr) = stream.into_split();
        let wr = Arc::new(Mutex::new(wr));
        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Request>(32);

        let wr_writer = wr.clone();
        let writer_events = events.clone();
        tokio::spawn(async move {
            while let Some(req) = cmd_rx.recv().await {
                let s = match serde_json::to_string(&req) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = writer_events.send(UiEvent::Error(format!("encode: {}", e))).await;
                        continue;
                    }
                };
                let mut g = wr_writer.lock().await;
                if g.write_all(s.as_bytes()).await.is_err() { break; }
                if g.write_all(b"\n").await.is_err() { break; }
            }
        });

        let events_rd = events.clone();
        tokio::spawn(async move {
            let mut r = BufReader::new(rd);
            let mut line = String::new();
            loop {
                line.clear();
                match r.read_line(&mut line).await {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(_) => break,
                }
                let trimmed = line.trim();
                if trimmed.is_empty() { continue; }
                match serde_json::from_str::<Response>(trimmed) {
                    Ok(Response::Status(s)) => { let _ = events_rd.send(UiEvent::Status(s)).await; }
                    Ok(Response::LogLine(l)) => { let _ = events_rd.send(UiEvent::Log(l)).await; }
                    Ok(Response::Error { message }) => { let _ = events_rd.send(UiEvent::Error(message)).await; }
                    Ok(Response::Ok) => {}
                    Ok(Response::Bye) => break,
                    Err(e) => {
                        let _ = events_rd.send(UiEvent::Error(format!("decode: {}", e))).await;
                    }
                }
            }
            let _ = events_rd.send(UiEvent::Disconnected).await;
        });

        Ok(Self { cmd_tx })
    }

    pub async fn send(&self, req: Request) {
        let _ = self.cmd_tx.send(req).await;
    }
}

pub fn socket_path(uid: u32) -> PathBuf {
    if let Some(rt) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(rt).join(ghoststream_gui_ipc::SOCKET_FILENAME);
    }
    ghoststream_gui_ipc::socket_path_for_uid_runtime(uid)
}

pub fn socket_exists() -> bool {
    let uid = unsafe { libc::getuid() };
    socket_path(uid).exists()
}

pub async fn await_socket(
    timeout: std::time::Duration,
    interval: std::time::Duration,
) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if socket_exists() { return true; }
        tokio::time::sleep(interval).await;
    }
    socket_exists()
}
