import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var vpnManager: VpnManager
    @State private var selectedLevel: String = "INFO"
    @State private var autoScroll = true

    private let levels = ["ALL", "TRACE", "DEBUG", "INFO", "WARN", "ERROR"]

    private var filtered: [LogEntry] {
        if selectedLevel == "ALL" { return vpnManager.logs }
        let order: [String: Int] = ["TRACE": 1, "DEBUG": 2, "INFO": 3, "WARN": 4, "ERROR": 5]
        let min = order[selectedLevel] ?? 3
        return vpnManager.logs.filter { (order[$0.level] ?? 3) >= min }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    Picker("Уровень", selection: $selectedLevel) {
                        ForEach(levels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedLevel) { value in
                        vpnManager.setLogLevel(value.lowercased())
                    }

                    Toggle("Автоскролл", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .frame(maxWidth: 140)
                }

                HStack {
                    Button("Очистить") {
                        vpnManager.clearLogs()
                    }
                    .buttonStyle(.bordered)

                    Button("Копировать") {
                        let text = filtered.map { "[\($0.ts)] \($0.level) \($0.msg)" }.joined(separator: "\n")
                        UIPasteboard.general.string = text
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                    Text("\(filtered.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filtered) { entry in
                                Text("[\(entry.ts)] \(entry.level) \(entry.msg)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(logColor(entry.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.seq)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChange(of: filtered.last?.seq) { value in
                        guard autoScroll, let value else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(value, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(12)
            .navigationTitle("Логи")
            .onAppear {
                vpnManager.fetchLogs()
            }
        }
    }

    private func logColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return .redError
        case "WARN": return .yellowWarning
        case "DEBUG": return .blueDebug
        default: return .primary
        }
    }
}
