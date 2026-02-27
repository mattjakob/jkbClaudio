import SwiftUI

struct MenuBarLabel: View {
    let utilization: Double
    let isConnected: Bool
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isConnected ? icon : "terminal.fill")
            if isConnected {
                Text("\(Int(utilization))%")
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(isConnected ? color : .secondary)
    }
}
