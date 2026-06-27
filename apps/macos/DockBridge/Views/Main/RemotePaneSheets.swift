import SwiftUI

struct RemoteEntryNameSheet: View {
    let title: String
    let fieldLabel: String
    let confirmLabel: String
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        RemotePath.isValidEntryName(trimmedName)
    }

    private var validationMessage: String? {
        guard !trimmedName.isEmpty, !isValid else { return nil }
        return RemoteEntryNameError.invalidCharacters.localizedDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2)
                .bold()

            Form {
                LabeledContent(fieldLabel) {
                    TextField(fieldLabel, text: $name)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
    }
}

struct RemoteRenameSheet: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        RemoteEntryNameSheet(
            title: "Rename",
            fieldLabel: "New name",
            confirmLabel: "Rename",
            name: $viewModel.renameText,
            onCancel: {
                viewModel.renameTarget = nil
            },
            onConfirm: {
                Task { await viewModel.commitRename() }
            }
        )
    }
}

struct RemoteNewFolderSheet: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        RemoteEntryNameSheet(
            title: "New Folder",
            fieldLabel: "Folder name",
            confirmLabel: "Create",
            name: $viewModel.mkdirName,
            onCancel: {
                viewModel.mkdirName = ""
                viewModel.showMkdirPrompt = false
            },
            onConfirm: {
                Task { await viewModel.commitMkdir() }
            }
        )
    }
}

struct RemoteDeleteConfirmSheet: View {
    let path: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete remote item?", systemImage: "trash")
                .font(.title2)
                .bold()

            Text("This action cannot be undone.")
                .foregroundStyle(.secondary)

            GroupBox("Path") {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}
