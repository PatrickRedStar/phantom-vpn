//! phantom-client-android: Android VPN client via JNI.
//!
//! Phase 4: GhostStreamVpnService calls nativeStart(tunFd, cfgJson, settingsJson, listener).
//! Rust runs the tunnel via client_core_runtime::run() with TunIo::BlockingThreads.
//! Status and log updates are pushed to Kotlin via PhantomListener callbacks instead
//! of polling.

use std::ffi::CString;
use std::os::unix::io::RawFd;
use std::sync::{Arc, Mutex, OnceLock};

use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::{jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};

use client_core_runtime::{ConnectProfile, TunIo, TunnelSettings};
use ghoststream_gui_ipc::LogFrame;

use tokio::sync::{mpsc, watch};
use ghoststream_gui_ipc::StatusFrame;

// ─── Android logcat ──────────────────────────────────────────────────────────

#[link(name = "log")]
extern "C" {
    fn __android_log_write(
        prio: libc::c_int,
        tag: *const libc::c_char,
        text: *const libc::c_char,
    ) -> libc::c_int;
}

fn logcat(prio: libc::c_int, msg: &str) {
    if let (Ok(tag), Ok(m)) = (CString::new("GhostStream"), CString::new(msg)) {
        unsafe { __android_log_write(prio, tag.as_ptr(), m.as_ptr()); }
    }
}

// ─── Global tunnel state ─────────────────────────────────────────────────────

/// Tokio runtime — created once and reused across reconnects.
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

struct TunnelState {
    cancel: Arc<tokio::sync::Notify>,
}

static TUNNEL: Mutex<Option<TunnelState>> = Mutex::new(None);

/// Protected TCP fds for N parallel TLS streams, prepared on the JNI thread
/// (VpnService.protect() must run on the thread holding the JNIEnv).
static PROTECTED_TCP_FDS: Mutex<Vec<RawFd>> = Mutex::new(Vec::new());

// ─── Runtime helper ──────────────────────────────────────────────────────────

fn get_or_init_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(6)
            .thread_name("ghoststream-rt")
            .build()
            .expect("failed to create tokio runtime")
    })
}

// ─── JNI entry points ────────────────────────────────────────────────────────

/// Start the tunnel.
///
/// Kotlin signature:
/// ```kotlin
/// external fun nativeStart(tunFd: Int, cfgJson: String, settingsJson: String, listener: PhantomListener): Int
/// ```
/// Returns 0 on success, -1 on config parse error, -10 on spawn failure.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeStart(
    mut env: JNIEnv,
    this: JObject,
    tun_fd: jint,
    cfg_json: JString,
    settings_json: JString,
    listener: JObject,
) -> jint {
    // ── 1. Parse ConnectProfile ──────────────────────────────────────────────
    let cfg_str = match env.get_string(&cfg_json) {
        Ok(s) => String::from(s),
        Err(_) => {
            logcat(6, "nativeStart: bad cfgJson");
            return -1;
        }
    };
    let cfg: ConnectProfile = match serde_json::from_str(&cfg_str) {
        Ok(c) => c,
        Err(e) => {
            logcat(6, &format!("nativeStart: failed to parse cfgJson: {}", e));
            return -1;
        }
    };

    // ── 2. Parse TunnelSettings ──────────────────────────────────────────────
    let _settings: TunnelSettings = match env.get_string(&settings_json) {
        Ok(s) => {
            let s = String::from(s);
            serde_json::from_str(&s).unwrap_or_default()
        }
        Err(_) => TunnelSettings::default(),
    };

    // ── 3. Dup TUN fd ────────────────────────────────────────────────────────
    let fd = unsafe { libc::dup(tun_fd as RawFd) };
    if fd < 0 {
        logcat(6, &format!("nativeStart: dup() failed: {}", std::io::Error::last_os_error()));
        return -1;
    }

    // ── 4. Pre-create + protect() N TCP sockets on the JNI thread ────────────
    {
        use phantom_core::wire::n_data_streams;
        let n_streams = n_data_streams();
        let mut fds: Vec<RawFd> = Vec::with_capacity(n_streams);
        for i in 0..n_streams {
            let tcp_fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
            if tcp_fd < 0 {
                logcat(6, &format!("nativeStart: socket() failed for stream {}", i));
                for f in &fds { unsafe { libc::close(*f); } }
                unsafe { libc::close(fd); }
                return -1;
            }

            let protected = env
                .call_method(&this, "protect", "(I)Z", &[JValue::Int(tcp_fd)])
                .ok()
                .and_then(|v| v.z().ok())
                .unwrap_or(false);

            if !protected {
                logcat(6, &format!("nativeStart: VpnService.protect() returned false on stream {}", i));
                unsafe { libc::close(tcp_fd); }
                for f in &fds { unsafe { libc::close(*f); } }
                unsafe { libc::close(fd); }
                return -1;
            }

            unsafe {
                let one: libc::c_int = 1;
                libc::setsockopt(
                    tcp_fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,
                    &one as *const _ as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
            }
            logcat(4, &format!("Stream {}: TCP fd={} protected + TCP_NODELAY", i, tcp_fd));
            fds.push(tcp_fd);
        }
        *PROTECTED_TCP_FDS.lock().unwrap() = fds;
    }

    // ── 5. Obtain JavaVM + global ref to listener for cross-thread callbacks ──
    let jvm: Arc<JavaVM> = match env.get_java_vm() {
        Ok(vm) => Arc::new(vm),
        Err(e) => {
            logcat(6, &format!("nativeStart: get_java_vm failed: {:?}", e));
            unsafe { libc::close(fd); }
            return -1;
        }
    };
    let listener_global: GlobalRef = match env.new_global_ref(&listener) {
        Ok(g) => g,
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref failed: {:?}", e));
            unsafe { libc::close(fd); }
            return -1;
        }
    };

    // ── 6. Get or create the shared tokio runtime ────────────────────────────
    let rt = get_or_init_runtime();

    // ── 7. Channels for status + log push ────────────────────────────────────
    let (status_tx, mut status_rx) = watch::channel(StatusFrame::default());
    let (log_tx, mut log_rx) = mpsc::channel::<LogFrame>(256);

    // ── 8. Start the tunnel via client_core_runtime::run() ───────────────────
    let (handles, _join) = match rt.block_on(client_core_runtime::run(
        cfg,
        TunIo::BlockingThreads(fd),
        status_tx,
        log_tx,
    )) {
        Ok(r) => r,
        Err(e) => {
            logcat(6, &format!("nativeStart: run() failed: {:#}", e));
            unsafe { libc::close(fd); }
            return -10;
        }
    };

    // Store cancel handle so nativeStop can trigger graceful shutdown.
    *TUNNEL.lock().unwrap() = Some(TunnelState {
        cancel: handles.cancel.clone(),
    });

    // ── 9. Spawn status watcher ───────────────────────────────────────────────
    // watch::Receiver changes → listener.onStatusFrame(json)
    {
        let jvm_status = jvm.clone();
        let listener_status = listener_global.clone();
        rt.spawn(async move {
            loop {
                if status_rx.changed().await.is_err() {
                    break;
                }
                let frame: StatusFrame = status_rx.borrow_and_update().clone();
                let json = match serde_json::to_string(&frame) {
                    Ok(j) => j,
                    Err(_) => continue,
                };

                let mut jni_env: jni::AttachGuard<'_> = match jvm_status.attach_current_thread() {
                    Ok(e) => e,
                    Err(_) => break,
                };

                if let Ok(jstr) = jni_env.new_string(&json) {
                    let _ = jni_env.call_method(
                        listener_status.as_obj(),
                        "onStatusFrame",
                        "(Ljava/lang/String;)V",
                        &[JValue::Object(&jstr)],
                    );
                }
            }
        });
    }

    // ── 10. Spawn log watcher ─────────────────────────────────────────────────
    // mpsc::Receiver<LogFrame> → listener.onLogFrame(json)
    {
        let jvm_log = jvm;
        let listener_log = listener_global;
        rt.spawn(async move {
            while let Some(frame) = log_rx.recv().await {
                let json = match serde_json::to_string(&frame) {
                    Ok(j) => j,
                    Err(_) => continue,
                };

                let mut jni_env: jni::AttachGuard<'_> = match jvm_log.attach_current_thread() {
                    Ok(e) => e,
                    Err(_) => break,
                };

                if let Ok(jstr) = jni_env.new_string(&json) {
                    let _ = jni_env.call_method(
                        listener_log.as_obj(),
                        "onLogFrame",
                        "(Ljava/lang/String;)V",
                        &[JValue::Object(&jstr)],
                    );
                }
            }
        });
    }

    logcat(4, "nativeStart: tunnel started OK");
    0
}

/// Stop the tunnel.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeStop(
    _env: JNIEnv,
    _class: JClass,
) -> jint {
    if let Some(TunnelState { cancel }) = TUNNEL.lock().unwrap().take() {
        logcat(4, "nativeStop: notifying cancel");
        cancel.notify_waiters();
    }
    0
}

// ─── Legacy stubs (kept for Kotlin callers during migration) ─────────────────

/// Stub — returns null. Stats are now push-based via onStatusFrame callback.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeGetStats(
    _env: JNIEnv,
    _class: JClass,
) -> jstring {
    std::ptr::null_mut()
}

/// Stub — returns null. Logs are now push-based via onLogFrame callback.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeGetLogs(
    _env: JNIEnv,
    _class: JClass,
    _since_seq: jlong,
) -> jstring {
    std::ptr::null_mut()
}

/// Stub — log level is controlled via RUST_LOG / EnvFilter in logsink::install().
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeSetLogLevel(
    _env: JNIEnv,
    _class: JClass,
    _level: JString,
) {
    // No-op: filtering is handled by the tracing subscriber in client_core_runtime.
}

// ─── Routing ─────────────────────────────────────────────────────────────────

/// Compute VPN routes (complement of "direct" CIDRs).
/// Input: path to a text file with one CIDR per line.
/// Output: JSON array of {"addr":"...","prefix":N} objects, or null on error.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeComputeVpnRoutes(
    mut env: JNIEnv,
    _class: JClass,
    direct_cidrs_path: JString,
) -> jstring {
    let path_str = match env.get_string(&direct_cidrs_path) {
        Ok(s) => String::from(s),
        Err(_) => {
            logcat(6, "nativeComputeVpnRoutes: bad path string");
            return std::ptr::null_mut();
        }
    };

    let text = match std::fs::read_to_string(&path_str) {
        Ok(t) => t,
        Err(e) => {
            logcat(6, &format!("nativeComputeVpnRoutes: failed to read {}: {}", path_str, e));
            return std::ptr::null_mut();
        }
    };

    let table = phantom_core::routing::RoutingTable::from_cidrs(&text);
    logcat(4, &format!("Routing: loaded {} direct CIDRs from {}", table.direct_count(), path_str));

    let routes = table.compute_vpn_routes();
    logcat(4, &format!("Routing: computed {} VPN routes", routes.len()));

    let json = phantom_core::routing::routes_to_json(&routes);
    env.new_string(&json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}
