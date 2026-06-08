import SwiftUI

struct ConnectionListView: View {
    @ObservedObject var viewModel: ConnectionListViewModel
    @Binding var showNewConnection: Bool
    @Binding var editingProfile: ConnectionProfile?

    var body: some View {
        List(selection: $viewModel.selectedProfileID) {
            ForEach(viewModel.profiles) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(profile.id)
                .contextMenu {
                    Button("Connect") {
                        viewModel.requestConnect(profile: profile)
                    }
                    Button("Edit") {
                        editingProfile = profile
                    }
                    Button("Delete", role: .destructive) {
                        viewModel.delete(profile: profile)
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showNewConnection = true
                } label: {
                    Label("Add", systemImage: "plus")
                }

                if let selected = viewModel.profiles.first(where: { $0.id == viewModel.selectedProfileID }) {
                    Button("Connect") {
                        viewModel.requestConnect(profile: selected)
                    }
                    .disabled(viewModel.isConnected)

                    Button("Disconnect") {
                        Task { await viewModel.disconnect() }
                    }
                    .disabled(!viewModel.isConnected)
                }
            }
        }
        .alert("Connect as root?", isPresented: $viewModel.showRootWarning) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingConnectProfile = nil
            }
            Button("Connect Anyway", role: .destructive) {
                viewModel.confirmRootConnect()
            }
        } message: {
            Text("Connecting as root is discouraged. Continue only if you understand the risks.")
        }
        .errorAlert(message: $viewModel.errorMessage)
    }
}
