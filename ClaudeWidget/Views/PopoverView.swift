import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                headerSection
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

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAUDE CODE")
                    .font(.caption)
                    .fontWeight(.bold)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isConnected ? .green : .red)
                        .frame(width: 6, height: 6)
                    Text(viewModel.isConnected ? "Connected" : "Disconnected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private var usageSection: some View {
        UsageCard(
            fiveHourUtilization: viewModel.fiveHourUtilization,
            fiveHourResetsAt: viewModel.fiveHourResetsAt,
            weeklyUtilization: viewModel.weeklyUtilization,
            weeklyResetsAt: viewModel.weeklyResetsAt
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
