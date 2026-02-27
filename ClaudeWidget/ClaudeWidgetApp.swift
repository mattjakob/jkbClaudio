import SwiftUI

@main
struct ClaudeWidgetApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("ClaudeWidget placeholder")
                .frame(width: 320, height: 200)
                .padding()
        } label: {
            Label("Claude", systemImage: "terminal.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
