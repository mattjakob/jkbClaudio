import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel
    @State private var chartRange: ChartRange = .sevenDay

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                chartSection
                usageSection
                sessionsSection
                statsSection
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
            range: $chartRange
        )
    }

    private var usageSection: some View {
        UsageCard(
            fiveHourUtilization: viewModel.fiveHourUtilization,
            fiveHourResetsAt: viewModel.fiveHourResetsAt,
            weeklyUtilization: viewModel.weeklyUtilization,
            weeklyResetsAt: viewModel.weeklyResetsAt,
            chartRange: chartRange
        )
    }

    private var sessionsSection: some View {
        SessionCard(sessions: viewModel.activeSessions)
    }

    private var statsSection: some View {
        StatsCard(stats: viewModel.weeklyStats)
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
