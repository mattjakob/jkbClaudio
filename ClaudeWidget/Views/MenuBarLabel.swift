import SwiftUI

struct MenuBarLabel: View {
    let utilization: Double
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal.fill")
            if isConnected {
                Text("\(Int(utilization))%")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
    }
}
