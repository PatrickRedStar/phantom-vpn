//
//  AdminPreviewData.swift
//  GhostStream
//
//  Mock data + view-model factories used only by SwiftUI #Preview blocks in
//  the Admin screens. Compiled out of Release builds.
//

#if DEBUG
import Foundation
import PhantomKit

/// Factory helpers that produce pre-populated Admin VMs without touching the
/// network. Previews use these to render realistic layouts.
enum AdminPreviewData {

    /// Sample profile — no PEMs, so AdminViewModel flags mtlsUnavailable on
    /// init; previews override the state below via the `_preview*` seams.
    static var sampleProfile: VpnProfile {
        VpnProfile(
            id: "preview-profile",
            name: "preview",
            serverAddr: "89.110.109.128:8443",
            serverName: "preview.ghoststream",
            insecure: false,
            certPem: nil,
            keyPem: nil,
            tunAddr: "10.7.0.2/24"
        )
    }

    static var sampleStatus: AdminStatus {
        // JSON round-trip keeps us honest against the real Codable shape.
        let json = """
        {"uptime_secs": 186342, "active_sessions": 3, "server_ip": "89.110.109.128"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(AdminStatus.self, from: json)
    }

    static var sampleClients: [AdminClient] {
        let now = Int64(Date().timeIntervalSince1970)
        let rows: [[String: Any]] = [
            [
                "name": "alice",
                "fingerprint": "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99",
                "tun_addr": "10.7.0.2/24",
                "enabled": true,
                "connected": true,
                "bytes_rx": 12_345_678,
                "bytes_tx": 2_345_678,
                "created_at": "2025-01-01T00:00:00Z",
                "last_seen_secs": 3,
                "expires_at": now + 23 * 86400,
                "is_admin": true,
            ],
            [
                "name": "bob",
                "fingerprint": "11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00",
                "tun_addr": "10.7.0.3/24",
                "enabled": true,
                "connected": false,
                "bytes_rx": 1024,
                "bytes_tx": 512,
                "created_at": "2025-02-01T00:00:00Z",
                "last_seen_secs": 7200,
                "expires_at": NSNull(),
                "is_admin": false,
            ],
            [
                "name": "charlie-ru",
                "fingerprint": "ff:ee:dd:cc:bb:aa:99:88:77:66:55:44:33:22:11:00",
                "tun_addr": "10.7.0.4/24",
                "enabled": false,
                "connected": false,
                "bytes_rx": 0,
                "bytes_tx": 0,
                "created_at": "2025-03-15T00:00:00Z",
                "last_seen_secs": 999_999,
                "expires_at": now - 3600,
                "is_admin": false,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return try! JSONDecoder().decode([AdminClient].self, from: data)
    }

    static var sampleStats: [ClientStat] {
        let base = Int64(Date().timeIntervalSince1970) - 3600
        return (0..<60).map { i in
            let rx = Int64(1_000_000 + i * 50_000 + Int.random(in: 0...20_000))
            let tx = Int64(200_000  + i * 10_000 + Int.random(in: 0...5_000))
            let json = """
            {"ts": \(base + Int64(i * 60)), "bytes_rx": \(rx), "bytes_tx": \(tx)}
            """.data(using: .utf8)!
            return try! JSONDecoder().decode(ClientStat.self, from: json)
        }
    }

    static var sampleLogs: [ClientLog] {
        let base = Int64(Date().timeIntervalSince1970)
        let hosts: [(String, Int, String, Int64)] = [
            ("cdn.cloudflare.com", 443, "tcp", 45_000),
            ("api.telegram.org",   443, "tcp", 12_500),
            ("8.8.8.8",             53, "udp", 120),
            ("youtube.com",        443, "tcp", 1_234_567),
        ]
        return hosts.enumerated().map { (i, h) in
            let json = """
            {"ts": \(base - Int64(i * 30)), "dst": "\(h.0)", "port": \(h.1), "proto": "\(h.2)", "bytes": \(h.3)}
            """.data(using: .utf8)!
            return try! JSONDecoder().decode(ClientLog.self, from: json)
        }
    }

    @MainActor
    static func populatedVM() -> AdminViewModel {
        let vm = AdminViewModel(profile: sampleProfile)
        vm._previewApply(status: sampleStatus, clients: sampleClients, error: nil, mtls: false)
        return vm
    }

    @MainActor
    static func mtlsBlockedVM() -> AdminViewModel {
        let vm = AdminViewModel(profile: sampleProfile)
        vm._previewApply(
            status: nil,
            clients: [],
            error: "Ed25519 client certs are not supported on iOS — regenerate as ECDSA P-256",
            mtls: true
        )
        return vm
    }

    @MainActor
    static func detailVM() -> ClientDetailViewModel {
        let admin = populatedVM()
        let vm = ClientDetailViewModel(client: sampleClients[0], adminVM: admin)
        vm._previewApply(stats: sampleStats, logs: sampleLogs)
        return vm
    }
}
#endif
