import SwiftUI

@main
struct ClaudioApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(viewModel: viewModel)
                .frame(width: 320, height: 520)
        } label: {
            MenuBarLabel(
                utilization: viewModel.weeklyUtilization,
                isConnected: viewModel.isConnected
            )
        }
        .menuBarExtraStyle(.window)
    }
}
