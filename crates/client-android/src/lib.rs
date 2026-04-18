//! phantom-client-android: Android VPN client via JNI.
//!
//! Phase 4: GhostStreamVpnService calls nativeStart(tunFd, cfgJson, settingsJson, listener).
//! Rust runs the tunnel via client_core_runtime::run() with TunIo::BlockingThreads.
//! Status and log updates are pushed to Kotlin via PhantomListener callbacks instead
//! of polling.

use std::ffi::CString;
use std::os::unix::io::RawFd;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::sys::{jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};

use client_core_runtime::{ConnectProfile, ProtectSocket, TunIo, TunnelSettings};
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
    join: tokio::task::JoinHandle<anyhow::Result<()>>,
}

static TUNNEL: Mutex<Option<TunnelState>> = Mutex::new(None);

/// Serializes nativeStart/nativeStop calls to prevent zombie tunnels.
/// Without this, rapid Kotlin start/stop cycles can overlap on different
/// threads: Thread A's nativeStart holds TUNNEL briefly (step 0), releases
/// it, then Thread B's nativeStart sees an empty TUNNEL and proceeds —
/// creating two concurrent supervisors where only the last is tracked.
static START_STOP_LOCK: Mutex<()> = Mutex::new(());


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
    // Serialize with other nativeStart/nativeStop calls to prevent zombies.
    let _op_guard = START_STOP_LOCK.lock().unwrap();

    // ── 0. Cancel any previous tunnel and WAIT for it to fully exit ────────
    // Without awaiting the JoinHandle, old supervisor tasks survive as zombies
    // that keep reading/writing the TUN fd → protect() failures, dual tunnels,
    // "TUN write failed" errors.
    if let Some(TunnelState { cancel, join }) = TUNNEL.lock().unwrap().take() {
        logcat(4, "nativeStart: cancelling previous tunnel");
        cancel.notify_waiters();
        let rt = get_or_init_runtime();
        let _ = rt.block_on(async {
            let _ = tokio::time::timeout(Duration::from_secs(5), join).await;
        });
        logcat(4, "nativeStart: previous tunnel cleaned up");
    }

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

    // ── 3. TUN fd ────────────────────────────────────────────────────────────
    // Don't dup here — client_core_runtime::run() dups internally for
    // BlockingThreads and closes the dup'd fd on supervisor exit.
    let fd = tun_fd as RawFd;

    // ── 4. Obtain JavaVM + global refs ─────────────────────────────────────────
    let jvm: Arc<JavaVM> = match env.get_java_vm() {
        Ok(vm) => Arc::new(vm),
        Err(e) => {
            logcat(6, &format!("nativeStart: get_java_vm failed: {:?}", e));
            return -1;
        }
    };
    // Create separate global refs from the local ref — GlobalRef::clone()
    // passes a global ref to NewGlobalRef which ART's -Xcheck:jni rejects as
    // an "invalid local reference".
    let listener_for_status: GlobalRef = match env.new_global_ref(&listener) {
        Ok(g) => g,
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(status) failed: {:?}", e));
            return -1;
        }
    };
    let listener_for_logs: GlobalRef = match env.new_global_ref(&listener) {
        Ok(g) => g,
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(logs) failed: {:?}", e));
            return -1;
        }
    };
    // Global ref to VpnService for protect() calls from tokio worker threads.
    let service_for_protect: GlobalRef = match env.new_global_ref(&this) {
        Ok(g) => g,
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(service) failed: {:?}", e));
            return -1;
        }
    };

    // ── 5. Build ProtectSocket callback ──────────────────────────────────────
    // Called by the runtime on tokio worker threads before each TCP connect.
    let jvm_protect = jvm.clone();
    let protect: ProtectSocket = Arc::new(move |tcp_fd: RawFd| {
        let mut jni_env = match jvm_protect.attach_current_thread() {
            Ok(e) => e,
            Err(_) => return false,
        };
        let result = jni_env
            .call_method(
                service_for_protect.as_obj(),
                "protect",
                "(I)Z",
                &[JValue::Int(tcp_fd)],
            )
            .ok()
            .and_then(|v| v.z().ok())
            .unwrap_or(false);
        if result {
            logcat(4, &format!("protect(fd={}) OK", tcp_fd));
        } else {
            logcat(6, &format!("protect(fd={}) FAILED", tcp_fd));
        }
        result
    });

    // ── 6. Get or create the shared tokio runtime ────────────────────────────
    let rt = get_or_init_runtime();

    // ── 7. Channels for status + log push ────────────────────────────────────
    let (status_tx, mut status_rx) = watch::channel(StatusFrame::default());
    let (log_tx, mut log_rx) = mpsc::channel::<LogFrame>(256);

    // ── 8. Start the tunnel via client_core_runtime::run() ───────────────────
    let (handles, join) = match rt.block_on(client_core_runtime::run(
        cfg,
        TunIo::BlockingThreads(fd),
        status_tx,
        log_tx,
        Some(protect),
    )) {
        Ok(r) => r,
        Err(e) => {
            logcat(6, &format!("nativeStart: run() failed: {:#}", e));
            return -10;
        }
    };

    // Store cancel handle AND join handle so nativeStop can trigger graceful
    // shutdown and WAIT for the supervisor task to fully exit.  Previously
    // the JoinHandle was dropped (_join), leaving no way to join the
    // supervisor — the root cause of zombie tunnels.
    *TUNNEL.lock().unwrap() = Some(TunnelState {
        cancel: handles.cancel.clone(),
        join,
    });

    // ── 9. Spawn status watcher ───────────────────────────────────────────────
    // watch::Receiver changes → listener.onStatusFrame(json)
    {
        let jvm_status = jvm.clone();
        let listener_status = listener_for_status;
        rt.spawn(async move {
            logcat(4, "status watcher: task started");
            loop {
                match status_rx.changed().await {
                    Ok(()) => {},
                    Err(e) => {
                        logcat(6, &format!("status watcher: channel closed: {}", e));
                        break;
                    }
                }
                let frame: StatusFrame = status_rx.borrow_and_update().clone();
                let json = match serde_json::to_string(&frame) {
                    Ok(j) => j,
                    Err(e) => {
                        logcat(6, &format!("status watcher: json serialize failed: {}", e));
                        continue;
                    }
                };

                let mut jni_env: jni::AttachGuard<'_> = match jvm_status.attach_current_thread() {
                    Ok(e) => e,
                    Err(e) => {
                        logcat(6, &format!("status watcher: attach_current_thread failed: {:?}", e));
                        break;
                    }
                };

                match jni_env.new_string(&json) {
                    Ok(jstr) => {
                        let result = jni_env.call_method(
                            listener_status.as_obj(),
                            "onStatusFrame",
                            "(Ljava/lang/String;)V",
                            &[JValue::Object(&jstr)],
                        );
                        if let Err(e) = result {
                            logcat(6, &format!("status watcher: call_method failed: {:?}", e));
                            // Check for and clear JNI exception
                            if jni_env.exception_check().unwrap_or(false) {
                                jni_env.exception_describe().ok();
                                jni_env.exception_clear().ok();
                            }
                        }
                    }
                    Err(e) => {
                        logcat(6, &format!("status watcher: new_string failed: {:?}", e));
                    }
                }
            }
            logcat(4, "status watcher: task exiting");
            // Attach thread to JVM before GlobalRef drop to avoid
            // "Dropping a GlobalRef in a detached thread" warning.
            let _guard = jvm_status.attach_current_thread();
            drop(listener_status);
        });
    }

    // ── 10. Spawn log watcher ─────────────────────────────────────────────────
    // mpsc::Receiver<LogFrame> → listener.onLogFrame(json)
    {
        let jvm_log = jvm;
        let listener_log = listener_for_logs;
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
            // Attach thread to JVM before GlobalRef drop.
            let _guard = jvm_log.attach_current_thread();
            drop(listener_log);
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
    let _op_guard = START_STOP_LOCK.lock().unwrap();
    if let Some(TunnelState { cancel, join }) = TUNNEL.lock().unwrap().take() {
        logcat(4, "nativeStop: notifying cancel");
        cancel.notify_waiters();
        logcat(4, "nativeStop: waiting for tunnel exit");
        let rt = get_or_init_runtime();
        let _ = rt.block_on(async {
            let _ = tokio::time::timeout(Duration::from_secs(5), join).await;
        });
        logcat(4, "nativeStop: tunnel stopped");
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

/// Change the tracing log level at runtime.
/// `level` is one of: "trace", "debug", "info", "warn", "error".
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeSetLogLevel(
    mut env: JNIEnv,
    _class: JClass,
    level: JString,
) {
    let lvl = match env.get_string(&level) {
        Ok(s) => String::from(s),
        Err(_) => return,
    };
    logcat(4, &format!("setLogLevel: {}", lvl));
    client_core_runtime::logsink::set_level(&lvl);
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
