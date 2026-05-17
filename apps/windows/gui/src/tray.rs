//! System tray icon + right-click menu.
//!
//! Built on the cross-platform `tray-icon` crate (Windows + macOS + X11
//! AppIndicator). On Windows it puts an icon in the notification area;
//! menu items emit events that we forward into the same `UiCommand`
//! channel the main window uses, so Connect / Disconnect / Quit work
//! identically from either UI surface.
//!
//! Phase 4.4 ships a basic 16×16 procedural icon (lime square on warm-
//! black) so the tray is functional without needing an .ico file in the
//! repo. A proper ghost glyph lands together with the brand SVG in a
//! later commit.

use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tokio::sync::mpsc::UnboundedSender;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::bridge::UiCommand;

/// Tray icon variants. The "off" icon (idle) is dim grey, the "on" icon
/// (connected) is phosphor-lime — same brand colour as the GhostFab button.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayState {
    Off,
    On,
}

/// Owns the live tray icon and its menu item ids. Kept alive for the
/// duration of the process; dropping it removes the icon from the
/// notification area.
pub struct Tray {
    tray: TrayIcon,
    items: TrayMenuItems,
    state: Arc<Mutex<TrayState>>,
}

struct TrayMenuItems {
    show_id: tray_icon::menu::MenuId,
    connect_id: tray_icon::menu::MenuId,
    disconnect_id: tray_icon::menu::MenuId,
    quit_id: tray_icon::menu::MenuId,
}

impl Tray {
    pub fn build() -> Result<Self> {
        let menu = Menu::new();
        let show_item = MenuItem::new("Show window", true, None);
        let connect_item = MenuItem::new("Initiate tunnel", true, None);
        let disconnect_item = MenuItem::new("Terminate tunnel", false, None);
        let quit_item = MenuItem::new("Quit GhostStream", true, None);

        menu.append_items(&[
            &show_item,
            &PredefinedMenuItem::separator(),
            &connect_item,
            &disconnect_item,
            &PredefinedMenuItem::separator(),
            &quit_item,
        ])
        .context("populate tray menu")?;

        let icon = build_icon(TrayState::Off)?;
        let tray = TrayIconBuilder::new()
            .with_tooltip("GhostStream — Dormant")
            .with_icon(icon)
            .with_menu(Box::new(menu))
            .build()
            .context("build tray icon")?;

        Ok(Self {
            tray,
            items: TrayMenuItems {
                show_id: show_item.id().clone(),
                connect_id: connect_item.id().clone(),
                disconnect_id: disconnect_item.id().clone(),
                quit_id: quit_item.id().clone(),
            },
            state: Arc::new(Mutex::new(TrayState::Off)),
        })
    }

    /// Update tray icon + tooltip to reflect the current state. Called
    /// from the UI thread whenever ConnState changes.
    pub fn set_state(&self, new_state: TrayState, tooltip: &str) {
        let mut current = self.state.lock().expect("tray state poisoned");
        if *current == new_state {
            return;
        }
        match build_icon(new_state) {
            Ok(icon) => {
                let _ = self.tray.set_icon(Some(icon));
            }
            Err(e) => {
                tracing::warn!(error = ?e, "build tray icon failed");
            }
        }
        let _ = self.tray.set_tooltip(Some(tooltip));
        *current = new_state;
    }
}

/// Spawn a Slint timer that drains `MenuEvent` from the global receiver
/// and forwards selections into the UiCommand channel. Must be called on
/// the event-loop thread (Slint timers fire there).
pub fn install_event_pump(
    items: TrayMenuIds,
    cmd_tx: UnboundedSender<UiCommand>,
    on_show: impl Fn() + 'static,
) {
    let receiver = MenuEvent::receiver();
    let on_show = std::rc::Rc::new(on_show);
    let timer = slint::Timer::default();
    timer.start(
        slint::TimerMode::Repeated,
        std::time::Duration::from_millis(100),
        move || {
            while let Ok(event) = receiver.try_recv() {
                if event.id == items.show_id {
                    on_show();
                } else if event.id == items.connect_id {
                    let _ = cmd_tx.send(UiCommand::Connect);
                } else if event.id == items.disconnect_id {
                    let _ = cmd_tx.send(UiCommand::Disconnect);
                } else if event.id == items.quit_id {
                    let _ = cmd_tx.send(UiCommand::Quit);
                    let _ = slint::quit_event_loop();
                }
            }
        },
    );
    // Leak the timer so it lives for the lifetime of the app — the
    // event pump is supposed to run forever, and dropping the Timer
    // would silently cancel future ticks.
    std::mem::forget(timer);
}

/// Subset of `Tray` exposed to the event pump. `MenuEvent::receiver` is
/// global so the pump only needs the item ids, not the icon handle.
#[derive(Clone)]
pub struct TrayMenuIds {
    pub show_id: tray_icon::menu::MenuId,
    pub connect_id: tray_icon::menu::MenuId,
    pub disconnect_id: tray_icon::menu::MenuId,
    pub quit_id: tray_icon::menu::MenuId,
}

impl From<&Tray> for TrayMenuIds {
    fn from(t: &Tray) -> Self {
        Self {
            show_id: t.items.show_id.clone(),
            connect_id: t.items.connect_id.clone(),
            disconnect_id: t.items.disconnect_id.clone(),
            quit_id: t.items.quit_id.clone(),
        }
    }
}

// ── Procedural 16×16 RGBA icon ────────────────────────────────────────────

fn build_icon(state: TrayState) -> Result<Icon> {
    // Phosphor lime when on, faint grey when off.
    let signal = match state {
        TrayState::On => [0xC4, 0xFF, 0x3E, 0xFF],
        TrayState::Off => [0x94, 0x8A, 0x6F, 0xFF],
    };
    let bg = [0x0A, 0x09, 0x08, 0xFF];

    // 16×16 ghost-silhouette mask. 1 = signal pixel, 0 = transparent.
    // Simple stylised body with wavy bottom — readable at tray size.
    let mask: [[u8; 16]; 16] = [
        [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0],
        [0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0],
        [0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 1, 0, 0, 0],
        [0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ];

    let mut rgba = Vec::with_capacity(16 * 16 * 4);
    for row in &mask {
        for &px in row {
            if px == 1 {
                rgba.extend_from_slice(&signal);
            } else {
                rgba.extend_from_slice(&bg);
            }
        }
    }
    Icon::from_rgba(rgba, 16, 16).context("build tray icon from rgba")
}
