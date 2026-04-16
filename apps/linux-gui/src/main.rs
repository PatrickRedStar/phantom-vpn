//! GhostStream Linux desktop client — Slint UI + tokio IPC.
//!
//! Two threads cooperate:
//!   * Slint event loop (main thread) — owns `MainWindow`, drives UI.
//!   * Tokio runtime (spawned) — owns the IPC socket, helper spawn, profile
//!     store mutations, async validation.
//!
//! They communicate via two channels:
//!   * `UiCommand` (UI → tokio): user gestures (connect, disconnect, save
//!     profile, etc.)
//!   * `UiAction`  (tokio → UI): results the UI must apply; wrapped into a
//!     closure posted with `slint::invoke_from_event_loop`.

use std::cell::RefCell;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, Mutex};
use tracing_subscriber::{fmt, EnvFilter};

mod admin_api;
mod ipc;
mod pkexec;
mod profiles;
mod settings;
mod state;
mod tray;

slint::include_modules!();

use ipc::{IpcClient, UiEvent};
use state::ViewState;
use tray::{MyTray, TrayEvent};

// ── Commands from UI thread → tokio worker ────────────────────────────────

#[derive(Debug)]
enum UiCommand {
    Connect,
    Disconnect,
    SelectProfile(String),
    EditorConnEdited(String),
    EditorSave {
        name: String,
        conn: String,
        admin_url: String,
        admin_token: String,
        admin_fp: String,
    },
    DeleteActiveProfile,
    EditActiveProfile,
    LogsClear,
    // Admin screen
    AdminOpen,
    AdminRefresh,
    AdminAddSubmit { name: String, expires_days: Option<u32> },
    AdminRowAction { action: String, name: String },
    // Settings
    SettingsToggleAutostart(bool),
    SettingsCopyDebug,
}

// ── main entry ───────────────────────────────────────────────────────────

fn main() -> anyhow::Result<()> {
    fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    register_fonts();

    let window = MainWindow::new()?;
    state::seed_static(&window);

    // Initial profile render.
    let profiles = profiles::Store::load();
    state::apply_profiles(&window, &profiles, &ghoststream_gui_ipc::StatusFrame::default());

    // Seed settings into UI.
    let user_settings = settings::UserSettings::load();
    window.set_setting_dns_leak(user_settings.dns_leak_protection);
    window.set_setting_ipv6_ks(user_settings.ipv6_killswitch);
    window.set_setting_autorec(user_settings.auto_reconnect);
    window.set_setting_autostart(settings::systemd_autostart_is_enabled());
    window.set_setting_start_min(user_settings.start_minimized);

    // Channels.
    let (cmd_tx, cmd_rx) = mpsc::channel::<UiCommand>(64);
    let (tray_tx, mut tray_rx) = tokio::sync::mpsc::unbounded_channel::<TrayEvent>();

    // Tray service — runs on its own thread inside ksni.
    let tray_handle = match tray::spawn_tray(tray_tx.clone()) {
        Ok(h) => Some(std::sync::Arc::new(h)),
        Err(e) => { tracing::warn!(?e, "tray init failed"); None }
    };

    // Spawn the tokio runtime on a background thread.
    let win_weak = window.as_weak();
    std::thread::Builder::new()
        .name("ghs-gui-tokio".into())
        .spawn({
            let tray_handle = tray_handle.clone();
            move || {
                let rt = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .worker_threads(2)
                    .thread_name("ghs-gui-rt")
                    .build()
                    .expect("tokio runtime");
                rt.block_on(tokio_worker(win_weak, cmd_rx, tray_handle));
            }
        })?;

    // Tray → UI bridge: route TrayEvent into the same cmd channel or window.
    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        std::thread::Builder::new()
            .name("ghs-gui-tray".into())
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all().build().expect("tray rt");
                rt.block_on(async move {
                    while let Some(ev) = tray_rx.recv().await {
                        match ev {
                            TrayEvent::ShowWindow => {
                                let win_weak = win_weak.clone();
                                let _ = slint::invoke_from_event_loop(move || {
                                    if let Some(w) = win_weak.upgrade() { w.show().ok(); }
                                });
                            }
                            TrayEvent::Connect    => { let _ = cmd_tx.send(UiCommand::Connect).await; }
                            TrayEvent::Disconnect => { let _ = cmd_tx.send(UiCommand::Disconnect).await; }
                            TrayEvent::Quit       => {
                                let _ = slint::invoke_from_event_loop(|| {
                                    slint::quit_event_loop().ok();
                                });
                            }
                        }
                    }
                });
            })?;
    }

    // Wire Slint callbacks → cmd_tx.
    wire_callbacks(&window, cmd_tx.clone());

    window.run()?;
    Ok(())
}

// ── Font registration (unchanged) ─────────────────────────────────────────

fn register_fonts() {
    use std::fs;
    use std::path::PathBuf;

    let target_dir: PathBuf = match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h).join(".local/share/fonts/ghoststream"),
        None => return,
    };

    let fonts: &[(&str, &[u8])] = &[
        ("InstrumentSerif-Regular.ttf", include_bytes!("../assets/fonts/InstrumentSerif-Regular.ttf")),
        ("InstrumentSerif-Italic.ttf",  include_bytes!("../assets/fonts/InstrumentSerif-Italic.ttf")),
        ("JetBrainsMono-Regular.ttf",   include_bytes!("../assets/fonts/JetBrainsMono-Regular.ttf")),
        ("DepartureMono-Regular.otf",   include_bytes!("../assets/fonts/DepartureMono-Regular.otf")),
    ];

    if let Err(e) = fs::create_dir_all(&target_dir) {
        tracing::warn!(?e, dir = ?target_dir, "could not create font dir");
        return;
    }

    let mut wrote_any = false;
    for (name, bytes) in fonts {
        let dest = target_dir.join(name);
        let needs_write = match fs::metadata(&dest) {
            Ok(m) => m.len() as usize != bytes.len(),
            Err(_) => true,
        };
        if needs_write {
            if let Err(e) = fs::write(&dest, *bytes) {
                tracing::warn!(font = name, error = ?e, "font write");
            } else { wrote_any = true; }
        }
    }
    if wrote_any {
        let _ = std::process::Command::new("fc-cache").arg("-f").arg(&target_dir).status();
    }
}

// ── Callback wiring (runs on UI thread) ────────────────────────────────────

fn wire_callbacks(window: &MainWindow, cmd_tx: mpsc::Sender<UiCommand>) {
    {
        let win_weak = window.as_weak();
        window.on_profiles_clicked(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_editor_name("".into());
                w.set_editor_conn("".into());
                w.set_editor_admin_url("".into());
                w.set_editor_admin_token("".into());
                w.set_editor_admin_fp("".into());
                w.set_editor_parse_error("".into());
                w.set_editor_parse_ok("".into());
                w.set_editor_open(true);
            }
        });
    }

    // Admin
    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        window.on_admin_clicked(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_admin_open(true);
                let _ = cmd_tx.blocking_send(UiCommand::AdminOpen);
            }
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        window.on_admin_refresh(move || { let _ = cmd_tx.blocking_send(UiCommand::AdminRefresh); });
    }
    {
        let win_weak = window.as_weak();
        window.on_admin_close(move || { if let Some(w) = win_weak.upgrade() { w.set_admin_open(false); } });
    }
    {
        let win_weak = window.as_weak();
        window.on_admin_add(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_admin_add_name("".into());
                w.set_admin_add_days(30);
                w.set_admin_add_open(true);
            }
        });
    }
    {
        let win_weak = window.as_weak();
        window.on_admin_add_cancel(move || { if let Some(w) = win_weak.upgrade() { w.set_admin_add_open(false); } });
    }
    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        window.on_admin_add_submit(move || {
            if let Some(w) = win_weak.upgrade() {
                let name = w.get_admin_add_name().to_string().trim().to_string();
                let days = w.get_admin_add_days();
                let expires = if days <= 0 { None } else { Some(days as u32) };
                w.set_admin_add_open(false);
                if !name.is_empty() {
                    let _ = cmd_tx.blocking_send(UiCommand::AdminAddSubmit { name, expires_days: expires });
                }
            }
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        window.on_admin_row_action(move |a, n| {
            let _ = cmd_tx.blocking_send(UiCommand::AdminRowAction {
                action: a.to_string(), name: n.to_string(),
            });
        });
    }

    // Logs overlay
    {
        let win_weak = window.as_weak();
        window.on_logs_clicked(move || { if let Some(w) = win_weak.upgrade() { w.set_logs_open(true); } });
    }
    {
        let win_weak = window.as_weak();
        window.on_logs_close(move || { if let Some(w) = win_weak.upgrade() { w.set_logs_open(false); } });
    }
    {
        let win_weak = window.as_weak();
        window.on_logs_level_cycle(move || {
            if let Some(w) = win_weak.upgrade() {
                let next = state::level_cycle_next(&w.get_logs_level_filter().to_string());
                w.set_logs_level_filter(next.into());
            }
        });
    }
    window.on_logs_filter_edited(|_t| { /* property is two-way — filter applied on next status tick */ });
    {
        let win_weak = window.as_weak();
        window.on_logs_copy(move || {
            if let Some(w) = win_weak.upgrade() {
                use slint::Model;
                let m = w.get_logs_all();
                let mut buf = String::new();
                for i in 0..m.row_count() {
                    if let Some(r) = m.row_data(i) {
                        buf.push_str(&format!("{} {} {}\n", r.ts, r.level, r.msg));
                    }
                }
                if let Ok(mut cb) = arboard::Clipboard::new() {
                    let _ = cb.set_text(buf);
                }
            }
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        window.on_logs_clear(move || { let _ = cmd_tx.blocking_send(UiCommand::LogsClear); });
    }

    // Settings overlay
    {
        let win_weak = window.as_weak();
        window.on_settings_clicked(move || { if let Some(w) = win_weak.upgrade() { w.set_settings_open(true); } });
    }
    {
        let win_weak = window.as_weak();
        window.on_settings_close(move || { if let Some(w) = win_weak.upgrade() { w.set_settings_open(false); } });
    }
    {
        let win_weak = window.as_weak();
        window.on_setting_toggle_dns(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_setting_dns_leak(!w.get_setting_dns_leak());
                save_settings_from_ui(&w);
            }
        });
    }
    {
        let win_weak = window.as_weak();
        window.on_setting_toggle_ipv6(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_setting_ipv6_ks(!w.get_setting_ipv6_ks());
                save_settings_from_ui(&w);
            }
        });
    }
    {
        let win_weak = window.as_weak();
        window.on_setting_toggle_reconnect(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_setting_autorec(!w.get_setting_autorec());
                save_settings_from_ui(&w);
            }
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        window.on_setting_toggle_autostart(move || {
            if let Some(w) = win_weak.upgrade() {
                let new_state = !w.get_setting_autostart();
                let _ = cmd_tx.blocking_send(UiCommand::SettingsToggleAutostart(new_state));
            }
        });
    }
    {
        let win_weak = window.as_weak();
        window.on_setting_toggle_minimized(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_setting_start_min(!w.get_setting_start_min());
                save_settings_from_ui(&w);
            }
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        window.on_setting_copy_debug(move || { let _ = cmd_tx.blocking_send(UiCommand::SettingsCopyDebug); });
    }
    window.on_setting_open_config_dir(|| {
        let dir = dirs::config_dir().unwrap_or_default().join("ghoststream");
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::process::Command::new("xdg-open").arg(&dir).spawn();
    });

    window.on_quit_clicked(|| { slint::quit_event_loop().ok(); });

    // Edit active profile — populate editor from current profile data.
    {
        let cmd_tx = cmd_tx.clone();
        window.on_edit_profile_clicked(move || {
            let _ = cmd_tx.blocking_send(UiCommand::EditActiveProfile);
        });
    }
    // Delete active profile.
    {
        let cmd_tx = cmd_tx.clone();
        window.on_delete_profile_clicked(move || {
            let _ = cmd_tx.blocking_send(UiCommand::DeleteActiveProfile);
        });
    }

    {
        let win_weak = window.as_weak();
        window.on_add_profile_clicked(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_editor_name("".into());
                w.set_editor_conn("".into());
                w.set_editor_admin_url("".into());
                w.set_editor_admin_token("".into());
                w.set_editor_admin_fp("".into());
                w.set_editor_parse_error("".into());
                w.set_editor_parse_ok("".into());
                w.set_editor_open(true);
            }
        });
    }

    {
        let win_weak = window.as_weak();
        window.on_editor_cancel(move || {
            if let Some(w) = win_weak.upgrade() { w.set_editor_open(false); }
        });
    }

    {
        let cmd_tx = cmd_tx.clone();
        window.on_editor_conn_edited(move |t| {
            let s = t.to_string();
            let _ = cmd_tx.blocking_send(UiCommand::EditorConnEdited(s));
        });
    }

    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        window.on_editor_save(move || {
            if let Some(w) = win_weak.upgrade() {
                let name = w.get_editor_name().to_string();
                let conn = w.get_editor_conn().to_string();
                let admin_url = w.get_editor_admin_url().to_string();
                let admin_token = w.get_editor_admin_token().to_string();
                let admin_fp = w.get_editor_admin_fp().to_string();
                let _ = cmd_tx.blocking_send(UiCommand::EditorSave { name, conn, admin_url, admin_token, admin_fp });
            }
        });
    }

    {
        let cmd_tx = cmd_tx.clone();
        let win_weak = window.as_weak();
        window.on_profile_selected(move |idx| {
            if let Some(w) = win_weak.upgrade() {
                use slint::Model;
                let model = w.get_profiles();
                if let Some(item) = model.row_data(idx as usize) {
                    // We only have the name/host, not the id in the UI model.
                    // Ask tokio worker to resolve + select by (name, host).
                    let _ = cmd_tx.blocking_send(
                        UiCommand::SelectProfile(format!("{}|{}", item.name, item.host))
                    );
                }
            }
        });
    }

    {
        let cmd_tx = cmd_tx.clone();
        window.on_connect_clicked(move || {
            let _ = cmd_tx.blocking_send(UiCommand::Connect);
        });
    }
    {
        let cmd_tx = cmd_tx.clone();
        window.on_disconnect_clicked(move || {
            let _ = cmd_tx.blocking_send(UiCommand::Disconnect);
        });
    }

}

// ── Tokio worker ───────────────────────────────────────────────────────────

async fn tokio_worker(
    win_weak: slint::Weak<MainWindow>,
    mut cmd_rx: mpsc::Receiver<UiCommand>,
    tray_handle: Option<Arc<ksni::Handle<MyTray>>>,
) {
    // Shared mutable state inside the runtime.
    let profiles: Arc<Mutex<profiles::Store>> = Arc::new(Mutex::new(profiles::Store::load()));
    let client: Arc<Mutex<Option<IpcClient>>> = Arc::new(Mutex::new(None));

    // Telemetry event channel (IPC → UI).
    let (ev_tx, mut ev_rx) = mpsc::channel::<UiEvent>(256);

    // Try to connect to an existing helper on boot.
    match IpcClient::try_connect(ev_tx.clone()).await {
        Ok(c) => {
            *client.lock().await = Some(c);
            tracing::info!("IPC connected to running helper");
            // ask for logs immediately
            if let Some(c) = client.lock().await.as_ref() {
                c.send(ipc::Request::SubscribeLogs).await;
                c.send(ipc::Request::GetStatus).await;
            }
        }
        Err(e) => {
            tracing::info!("no helper yet: {}", e);
        }
    }

    // UI event pump: push status/logs into Slint.
    {
        let win_weak = win_weak.clone();
        tokio::spawn(async move {
            // Small thread-local view state mirror on UI thread.
            while let Some(ev) = ev_rx.recv().await {
                let win_weak = win_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    with_view(&win_weak, |win, view| apply_ui_event(win, view, ev));
                });
            }
        });
    }

    // Periodic profile-row refresh (every 1s) — keeps rx/tx labels fresh.
    {
        let profiles = profiles.clone();
        let win_weak = win_weak.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let snap = profiles.lock().await.clone_snapshot();
                let win_weak = win_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    with_view(&win_weak, |win, view| {
                        state::apply_profiles(win, &snap, &view.last_status);
                    });
                });
            }
        });
    }

    // Command loop.
    while let Some(cmd) = cmd_rx.recv().await {
        let tray_relevant = matches!(&cmd,
            UiCommand::Connect | UiCommand::Disconnect
        );
        match cmd {
            UiCommand::Connect => {
                // Ensure helper is up; if not, launch via pkexec.
                let need_spawn = client.lock().await.is_none() || !ipc::socket_exists();
                if need_spawn {
                    tracing::info!("spawning helper via pkexec");
                    let _ = tokio::task::spawn_blocking(pkexec::spawn_via_pkexec).await;
                    if ipc::await_socket(Duration::from_secs(20), Duration::from_millis(250)).await {
                        match IpcClient::try_connect(ev_tx.clone()).await {
                            Ok(c) => {
                                *client.lock().await = Some(c);
                                if let Some(c) = client.lock().await.as_ref() {
                                    c.send(ipc::Request::SubscribeLogs).await;
                                }
                            }
                            Err(e) => {
                                push_error(&win_weak, format!("IPC connect: {:#}", e));
                                continue;
                            }
                        }
                    } else {
                        push_error(&win_weak, "Helper did not start (pkexec cancelled?)".into());
                        continue;
                    }
                }

                // Need an active profile.
                let ps = profiles.lock().await;
                let active = match ps.active() {
                    Some(p) => p.clone(),
                    None => {
                        drop(ps);
                        push_error(&win_weak, "No profile selected. Add one via + ADD PROFILE.".into());
                        continue;
                    }
                };
                drop(ps);

                // Build TunnelSettings from current UI state (avoids race with disk save).
                let tunnel_settings = {
                    let win_weak = win_weak.clone();
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    let _ = slint::invoke_from_event_loop(move || {
                        let ts = if let Some(w) = win_weak.upgrade() {
                            ghoststream_gui_ipc::TunnelSettings {
                                dns_leak_protection: w.get_setting_dns_leak(),
                                ipv6_killswitch: w.get_setting_ipv6_ks(),
                                auto_reconnect: w.get_setting_autorec(),
                            }
                        } else {
                            ghoststream_gui_ipc::TunnelSettings::default()
                        };
                        let _ = tx.send(ts);
                    });
                    rx.await.unwrap_or_default()
                };
                if let Some(c) = client.lock().await.as_ref() {
                    c.send(ipc::Request::Connect {
                        profile: ipc::ConnectProfile {
                            name: active.name.clone(),
                            conn_string: active.conn_string.clone(),
                            settings: tunnel_settings,
                        }
                    }).await;
                }
            }

            UiCommand::Disconnect => {
                if let Some(c) = client.lock().await.as_ref() {
                    c.send(ipc::Request::Disconnect).await;
                }
            }

            UiCommand::SelectProfile(key) => {
                let (name, host) = match key.split_once('|') {
                    Some((n, h)) => (n.to_string(), h.to_string()),
                    None => continue,
                };
                let mut ps = profiles.lock().await;
                let id = ps.profiles.iter().find(|p| p.name == name && p.server_addr == host).map(|p| p.id.clone());
                if let Some(id) = id {
                    ps.set_active(&id);
                    let _ = ps.save();
                    let snap = ps.clone_snapshot();
                    drop(ps);
                    let win_weak = win_weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        with_view(&win_weak, |win, view| state::apply_profiles(win, &snap, &view.last_status));
                    });
                }
            }

            UiCommand::EditorConnEdited(text) => {
                // Async-parse (cheap) and echo validation into UI.
                let (err, ok) = validate_conn_string(&text);
                let win_weak = win_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(w) = win_weak.upgrade() {
                        w.set_editor_parse_error(err.into());
                        w.set_editor_parse_ok(ok.into());
                    }
                });
            }

            UiCommand::EditorSave { name, conn, admin_url, admin_token, admin_fp } => {
                let (err, _) = validate_conn_string(&conn);
                if !err.is_empty() {
                    let win_weak = win_weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = win_weak.upgrade() {
                            w.set_editor_parse_error(err.into());
                        }
                    });
                    continue;
                }
                let chosen_name = if name.trim().is_empty() {
                    derive_default_name(&conn)
                } else {
                    name.trim().to_string()
                };
                match profiles::Profile::from_conn_string(chosen_name, conn) {
                    Ok(p) => {
                        let mut ps = profiles.lock().await;
                        let id = ps.add(p);
                        ps.update_admin(
                            &id,
                            Some(admin_url.clone()),
                            Some(admin_token.clone()),
                            Some(admin_fp.clone()),
                        );
                        ps.set_active(&id);
                        let _ = ps.save();
                        let snap = ps.clone_snapshot();
                        drop(ps);
                        let win_weak = win_weak.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(w) = win_weak.upgrade() {
                                w.set_editor_open(false);
                                w.set_editor_name("".into());
                                w.set_editor_conn("".into());
                            }
                            with_view(&win_weak, |win, view| state::apply_profiles(win, &snap, &view.last_status));
                        });
                    }
                    Err(e) => {
                        let msg = format!("{:#}", e);
                        let win_weak = win_weak.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(w) = win_weak.upgrade() {
                                w.set_editor_parse_error(msg.into());
                            }
                        });
                    }
                }
            }

            UiCommand::DeleteActiveProfile => {
                let mut ps = profiles.lock().await;
                if let Some(id) = ps.active_id.clone() {
                    ps.remove(&id);
                    let _ = ps.save();
                    let snap = ps.clone_snapshot();
                    drop(ps);
                    let win_weak = win_weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        with_view(&win_weak, |win, view| state::apply_profiles(win, &snap, &view.last_status));
                    });
                }
            }

            UiCommand::EditActiveProfile => {
                let ps = profiles.lock().await;
                if let Some(p) = ps.active().cloned() {
                    drop(ps);
                    let win_weak = win_weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(w) = win_weak.upgrade() {
                            w.set_editor_name(p.name.into());
                            w.set_editor_conn(p.conn_string.into());
                            w.set_editor_admin_url(p.admin_url.unwrap_or_default().into());
                            w.set_editor_admin_token(p.admin_token.unwrap_or_default().into());
                            w.set_editor_admin_fp(p.admin_server_cert_fp.unwrap_or_default().into());
                            w.set_editor_parse_error("".into());
                            w.set_editor_parse_ok("".into());
                            w.set_editor_open(true);
                        }
                    });
                }
            }

            UiCommand::LogsClear => {
                let win_weak = win_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    with_view(&win_weak, |win, view| {
                        view.logs.clear();
                        state::apply_logs(win, view);
                        let level = win.get_logs_level_filter().to_string();
                        let substr = win.get_logs_substring_filter().to_string();
                        state::apply_logs_screen(win, view, &level, &substr);
                    });
                });
            }

            UiCommand::AdminOpen | UiCommand::AdminRefresh => {
                admin_refresh(&profiles, &win_weak).await;
            }
            UiCommand::AdminAddSubmit { name, expires_days } => {
                let Some(ac) = make_admin_client(&profiles).await else {
                    set_admin_status(&win_weak, "Admin credentials missing on active profile.".into());
                    continue;
                };
                match ac.create_client(&name, expires_days).await {
                    Ok(_) => {
                        set_admin_status(&win_weak, format!("created {}", name));
                        admin_refresh(&profiles, &win_weak).await;
                    }
                    Err(e) => set_admin_status(&win_weak, format!("create failed: {:#}", e)),
                }
            }
            UiCommand::AdminRowAction { action, name } => {
                let Some(ac) = make_admin_client(&profiles).await else {
                    set_admin_status(&win_weak, "Admin credentials missing on active profile.".into());
                    continue;
                };
                let res: anyhow::Result<String> = match action.as_str() {
                    "extend30" => ac.extend_subscription(&name, 30).await.map(|_| format!("+30d on {}", name)),
                    "extend90" => ac.extend_subscription(&name, 90).await.map(|_| format!("+90d on {}", name)),
                    "enable"   => ac.toggle_enabled(&name, true).await.map(|_| format!("enabled {}", name)),
                    "disable"  => ac.toggle_enabled(&name, false).await.map(|_| format!("disabled {}", name)),
                    "delete"   => ac.delete_client(&name).await.map(|_| format!("deleted {}", name)),
                    "copy_conn" => {
                        match ac.get_conn_string(&name).await {
                            Ok(s) => {
                                if let Ok(mut cb) = arboard::Clipboard::new() { let _ = cb.set_text(s); }
                                Ok(format!("copied conn string for {}", name))
                            }
                            Err(e) => Err(e),
                        }
                    }
                    _ => Ok(String::new()),
                };
                match res {
                    Ok(msg) => set_admin_status(&win_weak, msg),
                    Err(e) => set_admin_status(&win_weak, format!("{}: {:#}", action, e)),
                }
                admin_refresh(&profiles, &win_weak).await;
            }

            UiCommand::SettingsToggleAutostart(target) => {
                let res = tokio::task::spawn_blocking(move || {
                    settings::systemd_autostart_set(target)
                }).await.unwrap_or_else(|e| Err(anyhow::anyhow!("join: {}", e)));
                let (new_state, status) = match res {
                    Ok(_) => (settings::systemd_autostart_is_enabled(), String::new()),
                    Err(e) => (settings::systemd_autostart_is_enabled(), format!("{:#}", e)),
                };
                let win_weak = win_weak.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(w) = win_weak.upgrade() {
                        w.set_setting_autostart(new_state);
                        w.set_settings_autostart_status(status.into());
                        save_settings_from_ui(&w);
                    }
                });
            }

            UiCommand::SettingsCopyDebug => {
                // Collect debug report from UI-accessible view-state + env.
                let report = build_debug_report(&profiles, &win_weak).await;
                if let Ok(mut cb) = arboard::Clipboard::new() {
                    let _ = cb.set_text(report);
                }
            }
        }

        // Keep tray state synced — only for connection-affecting commands.
        if tray_relevant {
            if let Some(th) = &tray_handle {
                let win_weak = win_weak.clone();
                let th = th.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(w) = win_weak.upgrade() {
                        let connected = w.get_state_kind() == "connected";
                        th.update(|t| { t.connected = connected; });
                    }
                });
            }
        }
    }
}

fn with_view(win_weak: &slint::Weak<MainWindow>, f: impl FnOnce(&MainWindow, &mut ViewState)) {
    thread_local! {
        static VIEW: RefCell<Option<ViewState>> = RefCell::new(None);
    }
    if let Some(w) = win_weak.upgrade() {
        VIEW.with(|v| {
            let mut v = v.borrow_mut();
            if v.is_none() { *v = Some(ViewState::new()); }
            f(&w, v.as_mut().unwrap());
        });
    }
}

fn apply_ui_event(window: &MainWindow, view: &mut ViewState, ev: UiEvent) {
    match ev {
        UiEvent::Status(s) => {
            state::apply_status(window, view, &s);
            // Profiles refresh is handled by the periodic 1s task — no need to
            // reload from disk on every status tick (was causing disk I/O at 4 Hz).
        }
        UiEvent::Log(l) => {
            view.push_log(l);
            state::apply_logs(window, view);
            let level = window.get_logs_level_filter().to_string();
            let substr = window.get_logs_substring_filter().to_string();
            state::apply_logs_screen(window, view, &level, &substr);
        }
        UiEvent::Disconnected => {
            let mut s = view.last_status.clone();
            s.state = ghoststream_gui_ipc::ConnState::Disconnected;
            s.streams_up = 0;
            state::apply_status(window, view, &s);
        }
        UiEvent::Error(msg) => {
            let mut s = view.last_status.clone();
            s.state = ghoststream_gui_ipc::ConnState::Error;
            s.last_error = Some(msg);
            state::apply_status(window, view, &s);
        }
    }
}

fn push_error(win_weak: &slint::Weak<MainWindow>, msg: String) {
    let win_weak = win_weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        with_view(&win_weak, |win, view| {
            let mut s = view.last_status.clone();
            s.state = ghoststream_gui_ipc::ConnState::Error;
            s.last_error = Some(msg);
            state::apply_status(win, view, &s);
        });
    });
}

fn validate_conn_string(s: &str) -> (String, String) {
    let s = s.trim();
    if s.is_empty() { return (String::new(), String::new()); }
    match client_common::helpers::parse_conn_string(s) {
        Ok(cfg) => {
            let summary = format!(
                "{} · sni {} · tun {}",
                cfg.network.server_addr,
                cfg.network.server_name.as_deref().unwrap_or("?"),
                cfg.network.tun_addr.as_deref().unwrap_or("?"),
            );
            (String::new(), summary)
        }
        Err(e) => (format!("{:#}", e), String::new()),
    }
}

// ── Settings helpers ──────────────────────────────────────────────────────

fn save_settings_from_ui(w: &MainWindow) {
    let s = settings::UserSettings {
        dns_leak_protection: w.get_setting_dns_leak(),
        ipv6_killswitch: w.get_setting_ipv6_ks(),
        auto_reconnect: w.get_setting_autorec(),
        autostart: w.get_setting_autostart(),
        start_minimized: w.get_setting_start_min(),
        theme_accent: None,
    };
    if let Err(e) = s.save() {
        tracing::warn!(?e, "save settings");
    }
}

// ── Admin helpers ─────────────────────────────────────────────────────────

async fn make_admin_client(
    profiles: &Arc<Mutex<profiles::Store>>,
) -> Option<admin_api::AdminClient> {
    let ps = profiles.lock().await;
    let active = ps.active()?.clone();
    drop(ps);
    let url = active.admin_url.as_deref()?;
    let token = active.admin_token.as_deref()?;
    let fp = active.admin_server_cert_fp.as_deref();
    match admin_api::AdminClient::new(url, token, fp) {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::warn!(?e, "admin client");
            None
        }
    }
}

fn set_admin_status(win_weak: &slint::Weak<MainWindow>, msg: String) {
    let win_weak = win_weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        if let Some(w) = win_weak.upgrade() {
            w.set_admin_status_line(msg.into());
        }
    });
}

async fn admin_refresh(
    profiles: &Arc<Mutex<profiles::Store>>,
    win_weak: &slint::Weak<MainWindow>,
) {
    let Some(ac) = make_admin_client(profiles).await else {
        set_admin_status(win_weak, "No admin URL/token on active profile.".into());
        let win_weak = win_weak.clone();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_admin_rows(slint::ModelRc::new(slint::VecModel::from(Vec::<AdminClientRow>::new())));
                w.set_admin_busy(false);
            }
        });
        return;
    };

    {
        let win_weak = win_weak.clone();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(w) = win_weak.upgrade() {
                w.set_admin_busy(true);
                w.set_admin_status_line("".into());
            }
        });
    }

    let status = ac.server_status().await.ok();
    let clients = ac.list_clients().await;
    let win_weak = win_weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        let Some(w) = win_weak.upgrade() else { return };
        w.set_admin_busy(false);
        if let Some(s) = &status {
            w.set_admin_server_status(AdminServerStatus {
                uptime:    format_uptime(s.uptime_secs).into(),
                sessions:  format!("{}", s.active_sessions).into(),
                cpu:       s.cpu_pct.map(|v| format!("{:.1}%", v)).unwrap_or_else(|| "—".into()).into(),
                server_ip: s.server_ip.clone().unwrap_or_else(|| "—".into()).into(),
            });
        }
        match clients {
            Ok(list) => {
                let rows: Vec<AdminClientRow> = list.iter().map(|c| {
                    let status = if !c.enabled { "disabled" }
                        else if c.days_left().map(|d| d < 0).unwrap_or(false) { "expired" }
                        else if c.connected { "active" }
                        else { "idle" };
                    let (expiry, expiry_kind) = match c.days_left() {
                        None => ("∞".to_string(), "ok"),
                        Some(d) if d < 0 => ("exp".to_string(), "bad"),
                        Some(d) if d < 7 => (format!("{}d", d), "warn"),
                        Some(d) => (format!("{}d", d), "ok"),
                    };
                    AdminClientRow {
                        name: c.name.clone().into(),
                        tun_addr: c.tun_addr.clone().into(),
                        status: status.into(),
                        expiry: expiry.into(),
                        expiry_kind: expiry_kind.to_string().into(),
                        traffic: format!("{}  ↓    {}  ↑",
                            humanize_bytes_short(c.bytes_rx),
                            humanize_bytes_short(c.bytes_tx)).into(),
                        is_admin: c.is_admin,
                    }
                }).collect();
                w.set_admin_rows(slint::ModelRc::new(slint::VecModel::from(rows)));
            }
            Err(e) => {
                w.set_admin_status_line(format!("load failed: {:#}", e).into());
            }
        }
    });
}

fn format_uptime(s: u64) -> String {
    let h = s / 3600;
    let m = (s % 3600) / 60;
    if h > 0 { format!("{}h {:02}m", h, m) } else { format!("{}m", m) }
}

fn humanize_bytes_short(n: u64) -> String {
    const K: u64 = 1024;
    const M: u64 = K * 1024;
    const G: u64 = M * 1024;
    if n >= G { format!("{:.1} GB", n as f64 / G as f64) }
    else if n >= M { format!("{:.0} MB", n as f64 / M as f64) }
    else if n >= K { format!("{:.0} KB", n as f64 / K as f64) }
    else { format!("{} B", n) }
}

async fn build_debug_report(
    profiles: &Arc<Mutex<profiles::Store>>,
    win_weak: &slint::Weak<MainWindow>,
) -> String {
    let mut buf = String::new();
    buf.push_str("GhostStream — debug report\n");
    buf.push_str(&format!("version: 0.19.4\n"));
    buf.push_str(&format!("platform: linux · {}\n", std::env::consts::ARCH));
    let ps = profiles.lock().await;
    if let Some(p) = ps.active() {
        buf.push_str(&format!("active profile: {} ({} · sni {})\n", p.name, p.server_addr, p.sni));
    } else {
        buf.push_str("active profile: —\n");
    }
    drop(ps);
    let us = settings::UserSettings::load();
    buf.push_str(&format!(
        "settings: dns_leak={} ipv6_ks={} reconnect={} autostart={}\n",
        us.dns_leak_protection, us.ipv6_killswitch, us.auto_reconnect, us.autostart
    ));

    // Pull last ~500 lines from the UI view.
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let win_weak = win_weak.clone();
    let _ = slint::invoke_from_event_loop(move || {
        let mut out = String::new();
        if let Some(w) = win_weak.upgrade() {
            use slint::Model;
            let m = w.get_logs_all();
            let total = m.row_count();
            let start = total.saturating_sub(500);
            for i in start..total {
                if let Some(r) = m.row_data(i) {
                    out.push_str(&format!("{} {} {}\n", r.ts, r.level, r.msg));
                }
            }
        }
        let _ = tx.send(out);
    });
    if let Ok(logs) = rx.recv_timeout(std::time::Duration::from_secs(2)) {
        buf.push_str("\n── logs tail ──\n");
        buf.push_str(&logs);
    }
    buf
}

fn derive_default_name(conn: &str) -> String {
    match client_common::helpers::parse_conn_string(conn) {
        Ok(cfg) => cfg.network.server_name.unwrap_or_else(|| cfg.network.server_addr),
        Err(_) => "New Profile".to_string(),
    }
}

// ── Store snapshot helper ──────────────────────────────────────────────────

impl profiles::Store {
    pub fn clone_snapshot(&self) -> Self {
        Self {
            profiles: self.profiles.clone(),
            active_id: self.active_id.clone(),
        }
    }
}
