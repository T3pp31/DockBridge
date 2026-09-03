import SwiftUI

struct OverwriteAskSheet: View {
    let destinationLabel: String
    let onKeep: () -> Void
    let onReplace: () -> Void

    var body: some View {
        DialogCard(title: "Replace Existing File?") {
            Text("An item already exists at the destination. Replace it?")
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection("Destination") {
                Text(destinationLabel)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } footer: {
            Button("Keep Existing", role: .cancel, action: onKeep)
                .keyboardShortcut(.cancelAction)
            Button("Replace", role: .destructive, action: onReplace)
                .keyboardShortcut(.defaultAction)
        }
    }
}
