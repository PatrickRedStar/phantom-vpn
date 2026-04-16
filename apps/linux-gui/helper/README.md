# ghoststream-helper (implemented)

The helper lives at **`apps/linux-gui-helper/`** as a peer workspace crate.
This directory is kept only for backwards-reference — the original skeleton
planned the helper as a sub-crate under `apps/linux-gui/helper/`, but making
it a sibling keeps Cargo simpler.

## What the helper does

- Runs as root (spawned via `pkexec /usr/bin/ghoststream-helper`)
- Listens on `$XDG_RUNTIME_DIR/ghoststream.sock` (chowned to the invoking
  user; mode 0600)
- Accepts a single newline-delimited JSON protocol (see
  `crates/gui-ipc/src/lib.rs`)
- Owns `/dev/net/tun`, policy routing rules (fwmark 0x50 + table 51820),
  and the live TLS tunnel via `crates/client-common`
- Streams `StatusFrame` telemetry at 4 Hz and (optionally) `LogFrame`
  log lines once the GUI sends `SubscribeLogs`

Environment variables the helper reads (set by pkexec):
- `PKEXEC_UID` / `PKEXEC_GID` — the launching user's IDs
- `SUDO_UID` / `SUDO_GID` — fallback when started via `sudo`
