# ghoststream-gui

GhostStream Linux desktop client — Slint 1.8 UI shell.

**Status:** UI skeleton only. All telemetry comes from `src/mock.rs`. No real
tunnel, no IPC, no system tray. The privileged `ghoststream-helper` is
planned for the next commit (see `helper/README.md`).

## Build

From the workspace root:

```bash
cargo build -p ghoststream-gui --release
# binary: target/release/ghoststream-gui
```

Slint picks the best available rendering backend at runtime. On a fresh
Linux system you may need:

```bash
# Debian/Ubuntu
sudo apt install libfontconfig1 libxkbcommon0 libwayland-client0 libxcb1

# Arch / CachyOS
sudo pacman -S fontconfig libxkbcommon wayland libxcb
```

## Run

```bash
./target/release/ghoststream-gui
```

Window opens at 1280×800. The mock generator updates RX/TX, stream activity,
the session timer, and adds a fresh log line every ~2 s. All header buttons
log to stderr via `tracing` — set `RUST_LOG=debug` to see clicks.

## Fonts

Embedded into the binary via `include_bytes!`, so no system font install is
required:

| Slot | File | Source |
|------|------|--------|
| Display headers (`Instrument Serif`) | `assets/fonts/InstrumentSerif-{Regular,Italic}.ttf` | Google Fonts (SIL OFL) |
| Mono / numerals (`Departure Mono`) | `assets/fonts/DepartureMono-Regular.otf` | https://departuremono.com (SIL OFL) |
| Body / logs (`JetBrains Mono`) | `assets/fonts/JetBrainsMono-Regular.ttf` | JetBrains (SIL OFL) |

## Layout

```
ui/
  theme.slint         — color & typography tokens
  topbar.slint        — header (brand, ticker, controls)
  profiles.slint      — left rail (profile list)
  oscilloscope.slint  — RX/TX throughput chart (Slint Path)
  mux.slint           — stream multiplex bars + session table
  rightrail.slint     — topology + log tail
  stage.slint         — central stage compositor
  main.slint          — root MainWindow component
src/
  main.rs             — entrypoint (font registration, timer, callbacks)
  state.rs            — Slint property bridge
  mock.rs             — telemetry mock
  ipc.rs              — placeholder for helper IPC
helper/               — placeholder for the privileged binary (next commit)
```

## Mockup parity

- Tone (warm near-black, lime-on-warm-bg) matches `design/mockup.html`.
- Fonts match (Instrument Serif italic for the state word, Departure Mono for
  data, JetBrains Mono for body & logs).
- Chart, mux bars, session table, topology, logs tail, footer — all present.

### Simplifications vs. mockup

- The state word `Transmitting.` is rendered in a single color (signal
  green). Slint `Text` cannot mix two colors inside one run; the period dot
  fix-up will arrive when we split into two `Text` nodes within an `HBox`.
- `border-style: dashed` is not supported by Slint; profile separators are
  rendered as solid hairlines at reduced opacity.
- The full-page grain overlay and radial gradients from CSS are dropped —
  Slint has no easy equivalent without a custom shader pass.
- The diagonal corner accent in the stage is approximated with a rotated
  thin rectangle.

## Next steps

1. `ghoststream-helper` binary + JSON IPC (`apps/linux-gui/helper/`).
2. Wire `Connect` / `Disconnect` to a real tunnel via `crates/client-common`.
3. System tray (`tray-icon` crate) + autostart toggle (systemd user unit).
4. PKGBUILD for Arch / CachyOS, AppImage manifest.
