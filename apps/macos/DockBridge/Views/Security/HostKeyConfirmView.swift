import SwiftUI

struct HostKeyConfirmView: View {
    let challenge: HostKeyChallenge
    let onAccept: () -> Void
    let onReject: () -> Void

    private var isMismatch: Bool {
        challenge.expectedFingerprintSha256 != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isMismatch {
                mismatchContent
            } else {
                unknownContent
            }

            HStack {
                Spacer()
                if isMismatch {
                    Button("Reject", role: .cancel, action: onReject)
                        .keyboardShortcut(.defaultAction)
                    Button("Accept", role: .destructive, action: onAccept)
                } else {
                    Button("Reject", role: .cancel, action: onReject)
                    Button("Accept", action: onAccept)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private var unknownContent: some View {
        Group {
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
        }
    }

    private var mismatchContent: some View {
        Group {
            Label("Host Key Changed", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
                .bold()
                .foregroundStyle(.orange)

            Text(
                """
                The host key for \(challenge.host):\(challenge.port.portLabel) has changed. \
                This may indicate a man-in-the-middle attack. \
                Verify the new fingerprint with the server administrator before accepting.
                """
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Previous SHA256") {
                    Text(challenge.expectedFingerprintSha256 ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("New SHA256") {
                    Text(challenge.fingerprintSha256)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Reject unless you intentionally changed the server key.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

extension HostKeyChallenge {
    var isHostKeyMismatch: Bool {
        expectedFingerprintSha256 != nil
    }
}
