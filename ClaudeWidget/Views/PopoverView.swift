import SwiftUI

struct PopoverView: View {
    let viewModel: AppViewModel

    var body: some View {
        VStack {
            Text("Loading...")
        }
        .task {
            viewModel.startPolling()
        }
    }
}
