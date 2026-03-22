import SwiftUI

struct LogsTab: View {
    @EnvironmentObject var vpnManager: VpnManager
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(vpnManager.logLines.count) строк")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Авто-прокрутка", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button { vpnManager.logLines = [] } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Очистить логи")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vpnManager.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: vpnManager.logLines.count) { _, _ in
                    if autoScroll, let last = vpnManager.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 260)
    }

    private func lineColor(_ line: String) -> Color {
        if line.uppercased().contains("ERROR") { return .red }
        if line.uppercased().contains("WARN")  { return .orange }
        if line.contains("INFO")  { return .primary }
        return .secondary
    }
}
