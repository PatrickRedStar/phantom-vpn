---
name: splice(2) serial pipeline — плохой выбор для bidirectional TLS-relay
description: hand-rolled splice через одну pipe зажимает скорость до 5 Mbit/s, copy_bidirectional с BBR даёт сотни Mbit
type: feedback
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
Для TCP-to-TCP relay (phantom-relay) НЕ использовать hand-rolled splice(2) через анонимную pipe. Использовать `tokio::io::copy_bidirectional`.

**Why:** 2026-04-11 реализовал в phantom-relay splice loop вида `src.readable().await → splice(src, pipe_w) → dst.writable().await → splice(pipe_r, dst)` в одной корутине. Под реальной TLS-нагрузкой (mTLS + 4 параллельных TCP-стрима от клиента) этот serial pipeline прокачивал ~5 Mbit/s при физическом линке 1.5 Gbit/s (замерено iperf3 между теми же хостами). Причина — pipeline: пока идёт fill pipe, drain не продвигается, и наоборот. Даже с 1 MiB pipe capacity и non-blocking splice это оказалось на порядки медленнее штатного `tokio::io::copy_bidirectional`, который запускает оба direction concurrent внутри одной task. Замена на copy_bidirectional подняла скорость до 138/71 Mbit/s (направление client↔NL через RU-hop). Дополнительно был footgun с `AsyncFd::with_interest` — повторная регистрация fd, уже зарегистрированного tokio TcpStream, падает с EEXIST (os error 17).

**How to apply:** Для любого TCP-to-TCP forwarding в async Rust сразу `tokio::io::copy_bidirectional(&mut a, &mut b)`. Если понадобится splice — делать через TWO concurrent futures (fill и drain в разных tasks), и читать readiness только через `TcpStream::async_io(Interest, closure)`, не через `AsyncFd::with_interest` на raw fd.
