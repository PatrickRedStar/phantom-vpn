---
updated: 2026-04-30
status: accepted
---

# 0006 — Layered macOS routing для корпоративного VPN + GhostStream

## Context

На macOS Cisco Secure Client/AnyConnect может работать как split-tunnel через
свой `utun*` и scoped DNS, не занимая тот же пользовательский VPN slot, что
`NETunnelProviderManager` GhostStream. Пользователю нужен порядок:
корпоративные Cisco CIDR/домены идут через Cisco, остальной публичный интернет
через GhostStream, а GhostStream direct exclusions идут напрямую.

Ключевое ограничение NetworkExtension: `excludedRoutes` у Packet Tunnel ведут
трафик на primary physical interface. Если положить туда корпоративные Cisco
CIDR, GhostStream может обойти Cisco, что нарушает требуемую иерархию.

## Decision

На macOS вводим `layeredAuto`: GhostStream вычитает маршруты активного upstream
VPN из своих `includedRoutes`, сохраняет Cisco/scoped DNS и не использует
`excludedRoutes` для корпоративных сетей.

## Alternatives considered

- Full tunnel через GhostStream с надеждой на longest-prefix Cisco routes.
  Работает только пока Cisco маршруты уже стоят и не меняются; DNS и route churn
  остаются неявными.
- Класть Cisco CIDR в `excludedRoutes`. Отклонено: macOS может отправить их
  напрямую через physical interface, обходя корпоративный VPN.
- Ручной список рабочих CIDR. Оставлен как override, но не как основной режим,
  потому что Cisco profiles могут менять routes/DNS без участия GhostStream.

## Consequences

- Host app должен читать route table/DNS read-only и пересылать
  `RoutePolicySnapshot` в system extension.
- Packet Tunnel должен уметь безопасно пересобрать `NEPacketTunnelNetworkSettings`
  во время активной сессии.
- DNS leak protection в `layeredAuto` становится совместимым режимом: Cisco
  scoped DNS сохраняется, а GhostStream DNS не должен ломать корпоративные
  domains.

## References

- `UpstreamVpnRouteDetector`
- `RoutePolicySnapshot`
- `PacketTunnelProvider.configureIPv4Routes`
