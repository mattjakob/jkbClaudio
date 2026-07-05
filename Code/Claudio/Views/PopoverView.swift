import SwiftUI

struct PopoverView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        if showSettings {
            BridgeSettingsView(bridge: viewModel.bridge) {
                showSettings = false
            }
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if !viewModel.isConnected, let error = viewModel.lastError {
                            errorSection(error)
                        }
                        chartSection
                        if viewModel.tokenUsage.todayTotal.total > 0 {
                            TokenStatsCard(usage: viewModel.tokenUsage)
                        }
                        if !viewModel.scopedWindows.isEmpty {
                            scopedWindowsSection
                        }
                        if viewModel.extraUsageEnabled {
                            extraUsageSection
                        }
                        sessionsSection
                    }
                    .padding(16)
                    .id(true)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        proxy.scrollTo(true, anchor: .top)
                    }
                }
            }

            Spacer(minLength: 0)

            footerSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 12)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                showSettings = false
                viewModel.popoverOpened()
            }
        }
    }

    private var scopedWindowsSection: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.scopedWindows, id: \.name) { window in
                HStack {
                    Text(window.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(window.utilization))%")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var chartSection: some View {
        UsageChartCard(
            readings: viewModel.usageHistory,
            weeklyUtilization: viewModel.weeklyUtilization,
            fiveHourUtilization: viewModel.fiveHourUtilization,
            weeklyResetsAt: viewModel.weeklyResetsAt,
            fiveHourResetsAt: viewModel.fiveHourResetsAt,
            range: $viewModel.chartRange
        )
    }

    private var extraUsageSection: some View {
        ExtraUsageBar(
            utilization: viewModel.extraUsageUtilization,
            usedDollars: viewModel.extraUsageUsedDollars,
            limitDollars: viewModel.extraUsageLimitDollars
        )
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sessionsSection: some View {
        SessionCard(sessions: viewModel.activeSessions)
    }

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.widgetYellow)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footerSection: some View {
        HStack {
            Button("Refresh") {
                Task { await viewModel.refresh(userInitiated: true) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
