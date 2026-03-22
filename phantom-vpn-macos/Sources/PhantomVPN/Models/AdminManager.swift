import Foundation
import Combine

struct AdminClientInfo: Identifiable {
    var id: String { name }
    let name: String
    let tunAddr: String
    let fingerprint: String
    let enabled: Bool
    let connected: Bool
    let bytesRx: Int64
    let bytesTx: Int64
    let createdAt: String
    let lastSeenSecs: Int64
    let expiresAt: Int64?

    var subLabel: String? {
        guard let exp = expiresAt else { return nil }
        let daysLeft = (exp - Int64(Date().timeIntervalSince1970)) / 86400
        if daysLeft < 0 { return "Истекла" }
        if daysLeft == 0 { return "< 1 дня" }
        return "\(daysLeft) дн."
    }

    var subColor: Color {
        guard let exp = expiresAt else { return .secondary }
        let daysLeft = (exp - Int64(Date().timeIntervalSince1970)) / 86400
        if daysLeft < 0  { return .red }
        if daysLeft < 3  { return .red }
        if daysLeft < 7  { return .orange }
        return .green
    }
}

struct AdminStatus {
    let uptimeSecs: Int64
    let sessionsActive: Int
    let serverAddr: String
    let exitIp: String?
}

class AdminManager: ObservableObject {
    static let shared = AdminManager()

    @Published var status: AdminStatus?
    @Published var clients: [AdminClientInfo] = []
    @Published var loading = false
    @Published var error: String?
    @Published var newConnString: String?

    private var baseUrl = ""
    private var token = ""

    private init() {}

    func configure(adminUrl: String, adminToken: String) {
        baseUrl = adminUrl.hasSuffix("/") ? String(adminUrl.dropLast()) : adminUrl
        token = adminToken
    }

    var isConfigured: Bool { !baseUrl.isEmpty && !token.isEmpty }

    func refresh() {
        guard isConfigured else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                async let s = fetchStatus()
                async let c = fetchClients()
                status = try await s
                clients = try await c
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func createClient(name: String, expiresDays: Int?) {
        Task { @MainActor in
            do {
                var body: [String: Any] = ["name": name]
                if let d = expiresDays { body["expires_days"] = d }
                let result = try await post("/api/clients", body: body)
                newConnString = result["conn_string"] as? String
                refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func deleteClient(name: String) {
        Task { @MainActor in
            do {
                try await delete("/api/clients/\(name)")
                refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setEnabled(name: String, enabled: Bool) {
        Task { @MainActor in
            do {
                let ep = enabled ? "/api/clients/\(name)/enable" : "/api/clients/\(name)/disable"
                _ = try await post(ep, body: [:])
                refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func manageSubscription(name: String, action: String, days: Int?) {
        Task { @MainActor in
            do {
                var body: [String: Any] = ["action": action]
                if let d = days { body["days"] = d }
                _ = try await post("/api/clients/\(name)/subscription", body: body)
                refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func getConnString(name: String) {
        Task { @MainActor in
            do {
                let result = try await get("/api/clients/\(name)/conn_string")
                newConnString = result["conn_string"] as? String
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func clearNewConnString() { newConnString = nil }

    // MARK: - HTTP helpers

    private func fetchStatus() async throws -> AdminStatus {
        let obj = try await get("/api/status")
        return AdminStatus(
            uptimeSecs: (obj["uptime_secs"] as? NSNumber)?.int64Value ?? 0,
            sessionsActive: (obj["sessions_active"] as? Int) ?? 0,
            serverAddr: obj["server_addr"] as? String ?? "",
            exitIp: obj["exit_ip"] as? String
        )
    }

    private func fetchClients() async throws -> [AdminClientInfo] {
        let arr = try await getArray("/api/clients")
        return (arr as? [[String: Any]] ?? []).map { o in
            AdminClientInfo(
                name: o["name"] as? String ?? "",
                tunAddr: o["tun_addr"] as? String ?? "",
                fingerprint: o["fingerprint"] as? String ?? "",
                enabled: o["enabled"] as? Bool ?? true,
                connected: o["connected"] as? Bool ?? false,
                bytesRx: (o["bytes_rx"] as? NSNumber)?.int64Value ?? 0,
                bytesTx: (o["bytes_tx"] as? NSNumber)?.int64Value ?? 0,
                createdAt: o["created_at"] as? String ?? "",
                lastSeenSecs: (o["last_seen_secs"] as? NSNumber)?.int64Value ?? 0,
                expiresAt: (o["expires_at"] as? NSNumber).flatMap { n in let v = n.int64Value; return v > 0 ? v : nil }
            )
        }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        let data = try await request("GET", path: path)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func getArray(_ path: String) async throws -> Any {
        let data = try await request("GET", path: path)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await request("POST", path: path, body: bodyData)
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func delete(_ path: String) async throws {
        _ = try await request("DELETE", path: path)
    }

    private func request(_ method: String, path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: baseUrl + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code < 200 || code >= 300 {
            throw NSError(domain: "AdminAPI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        return data
    }
}

// Make Color available in Models
import SwiftUI
extension Color {
    static var secondary: Color { .init(.secondaryLabelColor) }
}
