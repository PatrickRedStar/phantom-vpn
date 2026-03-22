import Foundation
import Combine
import AppKit

enum VpnState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }

    var label: String {
        switch self {
        case .disconnected: return "Не подключено"
        case .connecting:   return "Подключение…"
        case .connected:    return "Подключено"
        case .error(let m): return "Ошибка: \(m)"
        }
    }

    var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting: return .systemOrange
        case .error: return .systemRed
        case .disconnected: return .secondaryLabelColor
        }
    }
}

class VpnManager: ObservableObject {
    static let shared = VpnManager()

    @Published var state: VpnState = .disconnected
    @Published var connectedSince: Date?
    @Published var logLines: [String] = []

    private var monitorTimer: Timer?
    private let logURL = URL(fileURLWithPath: "/tmp/phantom-vpn.log")
    private let pidURL = URL(fileURLWithPath: "/tmp/phantom-vpn.pid")
    private let csURL  = URL(fileURLWithPath: "/tmp/phantom-vpn-cs.tmp")
    private var logReadOffset: UInt64 = 0

    private init() {}

    func connect(profile: VpnProfile) {
        guard state == .disconnected || state != .connecting else { return }
        state = .connecting
        logLines = []
        logReadOffset = 0
        try? "".write(to: logURL, atomically: true, encoding: .utf8)

        guard let binaryPath = findBinary() else {
            state = .error("phantom-client-macos не найден.\nУстановите: sudo install -m 0755 phantom-client-macos /usr/local/bin/")
            return
        }

        // Write connection string to temp file (avoids shell quoting issues)
        do {
            try profile.connString.write(to: csURL, atomically: true, encoding: .utf8)
        } catch {
            state = .error("Не удалось записать конфигурацию: \(error.localizedDescription)")
            return
        }

        let logPath = logURL.path
        let pidPath = pidURL.path
        let csPath  = csURL.path
        let cmd = "nohup \(binaryPath) --conn-string-file \(csPath) -vv > \(logPath) 2>&1 & echo $! > \(pidPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(&error)

            DispatchQueue.main.async {
                if let err = error {
                    let msg = err["NSAppleScriptErrorMessage"] as? String ?? "Отмена или ошибка"
                    self?.state = .error(msg)
                }
            }
        }

        startMonitoring()
    }

    func disconnect() {
        stopMonitoring()

        let pidPath = pidURL.path
        let script = """
            do shell script "if [ -f \(pidPath) ]; then kill $(cat \(pidPath)) 2>/dev/null; rm \(pidPath); fi; pkill -f 'phantom-client-macos' 2>/dev/null || true" with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.state = .disconnected
            self?.connectedSince = nil
        }
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkStatus()
            self?.readNewLogs()
        }
    }

    private func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func checkStatus() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "phantom-client-macos"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let running = !output.isEmpty

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .connecting where running:
                let connected = self.logLines.contains(where: {
                    $0.contains("utun") || $0.contains("TUN") || $0.contains("QUIC connect") || $0.contains("Tunnel ready")
                })
                if connected {
                    self.state = .connected
                    self.connectedSince = Date()
                }
            case .connecting where !running && self.logLines.count > 5:
                self.state = .error("Не удалось подключиться. Смотрите логи.")
                self.stopMonitoring()
            case .connected where !running:
                self.state = .error("Соединение прервано")
                self.connectedSince = nil
                self.stopMonitoring()
            default:
                break
            }
        }
    }

    private func readNewLogs() {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: logReadOffset)
        let data = fh.readDataToEndOfFile()
        logReadOffset += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        DispatchQueue.main.async { [weak self] in
            self?.logLines.append(contentsOf: lines)
            if (self?.logLines.count ?? 0) > 300 {
                self?.logLines = Array(self!.logLines.suffix(300))
            }
        }
    }

    private func findBinary() -> String? {
        [
            "/usr/local/bin/phantom-client-macos",
            "/opt/homebrew/bin/phantom-client-macos",
            Bundle.main.bundlePath + "/Contents/MacOS/phantom-client-macos",
        ].first { FileManager.default.fileExists(atPath: $0) }
    }
}
