---
name: User goals and constraints
description: User's requirements for PhantomVPN project — speed, stealth, infrastructure constraints, willingness to change approach
type: user
---

- Building PhantomVPN — custom VPN/proxy for bypassing Russian DPI (TSPU)
- Key requirements: high speed (target gigabit) + invisible to DPI
- Infrastructure: multiple VPS (vdsina=89.110.109.128 as server, vps_balancer=158.160.135.140 as client, vps_nl). Can scale hardware — not a constraint.
- Cloudflare/CDN NOT an option — Russia is actively blocking CF, trend toward full block
- Currently uses VLESS+xray as production (works at ~293 Mbps), PhantomVPN is experimental
- Interested in H.264 traffic shaping as differentiator (mask traffic as video call)
- Open to radical changes: new language, new approach, new protocols
- Domain: nl2.bikini-bottom.com (Let's Encrypt cert), balancer.bikini-bottom.com
- Local dev machine: CachyOS (no cargo), builds via SSH to vdsina
- SSH ports: vps_balancer=9083, vdsina=22
