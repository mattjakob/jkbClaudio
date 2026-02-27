import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel

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
            currentUtilization: viewModel.weeklyUtilization,
            resetsAt: viewModel.weeklyResetsAt,
            isLoading: viewModel.isLoading
        )
    }

    private var usageSection: some View {
        UsageCard(
            fiveHourUtilization: viewModel.fiveHourUtilization,
            fiveHourResetsAt: viewModel.fiveHourResetsAt
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
