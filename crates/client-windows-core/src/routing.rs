//! Windows routing helpers.
//!
//! The Wintun adapter alone does not steer traffic — Windows still
//! prefers its physical default route until we tell it otherwise. This
//! module owns the small `netsh` choreography that:
//!
//! * Discovers the current IPv4 default gateway so we can pin the route
//!   to the VPN server **before** we install our own default route
//!   (otherwise the TLS handshake recurses into the tunnel — P0-2).
//! * Installs a split default route via Wintun (`0.0.0.0/1` +
//!   `128.0.0.0/1`) so the OS prefers our adapter without us actually
//!   removing the original `0.0.0.0/0`. Standard VPN pattern — surviving
//!   a crash leaves the user's routing table intact.
//! * Bumps the Wintun adapter metric to `1` so Windows' interface-pick
//!   logic doesn't fall back to the physical adapter (P1-5).
//! * Routes IPv6 traffic into Wintun via `::/0 metric=1` rather than
//!   disabling IPv6 on the physical adapter — less invasive, doesn't
//!   break IPv6 on the LAN (P1-1).
//!
//! Every route added is tracked in a `RouteScope`; the matching `delete`
//! commands run on `Drop` so a panic or controller crash never strands
//! the user's network.
//!
//! ## Cross-compile note
//!
//! The actual `netsh` invocations only matter on Windows. On the Mac dev
//! host we still compile the bookkeeping (the `RouteScope` struct, the
//! `Drop` impl, the trait-injectable runner) so we can unit-test the
//! state machine without spawning processes — see the tests at the
//! bottom of this file. The `discover_default_gateway` and `*_real`
//! command runners are `cfg(windows)`; the `cfg(not(windows))` stubs in
//! `lib.rs` re-export the cross-platform pieces.

use std::net::Ipv4Addr;
use std::process::Command;

use anyhow::{Context, Result};

/// A single route that `RouteScope` tracks for later teardown.
#[derive(Debug, Clone, PartialEq, Eq)]
enum TrackedRoute {
    /// `netsh interface ipv4 add route <dest>/32 ... <gw>` —
    /// "exclude this host from the tunnel and send it via the real GW".
    HostExclude { dest: Ipv4Addr, gw: Ipv4Addr },
    /// One leg of the split default route via Wintun (`0.0.0.0/1` or
    /// `128.0.0.0/1`). We track each /1 separately so the `Drop` deletes
    /// both.
    SplitDefaultV4 {
        prefix: &'static str, // "0.0.0.0/1" | "128.0.0.0/1"
        adapter_idx: u32,
    },
    /// IPv6 default `::/0` via Wintun.
    DefaultV6 { adapter_idx: u32 },
    /// Adapter metric — we remember the new value but cannot trivially
    /// restore the old one (`netsh` does not surface the previous
    /// metric in a single call). On `Drop` we set it back to `automatic`
    /// (`store=active`) which matches Windows defaults.
    AdapterMetric { adapter_idx: u32 },
}

/// Abstraction over `Command::new(...).status()` so unit tests on the Mac
/// dev host can verify what `RouteScope` would have run without actually
/// shelling out. The default impl shells out via `std::process::Command`
/// and only matters on Windows; tests inject a recording impl.
pub trait CommandRunner: Send + Sync {
    /// Run `prog args...` and return the exit code (or an error if the
    /// process could not even be spawned). Implementations log the full
    /// command line via `tracing::info!` with `category = "routing"`.
    fn run(&self, prog: &str, args: &[&str]) -> Result<i32>;
}

/// Production runner — actually shells out and logs the command line
/// + exit code. Used by `RouteScope::new()`.
pub struct ShellRunner;

impl CommandRunner for ShellRunner {
    fn run(&self, prog: &str, args: &[&str]) -> Result<i32> {
        let cmdline = format!("{} {}", prog, args.join(" "));
        let status = Command::new(prog)
            .args(args)
            .status()
            .with_context(|| format!("spawn `{}`", cmdline))?;
        let code = status.code().unwrap_or(-1);
        tracing::info!(
            category = "routing",
            cmd = %cmdline,
            exit_code = code,
            "route command"
        );
        Ok(code)
    }
}

/// RAII guard that owns every route we've installed for the current
/// VPN session. `Drop` runs the matching `delete` commands in reverse
/// insertion order so the routing table returns to its pre-connect
/// state, even on a panic / process crash.
///
/// The runner is stored as `Box<dyn CommandRunner>` so tests can inject
/// a recording impl. Production code uses `RouteScope::new()` which
/// wires up `ShellRunner`.
pub struct RouteScope {
    runner: Box<dyn CommandRunner>,
    /// Routes added so far, in insertion order. `Drop` walks this in
    /// reverse so e.g. the host-exclude route is removed last — Windows
    /// is generally fine with any order but reverse matches the order
    /// `Linux/macOS` clients use and keeps reasoning local.
    routes: Vec<TrackedRoute>,
}

impl RouteScope {
    /// Production constructor: shells out via `netsh`.
    pub fn new() -> Self {
        Self::with_runner(Box::new(ShellRunner))
    }

    /// Test seam: inject any `CommandRunner` impl.
    pub fn with_runner(runner: Box<dyn CommandRunner>) -> Self {
        Self {
            runner,
            routes: Vec::new(),
        }
    }

    /// Install a `/32` host route via the physical default gateway. We
    /// use this for the VPN server IP itself so the TLS handshake
    /// packets reach `vdsina` directly instead of recursing into the
    /// tunnel we are about to install (P0-2 — the recursion blocker).
    ///
    /// Uses the legacy `route ADD` (not `netsh`) for this one entry
    /// because `route ADD` lets Windows pick the right physical adapter
    /// from the gateway alone — no need to discover the interface index
    /// of the physical NIC, which is fragile across Wi-Fi / Ethernet /
    /// USB tether changes. The OpenVPN tap driver uses the same trick.
    pub fn add_host_via_gateway(&mut self, dest: Ipv4Addr, gw: Ipv4Addr) -> Result<()> {
        let dest_s = dest.to_string();
        let gw_s = gw.to_string();
        let args = vec![
            "ADD",
            &dest_s,
            "MASK",
            "255.255.255.255",
            &gw_s,
            "METRIC",
            "5",
        ];
        let code = self.runner.run("route", &args)?;
        if code != 0 {
            anyhow::bail!(
                "route ADD {} via {} exit {}",
                dest,
                gw,
                code
            );
        }
        self.routes.push(TrackedRoute::HostExclude { dest, gw });
        Ok(())
    }

    /// Install the split default route via the Wintun adapter. We
    /// install `0.0.0.0/1` and `128.0.0.0/1` (each covers exactly half
    /// the IPv4 space) with `metric=1` so the OS prefers them over the
    /// untouched `0.0.0.0/0`. Standard VPN pattern: avoids touching the
    /// real default route, so even a hard crash leaves the user with
    /// working connectivity once our two halves get garbage-collected.
    pub fn add_default_via_adapter(&mut self, wintun_adapter_idx: u32) -> Result<()> {
        let idx = wintun_adapter_idx.to_string();
        for prefix in ["0.0.0.0/1", "128.0.0.0/1"] {
            let args = vec![
                "interface",
                "ipv4",
                "add",
                "route",
                prefix,
                &idx,
                "metric=1",
                "store=active",
            ];
            let code = self.runner.run("netsh", &args)?;
            if code != 0 {
                anyhow::bail!(
                    "netsh add default leg {} via idx {} exit {}",
                    prefix,
                    wintun_adapter_idx,
                    code
                );
            }
            self.routes.push(TrackedRoute::SplitDefaultV4 {
                prefix,
                adapter_idx: wintun_adapter_idx,
            });
        }
        Ok(())
    }

    /// Pin the Wintun adapter metric so Windows' interface-pick logic
    /// always prefers our adapter even if a physical interface has a
    /// lower metric. P1-5.
    pub fn set_adapter_metric(&mut self, idx: u32, metric: u32) -> Result<()> {
        let idx_s = idx.to_string();
        let metric_kv = format!("metric={}", metric);
        let args = vec![
            "interface",
            "ipv4",
            "set",
            "interface",
            &idx_s,
            &metric_kv,
            "store=active",
        ];
        let code = self.runner.run("netsh", &args)?;
        if code != 0 {
            anyhow::bail!(
                "netsh set adapter idx {} metric {} exit {}",
                idx,
                metric,
                code
            );
        }
        self.routes.push(TrackedRoute::AdapterMetric { adapter_idx: idx });
        Ok(())
    }

    /// Route IPv6 *into* Wintun rather than disabling IPv6 on the
    /// physical adapter. This still kills IPv6 leaks (P1-1) because
    /// any v6 packet that previously went out via the physical adapter
    /// now enters the encrypted tunnel — but it does not break IPv6 LAN
    /// neighbour discovery or DHCPv6 on the host, which the more
    /// invasive "disable IPv6 on the NIC" approach would.
    pub fn enable_ipv6_default_via_adapter(&mut self, idx: u32) -> Result<()> {
        let idx_s = idx.to_string();
        let args = vec![
            "interface",
            "ipv6",
            "add",
            "route",
            "::/0",
            &idx_s,
            "metric=1",
            "store=active",
        ];
        let code = self.runner.run("netsh", &args)?;
        if code != 0 {
            anyhow::bail!(
                "netsh add v6 default via idx {} exit {}",
                idx,
                code
            );
        }
        self.routes.push(TrackedRoute::DefaultV6 { adapter_idx: idx });
        Ok(())
    }

    /// For tests: peek at the tracked routes without consuming the
    /// scope. Not exposed publicly — only the test module reaches in.
    #[cfg(test)]
    fn tracked(&self) -> &[TrackedRoute] {
        &self.routes
    }
}

impl Default for RouteScope {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for RouteScope {
    fn drop(&mut self) {
        // Iterate in reverse insertion order so e.g. the host-exclude
        // route (added first) is torn down last. Every command is
        // best-effort — we log but never panic in a destructor.
        for route in self.routes.drain(..).rev() {
            let result = match route {
                TrackedRoute::HostExclude { dest, gw: _ } => {
                    let dest_s = dest.to_string();
                    self.runner.run("route", &["DELETE", &dest_s])
                }
                TrackedRoute::SplitDefaultV4 {
                    prefix,
                    adapter_idx,
                } => {
                    let idx_s = adapter_idx.to_string();
                    self.runner.run(
                        "netsh",
                        &["interface", "ipv4", "delete", "route", prefix, &idx_s],
                    )
                }
                TrackedRoute::DefaultV6 { adapter_idx } => {
                    let idx_s = adapter_idx.to_string();
                    self.runner.run(
                        "netsh",
                        &["interface", "ipv6", "delete", "route", "::/0", &idx_s],
                    )
                }
                TrackedRoute::AdapterMetric { adapter_idx } => {
                    // Restore "automatic" — Windows default. We don't
                    // try to read the previous value back; reverting to
                    // automatic is what every other VPN does.
                    let idx_s = adapter_idx.to_string();
                    self.runner.run(
                        "netsh",
                        &[
                            "interface",
                            "ipv4",
                            "set",
                            "interface",
                            &idx_s,
                            "metric=automatic",
                            "store=active",
                        ],
                    )
                }
            };
            if let Err(e) = result {
                tracing::warn!(
                    category = "routing",
                    error = %e,
                    "route teardown failed (best-effort, continuing)"
                );
            }
        }
    }
}

// ── IPv4 default gateway discovery (Windows-only) ─────────────────────────

/// Discover the current IPv4 default gateway by parsing `route print -4`.
///
/// We **must** call this before installing the tunnel route, otherwise
/// the lookup will pick up our own `0.0.0.0/1 → Wintun` and recurse. The
/// helper deliberately filters out routes whose interface looks like the
/// Wintun adapter ("GhostStream" by name) — that branch only matters if
/// a leftover route from a prior crash is still in the table.
///
/// Returns the first usable IPv4 gateway. If the host has multiple
/// physical interfaces (uncommon — typical case is one Wi-Fi or one
/// Ethernet), the metric-sorted first row from `route print` wins. This
/// matches what Windows itself uses for outbound traffic.
#[cfg(windows)]
pub fn discover_default_gateway() -> Result<Ipv4Addr> {
    use std::process::Stdio;

    let output = Command::new("route")
        .args(["print", "-4"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .context("spawn `route print -4`")?;
    if !output.status.success() {
        anyhow::bail!(
            "`route print -4` exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_route_print(&stdout).context("parse `route print -4` output")
}

/// Cross-platform stub — non-Windows callers never reach the production
/// path. We surface a clear error so a stray reference fails loudly.
#[cfg(not(windows))]
pub fn discover_default_gateway() -> Result<Ipv4Addr> {
    anyhow::bail!("discover_default_gateway is Windows-only")
}

/// Pure parser, factored out so the unit tests can feed it captured
/// `route print` output. Looks for the `0.0.0.0` line under the
/// "IPv4 Route Table" header. Columns are:
///
/// ```text
///   Network Destination        Netmask          Gateway       Interface  Metric
///           0.0.0.0          0.0.0.0      192.168.1.1   192.168.1.42      25
/// ```
///
/// We pick the first `0.0.0.0 0.0.0.0` row whose gateway parses as
/// IPv4 and is not itself the unspecified address (`0.0.0.0` means
/// "directly connected", which is what Wintun reports — we want the
/// real physical hop).
#[cfg_attr(not(any(windows, test)), allow(dead_code))]
fn parse_route_print(stdout: &str) -> Result<Ipv4Addr> {
    for line in stdout.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        // Expected layout: dest mask gw iface metric — at least 4 cols.
        if parts.len() < 4 {
            continue;
        }
        if parts[0] != "0.0.0.0" || parts[1] != "0.0.0.0" {
            continue;
        }
        let gw: Ipv4Addr = match parts[2].parse() {
            Ok(g) => g,
            Err(_) => continue,
        };
        if gw.is_unspecified() {
            // "On-link" / loopback-y entry — skip, keep looking for the
            // real upstream hop.
            continue;
        }
        return Ok(gw);
    }
    anyhow::bail!("no IPv4 default gateway found in `route print -4` output")
}

// ── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;
    use std::sync::Arc;

    /// Recording runner: captures every command line that would have
    /// been executed. `exit_code` is returned unconditionally so tests
    /// can simulate `netsh` success/failure.
    struct RecordingRunner {
        log: Arc<Mutex<Vec<String>>>,
        exit_code: i32,
    }

    impl RecordingRunner {
        fn new(exit_code: i32) -> (Self, Arc<Mutex<Vec<String>>>) {
            let log = Arc::new(Mutex::new(Vec::new()));
            (
                Self {
                    log: log.clone(),
                    exit_code,
                },
                log,
            )
        }
    }

    impl CommandRunner for RecordingRunner {
        fn run(&self, prog: &str, args: &[&str]) -> Result<i32> {
            self.log
                .lock()
                .push(format!("{} {}", prog, args.join(" ")));
            Ok(self.exit_code)
        }
    }

    #[test]
    fn add_host_route_records_and_tracks() {
        let (runner, log) = RecordingRunner::new(0);
        let mut scope = RouteScope::with_runner(Box::new(runner));
        scope
            .add_host_via_gateway(
                Ipv4Addr::new(89, 110, 109, 128),
                Ipv4Addr::new(192, 168, 1, 1),
            )
            .unwrap();

        let log_lines = log.lock().clone();
        assert_eq!(log_lines.len(), 1);
        assert!(
            log_lines[0].starts_with("route ADD 89.110.109.128"),
            "got: {}",
            log_lines[0]
        );
        assert!(log_lines[0].contains("MASK 255.255.255.255"));
        assert!(log_lines[0].contains("192.168.1.1"));
        assert_eq!(scope.tracked().len(), 1);
        std::mem::forget(scope); // Don't run Drop, we already inspected.
    }

    #[test]
    fn split_default_adds_two_legs() {
        let (runner, log) = RecordingRunner::new(0);
        let mut scope = RouteScope::with_runner(Box::new(runner));
        scope.add_default_via_adapter(42).unwrap();

        let log_lines = log.lock().clone();
        assert_eq!(log_lines.len(), 2);
        assert!(log_lines[0].contains("0.0.0.0/1"));
        assert!(log_lines[1].contains("128.0.0.0/1"));
        // Both legs reference the adapter index.
        assert!(log_lines[0].contains(" 42 "));
        assert!(log_lines[1].contains(" 42 "));
        assert_eq!(scope.tracked().len(), 2);
        std::mem::forget(scope);
    }

    #[test]
    fn adapter_metric_and_v6_recorded() {
        let (runner, log) = RecordingRunner::new(0);
        let mut scope = RouteScope::with_runner(Box::new(runner));
        scope.set_adapter_metric(7, 1).unwrap();
        scope.enable_ipv6_default_via_adapter(7).unwrap();

        let log_lines = log.lock().clone();
        assert_eq!(log_lines.len(), 2);
        assert!(log_lines[0].contains("set interface 7"));
        assert!(log_lines[0].contains("metric=1"));
        assert!(log_lines[1].contains("ipv6"));
        assert!(log_lines[1].contains("::/0"));
        assert_eq!(scope.tracked().len(), 2);
        std::mem::forget(scope);
    }

    #[test]
    fn nonzero_exit_bubbles_as_error_and_does_not_track() {
        let (runner, _log) = RecordingRunner::new(1);
        let mut scope = RouteScope::with_runner(Box::new(runner));
        let err = scope
            .add_host_via_gateway(
                Ipv4Addr::new(1, 2, 3, 4),
                Ipv4Addr::new(10, 0, 0, 1),
            )
            .unwrap_err();
        assert!(err.to_string().contains("exit 1"), "got: {err}");
        // No route tracked → Drop must not attempt to delete it.
        assert_eq!(scope.tracked().len(), 0);
    }

    #[test]
    fn drop_runs_delete_in_reverse_order() {
        let (runner, log) = RecordingRunner::new(0);
        {
            let mut scope = RouteScope::with_runner(Box::new(runner));
            scope
                .add_host_via_gateway(
                    Ipv4Addr::new(89, 110, 109, 128),
                    Ipv4Addr::new(192, 168, 1, 1),
                )
                .unwrap();
            scope.add_default_via_adapter(42).unwrap();
            scope.set_adapter_metric(42, 1).unwrap();
            scope.enable_ipv6_default_via_adapter(42).unwrap();
            // 1 + 2 + 1 + 1 = 5 add commands
        } // scope dropped → 5 delete commands

        let log_lines = log.lock().clone();
        assert_eq!(log_lines.len(), 10, "5 add + 5 delete = 10");

        // First 5 are adds; last 5 are deletes in reverse order:
        //   v6 delete, metric restore, default 128/1 delete,
        //   default 0/1 delete, host exclude delete.
        assert!(log_lines[5].contains("ipv6"), "expected v6 delete, got: {}", log_lines[5]);
        assert!(log_lines[5].contains("delete"));
        assert!(log_lines[6].contains("metric=automatic"), "expected metric restore, got: {}", log_lines[6]);
        assert!(log_lines[7].contains("128.0.0.0/1"));
        assert!(log_lines[7].contains("delete"));
        assert!(log_lines[8].contains("0.0.0.0/1"));
        assert!(log_lines[8].contains("delete"));
        assert!(
            log_lines[9].starts_with("route DELETE 89.110.109.128"),
            "expected legacy `route DELETE` for host exclude, got: {}",
            log_lines[9]
        );
    }

    #[test]
    fn drop_swallows_delete_failures() {
        // Runner returns nonzero — but on Drop we never want to panic.
        // We can't easily check "didn't panic" without unwind machinery,
        // but `drop(scope)` reaching here at all is the assertion: a
        // panic in a destructor on an Err path would have aborted.
        struct FailDelete {
            saw_delete: Arc<Mutex<bool>>,
        }
        impl CommandRunner for FailDelete {
            fn run(&self, _prog: &str, args: &[&str]) -> Result<i32> {
                // `netsh ... delete ...` or `route DELETE ...`.
                if args.contains(&"delete") || args.contains(&"DELETE") {
                    *self.saw_delete.lock() = true;
                    anyhow::bail!("simulated delete failure")
                } else {
                    Ok(0)
                }
            }
        }
        let saw_delete = Arc::new(Mutex::new(false));
        let runner = FailDelete {
            saw_delete: saw_delete.clone(),
        };
        {
            let mut scope = RouteScope::with_runner(Box::new(runner));
            scope
                .add_host_via_gateway(
                    Ipv4Addr::new(1, 2, 3, 4),
                    Ipv4Addr::new(10, 0, 0, 1),
                )
                .unwrap();
        }
        assert!(*saw_delete.lock(), "delete should have been attempted");
    }

    // ── parser tests ─────────────────────────────────────────────────────

    #[test]
    fn parse_route_print_picks_first_default() {
        // Synthetic but representative output. Real Windows output has
        // ASCII art separators which `split_whitespace` happily ignores.
        let stdout = "
===========================================================================
Interface List
 18...00 ff aa bb cc dd ......Wintun Userspace Tunnel
 12...00 11 22 33 44 55 ......Realtek PCIe GbE
===========================================================================

IPv4 Route Table
===========================================================================
Active Routes:
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0      192.168.1.1   192.168.1.42      25
       10.7.0.0    255.255.255.252       On-link        10.7.0.2     5256
      192.168.1.0    255.255.255.0       On-link    192.168.1.42      281
===========================================================================
";
        let gw = parse_route_print(stdout).expect("should find gateway");
        assert_eq!(gw, Ipv4Addr::new(192, 168, 1, 1));
    }

    #[test]
    fn parse_route_print_skips_unspecified_gateway() {
        // If a stale Wintun-installed default is still in the table with
        // gateway 0.0.0.0 (on-link), we must skip it and find the real one.
        let stdout = "
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0          0.0.0.0        10.7.0.2        1
          0.0.0.0          0.0.0.0      192.168.1.1   192.168.1.42       25
";
        let gw = parse_route_print(stdout).expect("should skip on-link");
        assert_eq!(gw, Ipv4Addr::new(192, 168, 1, 1));
    }

    #[test]
    fn parse_route_print_errors_when_no_default() {
        let stdout = "
Network Destination        Netmask          Gateway       Interface  Metric
       10.7.0.0    255.255.255.252       On-link        10.7.0.2     5256
";
        assert!(parse_route_print(stdout).is_err());
    }
}
