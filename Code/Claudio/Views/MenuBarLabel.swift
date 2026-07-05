import SwiftUI

struct MenuBarLabel: View {
    let utilization: Double
    let isConnected: Bool
    let icon: String
    let color: Color

    var body: some View {
        // MenuBarExtra renders its label as a monochrome template image,
        // stripping foreground colors. For warning states, bypass that by
        // pre-rendering to a non-template NSImage. The normal (white) state
        // stays template-rendered so it adapts to light/dark menu bars.
        if isConnected && color != .white {
            Image(nsImage: coloredImage)
        } else {
            labelContent
        }
    }

    private var labelContent: some View {
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

    private var coloredImage: NSImage {
        let renderer = ImageRenderer(content: labelContent)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        return image
    }
}
