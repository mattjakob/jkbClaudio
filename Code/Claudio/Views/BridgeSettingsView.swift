import SwiftUI

struct BridgeSettingsView: View {
    @Bindable var bridge: BridgeCoordinator
    var onBack: () -> Void
    @State private var tokenInput = ""
    @State private var isEditingToken = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                header
                    .padding(.bottom, 20)

                enableRow
                    .padding(.bottom, 12)

                if bridge.isEnabled {
                    if !bridge.botToken.isEmpty && bridge.isConnected && bridge.hooksInstalled && bridge.accessibilityGranted {
                        // Fully configured — compact view
                        statusCard
                            .padding(.bottom, 12)
                        notificationsCard
                            .padding(.bottom, 12)
                        helpCard(
                            "Commands: /status, /1 msg, /2 msg. Session output and events are forwarded automatically."
                        )
                        .padding(.bottom, 12)
                    } else {
                        // Setup in progress — show guided steps
                        setupSection
                            .padding(.bottom, 12)
                    }
                } else {
                    helpCard(
                        "Monitor and control Claude Code sessions remotely via a Telegram bot."
                    )
                    .padding(.bottom, 12)
                }

                if let error = bridge.lastBridgeError {
                    errorCard(error)
                        .padding(.bottom, 12)
                }
            }
            .padding(16)
        }
        .onAppear {
            bridge.hooksInstalled = bridge.checkHooksInstalled()
            bridge.checkAccessibility()
            Task { await bridge.validateConnection() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.title3.weight(.semibold))

            Spacer()
        }
    }

    // MARK: - Enable

    private var enableRow: some View {
        HStack {
            Label("Telegram Bridge", systemImage: "paperplane.fill")
                .font(.callout.weight(.medium))
            Spacer()
            Toggle("", isOn: Binding(
                get: { bridge.isEnabled },
                set: { val in Task { await bridge.setEnabled(val) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Setup (guided steps)

    private var setupSection: some View {
        VStack(spacing: 10) {
            // Step 1: Bot token
            stepCard(
                number: 1,
                title: "@BotFather Token",
                done: !bridge.botToken.isEmpty
            ) {
                if isEditingToken {
                    HStack(spacing: 8) {
                        TextField("Paste token here", text: $tokenInput)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .onSubmit { saveToken() }
                        Button("Save") { saveToken() }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                            .buttonStyle(.plain)
                    }
                } else if bridge.botToken.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Create a bot with @BotFather on Telegram, then paste the token here.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add Token") {
                            tokenInput = ""
                            isEditingToken = true
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack {
                        Text("****\(String(bridge.botToken.suffix(4)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Spacer()
                        Button("Edit") {
                            tokenInput = bridge.botToken
                            isEditingToken = true
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                    }
                }
            }

            // Step 2: Connect
            stepCard(
                number: 2,
                title: "Connection",
                done: bridge.isConnected
            ) {
                if bridge.botToken.isEmpty {
                    Text("Add a bot token first.")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                } else if bridge.isConnected {
                    if bridge.chatId > 0 {
                        Text("Chat \(bridge.chatId)")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Send any message to your bot on Telegram to link it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Step 3: Hooks
            stepCard(
                number: 3,
                title: "Claude Hooks",
                done: bridge.hooksInstalled
            ) {
                if bridge.hooksInstalled {
                    HStack {
                        Text("Installed in ~/.claude/settings.json")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Uninstall") { bridge.uninstallHooks() }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                            .buttonStyle(.plain)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Install hooks so Claude Code events are forwarded to Telegram.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Install Hooks") {
                            bridge.installHooks()
                            Task { await bridge.finalizeSetup() }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                        .disabled(bridge.isFinalizingSetup)
                    }
                }
            }

            // Step 4: Accessibility
            stepCard(
                number: 4,
                title: "Terminal Access",
                done: bridge.accessibilityGranted
            ) {
                if !bridge.hooksInstalled {
                    Text("Install hooks first.")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                } else if bridge.accessibilityGranted {
                    Text("Granted — message injection enabled.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Required to send messages to terminal sessions.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Grant Access") {
                            bridge.promptAccessibility()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Status (fully configured)

    private var statusCard: some View {
        VStack(spacing: 0) {
            settingsRow("Status") {
                statusBadge("Connected")
            }
            rowDivider
            settingsRow("@BotFather Token") {
                HStack(spacing: 8) {
                    Text("****\(String(bridge.botToken.suffix(4)))")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Button("Edit") {
                        tokenInput = bridge.botToken
                        isEditingToken = true
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                }
            }
            if isEditingToken {
                rowDivider
                HStack(spacing: 8) {
                    TextField("Paste token", text: $tokenInput)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit { saveToken() }
                    Button("Save") { saveToken() }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if bridge.chatId > 0 {
                rowDivider
                settingsRow("Chat ID") {
                    Text("\(bridge.chatId)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            rowDivider
            settingsRow("Claude Hooks") {
                statusBadge("Installed")
            }
            rowDivider
            settingsRow("Terminal Access") {
                statusBadge("Granted")
            }
            rowDivider
            HStack {
                Spacer()
                Button("Uninstall Hooks") { bridge.uninstallHooks() }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Notifications

    private var notificationsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ForEach(Array(BridgeCoordinator.MessageFilter.allCases.enumerated()), id: \.element) { index, filter in
                if index > 0 { rowDivider }
                filterRow(filter)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func filterRow(_ filter: BridgeCoordinator.MessageFilter) -> some View {
        HStack(spacing: 10) {
            Image(systemName: filter.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(filter.label)
                    .font(.caption)
                Text(filter.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { bridge.isFilterEnabled(filter) },
                set: { bridge.setFilter(filter, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Reusable pieces

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func statusBadge(_ text: String, color: Color? = nil) -> some View {
        let c = color ?? .secondary
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(c.opacity(0.12), in: Capsule())
    }

    private var rowDivider: some View {
        Divider().opacity(0.12).padding(.horizontal, 14)
    }

    private func stepCard<Content: View>(
        number: Int,
        title: String,
        done: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(done ? Color.green.opacity(0.15) : .white.opacity(0.06))
                        .frame(width: 20, height: 20)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(done ? .secondary : .primary)
            }

            content()
                .padding(.leading, 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func helpCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.widgetYellow)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func saveToken() {
        Task { await bridge.saveBotToken(tokenInput) }
        isEditingToken = false
    }
}
