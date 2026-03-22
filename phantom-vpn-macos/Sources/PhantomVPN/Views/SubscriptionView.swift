import SwiftUI

struct SubscriptionView: View {
    let client: AdminClientInfo
    @Binding var isPresented: Bool
    @EnvironmentObject var adminManager: AdminManager
    @State private var customDays = ""

    private var nowSecs: Int64 { Int64(Date().timeIntervalSince1970) }

    private var statusText: String {
        guard let exp = client.expiresAt else { return "Бессрочная" }
        let d = (exp - nowSecs) / 86400
        if d < 0  { return "Истекла" }
        if d == 0 { return "Истекает сегодня" }
        return "Активна ещё \(d) дн."
    }

    private var statusColor: Color {
        guard let exp = client.expiresAt else { return .accentColor }
        let d = (exp - nowSecs) / 86400
        if d < 0  { return .red }
        if d < 7  { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Подписка: \(client.name)")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { isPresented = false }
                    .buttonStyle(.plain)
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Status
                Label(statusText, systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(statusColor)

                Divider()

                // Quick extend
                Text("Продлить:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([(30, "+30 дн."), (90, "+90 дн."), (365, "+1 год")], id: \.0) { days, label in
                        Button(label) {
                            adminManager.manageSubscription(name: client.name, action: "extend", days: days)
                            isPresented = false
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }

                // Custom
                HStack(spacing: 8) {
                    TextField("Дней", text: $customDays)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Button("Установить") {
                        if let d = Int(customDays) {
                            adminManager.manageSubscription(name: client.name, action: "set", days: d)
                            isPresented = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(Int(customDays) == nil)
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Бессрочно") {
                        adminManager.manageSubscription(name: client.name, action: "cancel", days: nil)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Аннулировать") {
                        adminManager.manageSubscription(name: client.name, action: "revoke", days: nil)
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding()
        }
        .frame(width: 380, height: 320)
    }
}
