import SwiftUI

struct ConnectionListView: View {
    @ObservedObject var viewModel: ConnectionListViewModel
    @Binding var showNewConnection: Bool
    @Binding var editingProfile: ConnectionProfile?

    var body: some View {
        List(selection: $viewModel.selectedProfileID) {
            ForEach(viewModel.profiles) { profile in
                HStack(spacing: 8) {
                    connectionIndicator(for: profile)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName)
                            .font(.headline)
                        Text(profile.endpointLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    .disabled(viewModel.connectionStatus.isConnected || viewModel.connectionStatus.isConnecting)

                    Button("Disconnect") {
                        Task { await viewModel.disconnect() }
                    }
                    .disabled(!viewModel.connectionStatus.isConnected)
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

    @ViewBuilder
    private func connectionIndicator(for profile: ConnectionProfile) -> some View {
        let isActiveProfile = viewModel.connectedProfileID == profile.id

        if isActiveProfile, viewModel.connectionStatus.isConnected {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Connected")
        } else if isActiveProfile, viewModel.connectionStatus.isConnecting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Connecting")
        } else {
            Circle()
                .fill(.clear)
                .frame(width: 8, height: 8)
        }
    }
}
