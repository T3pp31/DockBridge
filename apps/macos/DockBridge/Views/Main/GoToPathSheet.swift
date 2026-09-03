import SwiftUI

/// A small sheet for typing a path and jumping to it (Issue #224).
///
/// Local paths may use `~`; invalid folders surface an error via the view
/// model. Remote paths must be absolute.
struct GoToPathSheet: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.goToPathPane == .local ? "Go to Local Path" : "Go to Remote Path")
                .font(.title3)
                .bold()

            TextField(
                viewModel.goToPathPane == .local ? "~/Documents" : "/home/user",
                text: $viewModel.goToPathText
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onKeyPress(.return) {
                viewModel.commitGoToPath()
                viewModel.showGoToPath = false
                return .handled
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    viewModel.showGoToPath = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Go") {
                    viewModel.commitGoToPath()
                    viewModel.showGoToPath = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: DialogCardMetrics.minWidth)
    }
}
