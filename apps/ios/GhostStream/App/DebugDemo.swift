//
//  DebugDemo.swift
//  GhostStream
//
//  Screenshot hook (DEBUG only): `-gsDemo idle|connected|reconnecting|degraded|error`
//  seeds demo profiles and a journal; the live modes play a fake tunnel
//  through VpnStateManager and the snapshot.json the extension writes, so
//  the dashboard, Live Activity and widget render without a real VPN.
//  Needs the App Group: sign the simulator build with its entitlements.
//

#if DEBUG
import Foundation
import NetworkExtension
import PhantomKit
import PhantomUI
import SwiftUI

@MainActor
enum DebugDemo {

    /// `-gsAdminDemo YES|detail|qr` for the Settings tab: the admin console,
    /// a client detail, or the QR card the detail shows once the server
    /// returns the link (preview VMs have no network, so it never does).
    static var adminScreen: AnyView? {
        switch UserDefaults.standard.string(forKey: "gsAdminDemo") {
        case "YES", "1", "list":
            return AnyView(AdminView(viewModel: AdminPreviewData.populatedVM()))
        case "detail":
            return AnyView(ClientDetailView(viewModel: AdminPreviewData.detailVM()))
        case "qr":
            let link = "ghs://eyJ2IjoxLCJzIjoiODkuMTEwLjEwOS4xMjg6ODQ0MyIsIm4iOiJ0bHMubmwyLmJpa2luaS1ib3R0b20uY29tIiwiYyI6Ii0tLS0tQkVHSU4gQ0VSVElGSUNBVEUtLS0tLSJ9"
            return AnyView(QRDemo(link: link))
        default:
            return nil
        }
    }

    private struct QRDemo: View {
        let link: String
        @Environment(\.gsColors) private var C
        var body: some View {
            ScrollView {
                ConnStringShareCard(connString: link)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("alice")
        }
    }

    /// What `VpnTunnelController.currentStatus()` reports in a live demo —
    /// there is no NE configuration in the simulator, and the dashboard's
    /// reconcile would otherwise force "idle".
    nonisolated static var neStatus: NEVPNStatus? {
        switch UserDefaults.standard.string(forKey: "gsDemo") {
        case "connected", "degraded": return .connected
        case "reconnecting": return .reasserting
        default: return nil
        }
    }

    static func startIfRequested() {
        guard let mode = UserDefaults.standard.string(forKey: "gsDemo"),
              let defaults = UserDefaults(suiteName: SharedKeys.appGroup),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)
        else { return }
        seedProfiles()
        seedLogs()
        let snapshotURL = container.appendingPathComponent("snapshot.json")
        try? FileManager.default.removeItem(at: snapshotURL)
        defaults.removeObject(forKey: SharedKeys.tunnelMemoryMiB)
        // 12:34:56 into the session — two-digit hours, the widest common case.
        let start = Date().addingTimeInterval(-45_296)
        let sni = "tls.nl2.bikini-bottom.com"
        switch mode {
        case "connected", "degraded":
            VpnStateManager.shared.update(.connected(since: start, serverName: sni))
        case "reconnecting":
            VpnStateManager.shared.update(.reconnecting(since: start, serverName: sni))
        case "error":
            VpnStateManager.shared.update(.error(
                "Сервер отклонил сертификат: доступ отозван администратором. Попросите новую ссылку подключения."
            ))
        default:
            VpnStateManager.shared.update(.disconnected)
        }
        guard neStatus != nil else { return }
        defaults.set(23.4, forKey: SharedKeys.tunnelMemoryMiB)
        // The extension rewrites snapshot.json every second; so do we.
        Task { @MainActor in
            var tick = 0
            while true {
                if let data = try? JSONEncoder().encode(frame(mode: mode, start: start, sni: sni, tick: tick)) {
                    try? data.write(to: snapshotURL, options: .atomic)
                }
                DarwinNotifications.post(DarwinNotifications.stateChanged)
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func frame(mode: String, start: Date, sni: String, tick: Int) -> StatusFrame {
        let reconnecting = mode == "reconnecting"
        let degraded = mode == "degraded"
        let wave = (sin(Double(tick) / 3) + 1) / 2
        let up: UInt8 = reconnecting ? 0 : (degraded ? 5 : 8)
        return StatusFrame(
            state: reconnecting ? .reconnecting : .connected,
            sessionSecs: UInt64(Date().timeIntervalSince(start)),
            bytesRx: 18_400_000_000, bytesTx: 1_200_000_000,
            rateRxBps: reconnecting ? 0 : 30_000_000 + 20_000_000 * wave,   // bits/s
            rateTxBps: reconnecting ? 0 : 2_000_000 + 3_000_000 * (1 - wave),
            nStreams: 8, streamsUp: up,
            streamActivity: (0..<16).map { i in
                i < Int(up) ? Float((sin(Double(tick + i * 2) / 2) + 1) / 2) : 0
            },
            rttMs: 48, tunAddr: "10.7.0.2/24", serverAddr: "158.160.135.140:443",
            sni: sni, lastError: nil,
            reconnectAttempt: reconnecting ? 3 : nil,
            reconnectNextDelaySecs: reconnecting ? 8 : nil,
            health: degraded ? .degraded : .healthy
        )
    }

    private static func seedProfiles() {
        let store = ProfilesStore.shared
        guard !store.profiles.contains(where: { $0.id == "demo-nl" }) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        store.add(VpnProfile(
            id: "demo-nl",
            name: "Нидерланды — основной сервер",
            serverAddr: "89.110.109.128:8443",
            serverName: "tls.nl2.bikini-bottom.com",
            tunAddr: "10.7.0.2/24",
            cachedExpiresAt: now + 167 * 86_400 + 5 * 3_600,
            cachedEnabled: true,
            cachedIsAdmin: true,
            relayEnabled: true,
            relayAddr: "158.160.135.140:443"
        ))
        store.add(VpnProfile(
            id: "demo-home",
            name: "Дом",
            serverAddr: "89.110.109.128:8443",
            serverName: "tls.nl2.bikini-bottom.com",
            tunAddr: "10.7.0.3/24",
            cachedExpiresAt: now + 9 * 86_400,
            cachedEnabled: true
        ))
        store.add(VpnProfile(
            id: "demo-off",
            name: "Резерв (отключён)",
            serverAddr: "89.169.175.55:443",
            serverName: "relay.bikini-bottom.com",
            tunAddr: "10.7.0.4/24",
            cachedEnabled: false
        ))
        store.setActive(id: "demo-nl")
    }

    private static func seedLogs() {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)?
            .appendingPathComponent("logs.jsonl"),
              !FileManager.default.fileExists(atPath: url.path)
        else { return }
        let lines: [(String, String)] = [
            ("INF", "tunnel starting: profile=Нидерланды — основной сервер relay=158.160.135.140:443"),
            ("DBG", "tls: handshake ok sni=tls.nl2.bikini-bottom.com alpn=h2 cipher=TLS_AES_128_GCM_SHA256"),
            ("INF", "h2: 8/8 streams up, rtt=48ms"),
            ("WRN", "stream 5: no rx for 12s, probing (health=stale)"),
            ("ERR", "stream 5: connection reset by peer (os error 54); reconnect attempt 1 in 2s"),
            ("INF", "stream 5: reconnected after 2.1s"),
            ("TRC", "rx batch=64 frames bytes=91234 queue_depth=3"),
            ("INF", "on-demand: network changed wifi → cellular, keeping session"),
            ("WRN", "Очень длинная строка журнала без пробелов: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            ("INF", "dns: 1.1.1.1 · 8.8.8.8 via tunnel"),
        ]
        let base = UInt64(Date().timeIntervalSince1970 * 1000) - 600_000
        let encoder = JSONEncoder()
        let text = lines.enumerated().compactMap { i, line -> String? in
            let frame = LogFrame(tsUnixMs: base + UInt64(i) * 47_000, level: line.0, msg: line.1)
            return (try? encoder.encode(frame)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
