import SwiftUI

struct PopoverView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if !viewModel.isConnected, let error = viewModel.lastError {
                    errorSection(error)
                }
                chartSection
                usageSection
                sessionsSection
                footerSection
            }
            .padding(16)
        }
        .task {
            viewModel.startPolling()
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

    private var usageSection: some View {
        UsageCard(
            fiveHourUtilization: viewModel.fiveHourUtilization,
            fiveHourResetsAt: viewModel.fiveHourResetsAt,
            weeklyUtilization: viewModel.weeklyUtilization,
            weeklyResetsAt: viewModel.weeklyResetsAt,
            chartRange: $viewModel.chartRange,
            extraUsageEnabled: viewModel.extraUsageEnabled,
            extraUsageUtilization: viewModel.extraUsageUtilization,
            extraUsageUsedDollars: viewModel.extraUsageUsedDollars,
            extraUsageLimitDollars: viewModel.extraUsageLimitDollars
        )
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

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
