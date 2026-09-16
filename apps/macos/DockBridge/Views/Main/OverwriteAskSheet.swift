import SwiftUI

struct OverwriteAskSheet: View {
    let destinationLabel: String
    let onKeep: () -> Void
    let onReplace: () -> Void

    var body: some View {
        DialogCard(title: String(localized: "Replace Existing File?")) {
            Text(String(localized: "An item already exists at the destination. Replace it?"))
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection(String(localized: "Destination")) {
                Text(destinationLabel)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } footer: {
            Button(String(localized: "Keep Existing"), role: .cancel, action: onKeep)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Replace"), role: .destructive, action: onReplace)
                .keyboardShortcut(.defaultAction)
        }
    }
}
