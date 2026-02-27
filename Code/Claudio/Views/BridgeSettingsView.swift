import SwiftUI

struct BridgeSettingsView: View {
    @Bindable var bridge: BridgeCoordinator
    @State private var tokenInput = ""
    @State private var showToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telegram Bridge")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Toggle("Enable", isOn: Binding(
                get: { bridge.isEnabled },
                set: { val in Task { await bridge.setEnabled(val) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if bridge.isEnabled {
                tokenRow
                statusRow

                HStack {
                    Label(
                        bridge.hooksInstalled ? "Hooks installed" : "Hooks not installed",
                        systemImage: bridge.hooksInstalled ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(bridge.hooksInstalled ? Color.secondary : Color.orange)

                    if !bridge.hooksInstalled {
                        Button("Install") { bridge.installHooks() }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                    }
                }

                if let error = bridge.lastBridgeError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            bridge.hooksInstalled = bridge.checkHooksInstalled()
        }
    }

    private var tokenRow: some View {
        HStack {
            if showToken {
                TextField("Bot token", text: $tokenInput)
                    .textFieldStyle(.plain)
                    .font(.caption2)
                    .onSubmit {
                        bridge.saveBotToken(tokenInput)
                        showToken = false
                    }
            } else {
                Text(bridge.botToken.isEmpty ? "No token" : "Token: ****\(String(bridge.botToken.suffix(6)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(showToken ? "Save" : "Edit") {
                if showToken {
                    bridge.saveBotToken(tokenInput)
                } else {
                    tokenInput = bridge.botToken
                }
                showToken.toggle()
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(bridge.isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(bridge.isConnected ? "Connected" : "Disconnected")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if bridge.chatId > 0 {
                Text("Chat: \(bridge.chatId)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
