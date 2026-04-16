//! System tray (StatusNotifierItem via `ksni`).
//!
//! Shows a "G" glyph — hair/outline when disconnected, signal-coloured when
//! connected. Clicking activates the main window; the menu exposes Connect /
//! Disconnect / Show / Quit.

use ksni::{menu::StandardItem, Handle, MenuItem, Tray, TrayService};
use tokio::sync::mpsc::UnboundedSender;

#[derive(Debug, Clone, Copy)]
pub enum TrayEvent {
    ShowWindow,
    Connect,
    Disconnect,
    Quit,
}

pub struct MyTray {
    pub connected: bool,
    pub tx: UnboundedSender<TrayEvent>,
}

impl MyTray {
    /// Rasterised 22×22 ARGB icon used by ksni (`Vec<ksni::Icon>`).
    fn icon(&self) -> Vec<ksni::Icon> {
        let size = 22i32;
        let mut argb: Vec<u8> = vec![0; (size * size * 4) as usize];

        // Colour (RGB) — hair (gold-tan) off, signal (lime) on.
        let (r, g, b) = if self.connected {
            (0xC4, 0xFF, 0x3E)
        } else {
            (0x94, 0x8A, 0x6F)
        };

        // Very compact "G" monogram mask. Rough circle stroke + inner cut.
        let cx = size as f32 / 2.0;
        let cy = size as f32 / 2.0;
        let r_outer = (size as f32 / 2.0) - 2.0;
        let r_inner = r_outer - 2.2;
        for py in 0..size {
            for px in 0..size {
                let dx = px as f32 + 0.5 - cx;
                let dy = py as f32 + 0.5 - cy;
                let d = (dx * dx + dy * dy).sqrt();
                let on_ring = d <= r_outer && d >= r_inner;
                // cut out right-center opening to form "G"
                let cutout = dx >= 0.0 && dy.abs() < 2.0;
                // inner horizontal serif
                let serif = dx >= 0.0 && dx <= r_outer - 2.0 && dy.abs() < 1.0 && dy >= 0.0;
                let lit = (on_ring && !cutout) || serif;
                if lit {
                    let idx = ((py * size + px) * 4) as usize;
                    // ksni icon is ARGB big-endian — A, R, G, B.
                    argb[idx] = 0xFF;
                    argb[idx + 1] = r;
                    argb[idx + 2] = g;
                    argb[idx + 3] = b;
                }
            }
        }
        vec![ksni::Icon { width: size, height: size, data: argb }]
    }
}

impl Tray for MyTray {
    fn title(&self) -> String {
        if self.connected { "GhostStream — connected".into() }
        else { "GhostStream".into() }
    }

    fn icon_name(&self) -> String {
        // themed icon fallback if pixmap isn't rendered by the shell
        if self.connected { "network-vpn-symbolic".into() }
        else { "network-vpn-disconnected-symbolic".into() }
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> { self.icon() }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.tx.send(TrayEvent::ShowWindow);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            StandardItem {
                label: "Show GhostStream".into(),
                activate: Box::new(|t: &mut Self| { let _ = t.tx.send(TrayEvent::ShowWindow); }),
                ..Default::default()
            }.into(),
            MenuItem::Separator,
            StandardItem {
                label: "Connect".into(),
                enabled: !self.connected,
                activate: Box::new(|t: &mut Self| { let _ = t.tx.send(TrayEvent::Connect); }),
                ..Default::default()
            }.into(),
            StandardItem {
                label: "Disconnect".into(),
                enabled: self.connected,
                activate: Box::new(|t: &mut Self| { let _ = t.tx.send(TrayEvent::Disconnect); }),
                ..Default::default()
            }.into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(|t: &mut Self| { let _ = t.tx.send(TrayEvent::Quit); }),
                ..Default::default()
            }.into(),
        ]
    }
}

/// Start the tray service in a detached thread. Returns a handle so the GUI
/// can mutate connected-state via `handle.update(|t| t.connected = …)`.
pub fn spawn_tray(events_tx: UnboundedSender<TrayEvent>) -> anyhow::Result<Handle<MyTray>> {
    let tray = MyTray { connected: false, tx: events_tx };
    let service = TrayService::new(tray);
    let handle = service.handle();
    service.spawn();
    Ok(handle)
}
