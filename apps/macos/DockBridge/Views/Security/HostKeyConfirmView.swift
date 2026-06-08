import SwiftUI

struct HostKeyConfirmView: View {
    let challenge: HostKeyChallenge
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unknown Host Key")
                .font(.title2)
                .bold()

            Text("The authenticity of host \(challenge.host):\(challenge.port.portLabel) can't be established.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("SHA256 Fingerprint") {
                Text(challenge.fingerprintSha256)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Accept only if you trust this fingerprint.")
                .foregroundStyle(.secondary)
                .font(.callout)

            HStack {
                Spacer()
                Button("Reject", role: .cancel, action: onReject)
                Button("Accept", action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}
