import Foundation
import Combine
import NetworkExtension

enum VpnState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date, serverName: String)
    case error(message: String)
    case disconnecting
}

struct LogEntry: Identifiable, Codable {
    var id: Int64 { seq }
    let seq: Int64
    let ts: String
    let level: String
    let msg: String
}

final class VpnManager: ObservableObject {
    static let shared = VpnManager()

    @Published var state: VpnState = .disconnected
    @Published var stats: VpnStats = .init(bytes_rx: 0, bytes_tx: 0, pkts_rx: 0, pkts_tx: 0, connected: false)
    @Published var timerText: String = "00:00:00"
    @Published var preflightWarning: String?
    @Published var logs: [LogEntry] = []

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var timer: Timer?
    private var statsTimer: Timer?
    private var since = Date()
    private var lastSeq: Int64 = -1

    private init() {}

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        timer?.invalidate()
        statsTimer?.invalidate()
    }

    func bootstrapManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                if let error {
                    self?.state = .error(message: "Не удалось загрузить VPN-профиль: \(error.localizedDescription)")
                    return
                }
                self?.manager = managers?.first
                self?.ensureManagerExists()
                self?.observeStatus()
            }
        }
    }

    func connect(config: VpnConfig) {
        guard !config.serverAddr.isEmpty else {
            state = .error(message: "Пустой адрес сервера")
            return
        }
        preflightWarning = nil
        state = .connecting
        ensureManagerExists()
        guard let manager else {
            state = .error(message: "VPN manager не инициализирован")
            return
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.ghoststream.vpn.ios.PacketTunnel"
        proto.serverAddress = config.serverAddr
        proto.providerConfiguration = [
            "serverAddr": config.serverAddr,
            "serverName": config.serverName,
            "insecure": config.insecure,
            "certPath": config.certPath,
            "keyPath": config.keyPath,
            "caCertPath": config.caCertPath,
            "tunAddr": config.tunAddr,
            "dnsServers": config.dnsServers,
            "splitRouting": config.splitRouting,
            "directCountries": config.directCountries
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "GhostStream VPN"
        manager.isEnabled = true

        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.state = .error(message: "Ошибка сохранения VPN профиля: \(error.localizedDescription)")
                    return
                }
                manager.loadFromPreferences { loadError in
                    DispatchQueue.main.async {
                        if let loadError {
                            self?.state = .error(message: "Ошибка загрузки VPN профиля: \(loadError.localizedDescription)")
                            return
                        }
                        do {
                            try manager.connection.startVPNTunnel()
                            self?.since = Date()
                            self?.startTimers()
                        } catch {
                            self?.state = .error(message: "Не удалось запустить VPN: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    func disconnect() {
        guard let manager else { return }
        state = .disconnecting
        manager.connection.stopVPNTunnel()
        stopTimers()
    }

    func dismissPreflightWarning() {
        preflightWarning = nil
    }

    func fetchStats() {
        sendMessage(["op": "getStats"]) { [weak self] response in
            guard let response,
                  let stats = try? JSONDecoder().decode(VpnStats.self, from: response) else { return }
            DispatchQueue.main.async {
                self?.stats = stats
            }
        }
    }

    func fetchLogs() {
        sendMessage(["op": "getLogs", "sinceSeq": lastSeq]) { [weak self] response in
            guard let self,
                  let response,
                  let entries = try? JSONDecoder().decode([LogEntry].self, from: response) else { return }
            DispatchQueue.main.async {
                if let maxSeq = entries.map(\.seq).max() {
                    self.lastSeq = maxSeq
                }
                self.logs.append(contentsOf: entries)
                if self.logs.count > 50_000 {
                    self.logs = Array(self.logs.suffix(50_000))
                }
            }
        }
    }

    func setLogLevel(_ level: String) {
        sendMessage(["op": "setLogLevel", "level": level], completion: { _ in })
    }

    func clearLogs() {
        logs.removeAll()
        lastSeq = -1
    }

    private func ensureManagerExists() {
        if manager != nil { return }
        let newManager = NETunnelProviderManager()
        manager = newManager
    }

    private func observeStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncStatus()
        }
        syncStatus()
    }

    private func syncStatus() {
        guard let status = manager?.connection.status else { return }
        switch status {
        case .invalid, .disconnected:
            state = .disconnected
            stopTimers()
        case .connecting, .reasserting:
            state = .connecting
        case .connected:
            if case .connected = state {
            } else {
                since = Date()
                state = .connected(since: since, serverName: ProfileStore.shared.activeProfile?.serverName ?? "")
            }
            startTimers()
        case .disconnecting:
            state = .disconnecting
        @unknown default:
            state = .error(message: "Неизвестный статус VPN")
        }
    }

    private func startTimers() {
        timer?.invalidate()
        statsTimer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let sec = Int(Date().timeIntervalSince(self.since))
            self.timerText = FormatUtils.formatDuration(seconds: sec)
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.fetchStats()
            self?.fetchLogs()
        }
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        timerText = "00:00:00"
    }

    private func sendMessage(_ payload: [String: Any], completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(data) { response in
                completion(response)
            }
        } catch {
            completion(nil)
        }
    }
}
