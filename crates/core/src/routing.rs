//! IP-based split routing: CIDR list parsing and VPN route computation.
//!
//! Loads "direct" CIDR lists (e.g. geoip country files from v2fly/geoip)
//! and computes the complement — the set of routes that should go through VPN.
//! The complement is passed to Android VpnService.Builder.addRoute() so that
//! "direct" traffic never enters the TUN interface.

use std::net::Ipv4Addr;

use ipnet::{Ipv4Net, Ipv4Subnets};

/// Parsed set of "direct" IPv4 CIDRs and the computed VPN route complement.
pub struct RoutingTable {
    direct: Vec<Ipv4Net>,
}

/// A single route entry for VpnService.Builder.addRoute().
#[derive(Debug, Clone)]
pub struct VpnRoute {
    pub addr: Ipv4Addr,
    pub prefix: u8,
}

/// Upper bound on routes handed to `VpnService.Builder` / `NEPacketTunnelProvider`.
///
/// Android ships the whole route table through a single Binder transaction in
/// `establish()`, and that transaction is capped at ~1 MB. Each route parcels to
/// roughly 25-30 bytes, so ~30k routes lands right at the limit and `establish()`
/// throws `TransactionTooLargeException` — a VPN that refuses to start, which is
/// worse than one that routes imprecisely.
///
/// Measured against v2fly/geoip `ru.txt` (12 813 IPv4 entries, 46.2 M addresses):
///
/// | budget | direct entries kept | routes | address coverage |
/// |--------|--------------------|--------|------------------|
/// | 6 000  | 2 324              | 5 996  | 83.0 %           |
/// | 8 000  | 3 130              | 7 999  | 86.6 %           |
/// | 12 000 | 4 777              | 12 000 | 91.6 %           |
///
/// 8 000 sits just above the 6 285 routes the shipped `/18`-clamped build already
/// produced in production, so it is known-survivable, and buys back ~4 % coverage.
pub const MAX_VPN_ROUTES: usize = 8_000;

impl RoutingTable {
    /// Parse a text file with one CIDR per line. Skips blank lines and `#` comments.
    pub fn from_cidrs(text: &str) -> Self {
        let mut nets: Vec<Ipv4Net> = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Ok(net) = line.parse::<Ipv4Net>() {
                nets.push(net);
            }
            // silently skip IPv6 or malformed lines
        }
        // Aggregate overlapping/adjacent ranges for efficiency
        nets = Ipv4Net::aggregate(&nets);
        Self { direct: nets }
    }

    /// Number of aggregated direct CIDRs.
    pub fn direct_count(&self) -> usize {
        self.direct.len()
    }

    /// Compute VPN routes = complement of direct CIDRs within 0.0.0.0/0.
    ///
    /// Also always excludes private/link-local ranges (10/8, 172.16/12,
    /// 192.168/16, 169.254/16, 127/8) since those should never be tunneled.
    /// Bounded by [`MAX_VPN_ROUTES`]. If the exact complement does not fit, direct
    /// entries are dropped **narrowest-first** until it does.
    ///
    /// Dropping is the only safe way to shed routes: a dropped range simply stays
    /// inside the tunnel. Never shrink this table by *widening* a direct entry — the
    /// Android side used to clamp every prefix to /18, which turned `5.8.16.0/22`
    /// into `5.8.0.0/18` and pushed 16× more addresses out of the tunnel in the
    /// clear, with the user's real IP, while they believed they were covered.
    ///
    /// Widest-first ordering maximises the share of address space that still bypasses
    /// the tunnel per route spent (a /12 protects 1 M addresses for the same ~2
    /// routes a /24 spends on 256).
    pub fn compute_vpn_routes(&self) -> Vec<VpnRoute> {
        let mut routes = complement_of(&self.direct);
        if routes.len() <= MAX_VPN_ROUTES {
            return routes;
        }

        // Widest first, then keep as long a prefix of that list as the budget allows.
        let mut direct = self.direct.clone();
        direct.sort_by_key(|n| n.prefix_len());

        // Route count is monotonic in the number of holes and close to linear
        // (~2.5 routes per hole on ru.txt), so scale the cut proportionally and
        // undershoot a few percent. This converges in one or two passes; a binary
        // search recomputes the complement ~log2(n) times, which measured >1 s on
        // ru.txt-sized input — and this runs on the connect path.
        let mut keep = direct.len();
        for _ in 0..5 {
            let scaled = (keep as u128 * MAX_VPN_ROUTES as u128 / routes.len() as u128) as usize;
            keep = (scaled - scaled / 32).clamp(1, keep.saturating_sub(1));
            routes = complement_of(&direct[..keep]);
            if routes.len() <= MAX_VPN_ROUTES {
                return routes;
            }
        }

        // Pathological input (ratio didn't hold): halve until it fits. Bounded by
        // log2(n) passes and guarantees we never hand back an over-budget table.
        while routes.len() > MAX_VPN_ROUTES && keep > 1 {
            keep /= 2;
            routes = complement_of(&direct[..keep]);
        }
        routes
    }
}

/// Complement of `direct` (plus the always-excluded private/link-local ranges)
/// within `0.0.0.0/0` — i.e. everything that should enter the tunnel.
fn complement_of(direct: &[Ipv4Net]) -> Vec<VpnRoute> {
    let private_ranges: Vec<Ipv4Net> = [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
    ]
    .iter()
    .filter_map(|s| s.parse().ok())
    .collect();

    // Merge direct CIDRs with private ranges — all of these are excluded from VPN
    let mut excluded = direct.to_vec();
    excluded.extend_from_slice(&private_ranges);
    excluded = Ipv4Net::aggregate(&excluded);

    // Compute complement: 0.0.0.0/0 minus all excluded
    let full = "0.0.0.0/0".parse::<Ipv4Net>().unwrap();
    subtract_nets(full, &excluded)
        .into_iter()
        .map(|net| VpnRoute {
            addr: net.network(),
            prefix: net.prefix_len(),
        })
        .collect()
}

/// Subtract a sorted+aggregated set of exclusions from a single parent network.
fn subtract_nets(parent: Ipv4Net, exclusions: &[Ipv4Net]) -> Vec<Ipv4Net> {
    // Start with ranges covering the parent
    let mut remaining: Vec<Ipv4Net> = vec![parent];

    for exc in exclusions {
        let mut next = Vec::new();
        for net in &remaining {
            if !net.contains(exc) && !exc.contains(net) {
                // No overlap — keep as is
                next.push(*net);
            } else if exc.contains(net) {
                // Exclusion fully covers this net — drop it
            } else {
                // Partial overlap — net contains exc, split net around exc
                // Use Ipv4Subnets to enumerate the gaps
                let net_start = net.network();
                let net_end = broadcast(*net);
                let exc_start = exc.network();
                let exc_end = broadcast(*exc);

                // Subnets before the exclusion
                if net_start < exc_start {
                    if let Some(before_end) = prev_addr(exc_start) {
                        let subs = Ipv4Subnets::new(net_start, before_end, 0);
                        next.extend(subs);
                    }
                }
                // Subnets after the exclusion
                if exc_end < net_end {
                    if let Some(after_start) = next_addr(exc_end) {
                        let subs = Ipv4Subnets::new(after_start, net_end, 0);
                        next.extend(subs);
                    }
                }
            }
        }
        remaining = next;
    }

    Ipv4Net::aggregate(&remaining)
}

fn broadcast(net: Ipv4Net) -> Ipv4Addr {
    let ip: u32 = net.network().into();
    let mask: u32 = if net.prefix_len() == 32 {
        0
    } else {
        !0u32 >> net.prefix_len()
    };
    (ip | mask).into()
}

fn prev_addr(addr: Ipv4Addr) -> Option<Ipv4Addr> {
    let n: u32 = addr.into();
    n.checked_sub(1).map(Ipv4Addr::from)
}

fn next_addr(addr: Ipv4Addr) -> Option<Ipv4Addr> {
    let n: u32 = addr.into();
    n.checked_add(1).map(Ipv4Addr::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_cidrs() {
        let text = "# Russian IPs\n1.0.0.0/24\n2.56.56.0/22\n\n# comment\nbadline\n";
        let table = RoutingTable::from_cidrs(text);
        assert_eq!(table.direct_count(), 2);
    }

    /// Sheds routes only by DROPPING direct entries, never by widening them.
    ///
    /// This is the invariant that the old Android-side `/18` clamp violated: an
    /// address absent from the direct list must always stay inside the tunnel. If a
    /// future size optimisation widens entries instead of dropping them, the gap
    /// assertion below fails.
    #[test]
    fn route_cap_drops_entries_and_never_leaks_a_gap() {
        // ~6 000 scattered /24 holes ⇒ ~12 000 complement routes ⇒ cap must engage.
        let mut text = String::new();
        for i in 0u32..6_000 {
            let base: u32 = u32::from("1.0.0.0".parse::<Ipv4Addr>().unwrap()) + i * 512;
            text.push_str(&format!("{}/24\n", Ipv4Addr::from(base)));
        }
        let table = RoutingTable::from_cidrs(&text);
        let routes = table.compute_vpn_routes();

        assert!(
            routes.len() <= MAX_VPN_ROUTES,
            "route table must stay within the Binder budget, got {}",
            routes.len()
        );
        assert!(!routes.is_empty(), "capping must not empty the route table");

        let nets: Vec<Ipv4Net> = routes
            .iter()
            .map(|r| format!("{}/{}", r.addr, r.prefix).parse().unwrap())
            .collect();

        // Each /24 hole is followed by 256 addresses that were never declared direct.
        // Every one of them must be tunneled. Widening any hole would swallow them.
        for i in 0u32..6_000 {
            let gap = Ipv4Addr::from(
                u32::from("1.0.0.0".parse::<Ipv4Addr>().unwrap()) + i * 512 + 256,
            );
            assert!(
                nets.iter().any(|n| n.contains(&gap)),
                "{gap} was never listed as direct, so it must stay in the tunnel"
            );
        }
    }

    #[test]
    fn complement_excludes_direct() {
        let table = RoutingTable::from_cidrs("8.8.8.0/24\n");
        let routes = table.compute_vpn_routes();
        // 8.8.8.0/24 should NOT appear in VPN routes
        for r in &routes {
            let net: Ipv4Net = format!("{}/{}", r.addr, r.prefix).parse().unwrap();
            assert!(
                !net.contains(&"8.8.8.8".parse::<Ipv4Addr>().unwrap()),
                "VPN routes should not contain direct IP 8.8.8.8"
            );
        }
        // 8.8.4.4 should be in VPN routes
        let covers_8844 = routes.iter().any(|r| {
            let net: Ipv4Net = format!("{}/{}", r.addr, r.prefix).parse().unwrap();
            net.contains(&"8.8.4.4".parse::<Ipv4Addr>().unwrap())
        });
        assert!(covers_8844, "VPN routes should contain 8.8.4.4");
    }

    #[test]
    fn private_ranges_excluded() {
        let table = RoutingTable::from_cidrs("");
        let routes = table.compute_vpn_routes();
        for r in &routes {
            let net: Ipv4Net = format!("{}/{}", r.addr, r.prefix).parse().unwrap();
            assert!(
                !net.contains(&"192.168.1.1".parse::<Ipv4Addr>().unwrap()),
                "VPN routes should not contain private IPs"
            );
            assert!(
                !net.contains(&"10.0.0.1".parse::<Ipv4Addr>().unwrap()),
                "VPN routes should not contain private IPs"
            );
        }
    }

    #[test]
    fn complement_excludes_single_host_without_dropping_neighbor_ranges() {
        let table = RoutingTable::from_cidrs("89.110.109.128/32\n");
        let routes = table.compute_vpn_routes();

        let contains = |addr: &str| {
            let ip = addr.parse::<Ipv4Addr>().unwrap();
            routes.iter().any(|r| {
                let net: Ipv4Net = format!("{}/{}", r.addr, r.prefix).parse().unwrap();
                net.contains(&ip)
            })
        };

        assert!(!contains("89.110.109.128"), "direct server host must bypass VPN");
        assert!(contains("89.110.109.127"), "previous host should still use VPN");
        assert!(contains("89.110.109.129"), "next host should still use VPN");
    }

    #[test]
    fn test_routes_to_json() {
        let table = RoutingTable::from_cidrs("1.0.0.0/8\n");
        let routes = table.compute_vpn_routes();
        let json = super::routes_to_json(&routes);
        assert!(json.starts_with('['));
        assert!(json.contains("\"prefix\""));
    }
}

/// Serialize VPN routes to JSON for JNI.
pub fn routes_to_json(routes: &[VpnRoute]) -> String {
    let entries: Vec<String> = routes
        .iter()
        .map(|r| format!(r#"{{"addr":"{}","prefix":{}}}"#, r.addr, r.prefix))
        .collect();
    format!("[{}]", entries.join(","))
}
