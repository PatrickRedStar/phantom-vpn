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

// ─── JNI-safe GlobalRef wrapper (v0.25.1, W3-9) ──────────────────────────────
//
// Bare `GlobalRef::drop()` calls `DeleteGlobalRef`, which JNI requires to be
// invoked from a thread currently attached to the JVM. When a watcher task
// is aborted, or `nativeStart` early-returns with an error, the GlobalRef
// can be dropped on a tokio worker thread that has long detached from the
// JVM. ART's `-Xcheck:jni` debug mode treats this as fatal; release mode
// silently leaks slots in the global ref table.
//
// `JniSafeGlobalRef` re-attaches the dropping thread as a daemon before
// releasing the inner ref. `attach_current_thread_as_daemon` is the right
// primitive here:
//   - permanent attach (no detach on guard drop), so the tokio worker
//     stays attached for the rest of its life — cost is one thread slot
//     in the JVM, paid once per worker. Cheap; workers are pooled.
//   - safe to call when already attached (returns the existing JNIEnv).
//   - never detaches by itself, so the underlying `DeleteGlobalRef` call
//     happens on a known-attached thread.
struct JniSafeGlobalRef {
    inner: Option<GlobalRef>,
    vm: Arc<JavaVM>,
}

impl JniSafeGlobalRef {
    fn new(env: &mut JNIEnv, obj: &JObject, vm: Arc<JavaVM>) -> jni::errors::Result<Self> {
        Ok(Self { inner: Some(env.new_global_ref(obj)?), vm })
    }

    fn as_obj(&self) -> &GlobalRef {
        self.inner.as_ref().expect("JniSafeGlobalRef used after drop")
    }
}

impl Drop for JniSafeGlobalRef {
    fn drop(&mut self) {
        let Some(gref) = self.inner.take() else { return };
        // attach_current_thread_as_daemon returns Result<JNIEnv> and leaves
        // the thread permanently attached. We don't need the JNIEnv — just
        // the side effect of being attached when `gref` drops below.
        match self.vm.attach_current_thread_as_daemon() {
            Ok(_) => drop(gref),
            Err(_) => {
                // JVM is unreachable (shutdown in progress, or attach
                // limit hit). Leak the slot rather than risk a crash —
                // process is going down anyway in either case.
                std::mem::forget(gref);
            }
        }
    }
}

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
    /// Cancel signal: send `true` to trigger graceful shutdown.
    ///
    /// v0.25.1 (W3-2): `watch::Sender<bool>` replaces `Arc<Notify>` so that
    /// a cancel issued mid-`select!` (between arms re-arming) isn't lost.
    /// `Notify::notify_waiters()` only wakes tasks already suspended on
    /// `.notified()` — under TSPU drops the supervisor sometimes raced its
    /// own re-entry and a user-issued Disconnect tap stalled for 45 s.
    cancel: tokio::sync::watch::Sender<bool>,
    join: tokio::task::JoinHandle<anyhow::Result<()>>,
    /// Watcher task handles — kept so `nativeStop` can `.abort()` them
    /// synchronously before the supervisor finishes draining. Without
    /// this, a slow `attach_current_thread → call_method → detach` cycle
    /// inside the watcher could land one final "Disconnected" frame
    /// *after* a freshly-started new tunnel has already emitted
    /// "Connected", causing the UI to blink (v0.25.1, W3-10).
    status_watcher: tokio::task::JoinHandle<()>,
    log_watcher: tokio::task::JoinHandle<()>,
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
    if let Some(TunnelState { cancel, join, status_watcher, log_watcher }) =
        TUNNEL.lock().unwrap().take()
    {
        logcat(4, "nativeStart: cancelling previous tunnel");
        // v0.25.1 (W3-2): watch::Sender::send may legitimately fail when the
        // supervisor's receiver has already dropped (rare — usually means
        // it exited on its own). Ignoring is correct: we still join below.
        let _ = cancel.send(true);
        // v0.25.1 (W3-10): abort the previous tunnel's watcher tasks so
        // their already-queued frames can't race past the new tunnel's
        // first "Connecting" callback.
        status_watcher.abort();
        log_watcher.abort();
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
            // v0.25.0: don't log `e`'s Display — serde_json::Error includes a
            // content snippet which for cfgJson means the private key surface
            // area. Log only the category code.
            logcat(6, &format!(
                "nativeStart: failed to parse cfgJson (category={})",
                e.classify() as u8
            ));
            return -1;
        }
    };

    // ── 2. Parse TunnelSettings ──────────────────────────────────────────────
    let _settings: TunnelSettings = match env.get_string(&settings_json) {
        Ok(s) => {
            let s = String::from(s);
            match serde_json::from_str::<TunnelSettings>(&s) {
                Ok(parsed) => parsed,
                Err(e) => {
                    // v0.25.0: don't silently downgrade to default — that
                    // may turn killswitch off without the user knowing.
                    // Logcat surfaces this so we can spot breaking-change
                    // formats; default is still applied (fail-safe) so
                    // the tunnel still comes up.
                    logcat(6, &format!(
                        "nativeStart: settings parse failed (category={}), using defaults",
                        e.classify() as u8
                    ));
                    TunnelSettings::default()
                }
            }
        }
        Err(_) => {
            logcat(6, "nativeStart: settings_json get_string failed, using defaults");
            TunnelSettings::default()
        }
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
    //
    // v0.25.1 (W3-9): each ref is wrapped in `JniSafeGlobalRef` so its
    // eventual drop attaches the dropping thread to the JVM as a daemon
    // first. Otherwise a watcher task aborted on a tokio worker would
    // drop the raw `GlobalRef` on a detached thread — silent leak in
    // release, `-Xcheck:jni` fatal in debug.
    let listener_for_status = match JniSafeGlobalRef::new(&mut env, &listener, jvm.clone()) {
        Ok(g) => Arc::new(g),
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(status) failed: {:?}", e));
            return -1;
        }
    };
    let listener_for_logs = match JniSafeGlobalRef::new(&mut env, &listener, jvm.clone()) {
        Ok(g) => Arc::new(g),
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(logs) failed: {:?}", e));
            return -1;
        }
    };
    // Global ref to VpnService for protect() calls from tokio worker threads.
    let service_ref: Arc<JniSafeGlobalRef> = match JniSafeGlobalRef::new(&mut env, &this, jvm.clone()) {
        Ok(g) => Arc::new(g),
        Err(e) => {
            logcat(6, &format!("nativeStart: new_global_ref(service) failed: {:?}", e));
            return -1;
        }
    };

    // ── 5. Build ProtectSocket callback ──────────────────────────────────────
    // Called by the runtime on tokio worker threads before each TCP connect.
    //
    // v0.25.1 (W3-9): `service_ref` is `Arc<JniSafeGlobalRef>`. It moves
    // into the closure; the closure itself is held by the runtime's
    // protect callback for the tunnel's lifetime. When that last clone
    // finally drops on a tokio worker thread, `JniSafeGlobalRef::drop`
    // re-attaches the thread to the JVM before releasing the inner ref.
    let jvm_protect = jvm.clone();
    let protect: ProtectSocket = Arc::new(move |tcp_fd: RawFd| {
        let mut jni_env = match jvm_protect.attach_current_thread() {
            Ok(e) => e,
            Err(_) => return false,
        };
        let result = jni_env
            .call_method(
                service_ref.as_obj(),
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

    // ── 9. Spawn status watcher ───────────────────────────────────────────────
    // watch::Receiver changes → listener.onStatusFrame(json)
    //
    // v0.25.1 (W3-10): the JoinHandle is now retained in TunnelState so
    // `nativeStop` can `.abort()` this task synchronously. Without this,
    // a slow JNI call cycle could deliver one final "Disconnected" frame
    // *after* a freshly-started new tunnel has emitted "Connected", which
    // surfaced as a UI flicker on rapid Stop→Start.
    let status_watcher = {
        let jvm_status = jvm.clone();
        // `listener_for_status: Arc<JniSafeGlobalRef>` — when the spawned
        // task ends or is aborted, the Arc drops on a tokio worker; the
        // wrapper attaches the thread before releasing the inner GlobalRef.
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
            // GlobalRef drop is now safe — JniSafeGlobalRef::drop re-attaches
            // the dropping thread to the JVM before releasing the ref.
        })
    };

    // ── 10. Spawn log watcher ─────────────────────────────────────────────────
    // mpsc::Receiver<LogFrame> → listener.onLogFrame(json)
    //
    // v0.25.1 (W3-10): JoinHandle retained for `nativeStop.abort()`.
    let log_watcher = {
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
            // GlobalRef drop is now safe — see status watcher comment.
        })
    };

    // Store cancel handle + supervisor join + watcher join handles so
    // nativeStop can abort watchers synchronously and join the supervisor.
    //
    // NB: the watcher store happens *after* successful `run()` so that
    // an early return on a `run()` error doesn't leave watchers running
    // against a tunnel that never started (W3-9: watcher tasks would
    // otherwise drop GlobalRefs on detached workers — though the
    // JniSafeGlobalRef wrapper makes that safe regardless).
    if let Some(prev) = TUNNEL.lock().unwrap().replace(TunnelState {
        cancel: handles.cancel.clone(),
        join,
        status_watcher,
        log_watcher,
    }) {
        // This branch is theoretically unreachable — step 0 already took
        // and joined any previous TunnelState. But if a concurrent insert
        // ever snuck through, abort the displaced watchers to keep
        // the invariant "only one tunnel's watcher tasks alive at a time".
        prev.status_watcher.abort();
        prev.log_watcher.abort();
        prev.join.abort();
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
    if let Some(TunnelState { cancel, join, status_watcher, log_watcher }) =
        TUNNEL.lock().unwrap().take()
    {
        logcat(4, "nativeStop: notifying cancel");
        // v0.25.1 (W3-2): watch::Sender::send carries a value so it can't
        // be "missed" the way `Notify::notify_waiters` could. A late
        // observer of the channel still sees `true` and exits.
        let _ = cancel.send(true);

        // v0.25.1 (W3-10): abort watcher tasks *before* awaiting the
        // supervisor. The supervisor's status_tx/log_tx are still alive
        // while it's draining, so without abort the watchers would keep
        // pumping frames (including a final "Disconnected") and a rapid
        // Stop→Start would race them against the new tunnel's watchers.
        // Aborting is synchronous from the caller's POV: any frame the
        // watcher was mid-flight delivering completes (`call_method`
        // is not an await point), then the task is cancelled at its
        // next poll — guaranteed before this thread returns to Kotlin
        // because we don't resume the supervisor join below until the
        // abort signal has been issued.
        status_watcher.abort();
        log_watcher.abort();

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
