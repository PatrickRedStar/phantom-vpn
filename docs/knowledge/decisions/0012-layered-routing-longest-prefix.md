---
updated: 2026-07-02
status: accepted
supersedes: часть 0006 (механизм вычитания маршрутов)
---

# 0012 — layeredAuto через longest-prefix, без вычитания маршрутов upstream

## Context

ADR 0006 реализовал layeredAuto вычитанием маршрутов Cisco из `includedRoutes`
GhostStream. Июльская практика на живом корп-маке показала, что вычитание
нерабочее в обоих вариантах:

- **Точное вычитание** (до 2026-07): Cisco dynamic split-include = сотни
  DNS-driven /32, меняющихся на лету → комплемент 4713 `includedRoutes`
  (NE давится) + `routeHash` дребезжит на каждый новый хост →
  `setTunnelNetworkSettings`-флапы → instant-disconnect.
- **Агрегированное вычитание** (/24→/20→/16, Batch B 2026-07): супернеты
  вокруг корп-/32 (живущих на Cloudflare/AWS/Google) вырезали из GhostStream
  огромные публичные диапазоны. Live-факт: `route get 104.17.148.22`
  (speedtest, Cloudflare) → **en0** — трафик уходил голым мимо ОБОИХ VPN,
  в РФ его резал ТСПУ. «Что-то грузится, что-то нет» + privacy-утечка.

Корень: любое вычитание создаёт «дыры в никуда» — вычтенный диапазон уходит
не в Cisco, а в обычный системный роутинг (физический интерфейс).

## Decision

В layeredAuto **ничего не вычитать**. `includedRoutes` GhostStream =
комплемент только от manual CIDR + приватных диапазонов (как publicSplit),
~30–40 крупных блоков. Иерархию «корп → Cisco» обеспечивает longest-prefix
matching системной таблицы: любой маршрут Cisco (/26…/32, включая
динамические /32) специфичнее комплемент-блоков GhostStream (/1…/8) и
выигрывает автоматически, без пересборки настроек.

- `detectedUpstreamCidrs` остаются в `RoutePolicySnapshot` только для
  UI-счётчика и диагностики; **исключены из `routeHash`** → дребезг
  динамического сплита больше не триггерит re-apply.
- Серверный exclude (`physicalServerExcludedRoutes`) ставится **всегда** —
  прежний containment-check по detected был парным к вычитанию и на
  протухшей копии мог отправить транспорт GhostStream в туннель Cisco
  (туннель-в-туннеле) или в петлю.
- Guard: если у upstream замечен default или маршрут ≤ /7 (full-tunnel,
  split-include «0.0.0.0/0») — флаг `upstreamHasBroadRoutes`, UI
  предупреждает: публичный трафик уйдёт в GhostStream, корп-ресурсы без
  узких маршрутов лишатся корп-туннеля.

## Почему отклонённый в 0006 longest-prefix теперь принят

0006 отвергал «full tunnel с надеждой на longest-prefix», потому что
«работает только пока Cisco-маршруты стоят и не меняются». Практика
показала обратное: churn ломает именно вычитание (окно протухания —
5с-полл + гистерезис на КАЖДОЕ изменение), а LPM реагирует на новый
Cisco-/32 мгновенно и без нашего участия — окном владеет сам Cisco
(мс, как и без GhostStream). При этом «управляемая» альтернатива
оказалась хуже неуправляемой: агрегация отправляла чужие /16 CDN на
en0/ТСПУ.

## Consequences

- Обрыв одной TCP-сессии в момент появления нового dynamic /32 —
  inherent для LPM, идентично поведению самого AnyConnect.
- DNS-запросы, ушедшие внутрь GhostStream (1.1.1.1), невидимы для
  socket-filter Cisco → dynamic split для таких доменов не сработает,
  корп-SaaS уйдёт через GhostStream; SaaS с conditional-access по
  egress-IP может флаковать в зависимости от того, чей резолвер выиграл.
  Не регрессия (при вычитании ломалось всегда), фиксится manual CIDR.
- `upstreamDnsServers/Domains` остаются в hash — потенциальный источник
  остаточного дребезга; наблюдать, при подтверждении выносить из hash
  отдельным решением.

## References

- `RoutePolicySnapshot` (hash-контракт, `RouteHashContractTests`)
- `UpstreamVpnRouteDetector.routes(on:)` (флаг broad routes)
- `PacketTunnelProvider.directCidrsForRouteComputation` (macOS + iOS)
- incidents/2026-07-01-macos-logs-freeze-cisco-disconnect.md
