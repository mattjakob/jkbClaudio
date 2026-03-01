import SwiftUI

struct PopoverView: View {
    @Bindable var viewModel: AppViewModel
    @State private var scrollID: Bool?
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if !viewModel.isConnected, let error = viewModel.lastError {
                        errorSection(error)
                    }
                    chartSection
                    if viewModel.extraUsageEnabled {
                        extraUsageSection
                    }
                    sessionsSection
                    footerSection
                }
                .padding(16)
                .id(true)
            }
            .onAppear {
                proxy.scrollTo(true, anchor: .top)
            }
        }
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
                Task { await viewModel.refresh() }
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
