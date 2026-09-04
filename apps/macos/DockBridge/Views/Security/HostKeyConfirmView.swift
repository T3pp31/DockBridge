import SwiftUI

struct HostKeyConfirmView: View {
    let challenge: HostKeyChallenge
    let onAccept: () -> Void
    let onReject: () -> Void

    private var isMismatch: Bool {
        challenge.expectedFingerprintSha256 != nil
    }

    var body: some View {
        DialogCard(
            title: isMismatch ? "Host Key Changed" : "Unknown Host Key",
            titleSystemImage: isMismatch ? "exclamationmark.triangle" : nil
        ) {
            if isMismatch {
                mismatchContent
            } else {
                unknownContent
            }
        } footer: {
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

    private var unknownContent: some View {
        Group {
            Text("The authenticity of host \(challenge.host):\(challenge.port.portLabel) can't be established.")
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection("SHA256 Fingerprint") {
                Text(challenge.fingerprintSha256)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            DialogDetailSection("How to verify") {
                Text(
                    """
                    Compare the fingerprint above with a value the server \
                    administrator or hosting provider publishes out-of-band \
                    (their website, setup email, or console). Match the \
                    characters exactly before accepting.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            DialogFootnote(text: "Accept only if you trust this fingerprint.")
        }
    }

    private var mismatchContent: some View {
        Group {
            Text(
                """
                The host key for \(challenge.host):\(challenge.port.portLabel) has changed. \
                This may indicate a man-in-the-middle attack. \
                Verify the new fingerprint with the server administrator before accepting.
                """
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                DialogDetailSection("Previous SHA256") {
                    Text(challenge.expectedFingerprintSha256 ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                DialogDetailSection("New SHA256") {
                    Text(challenge.fingerprintSha256)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            DialogDetailSection("How to verify") {
                Text(
                    """
                    Compare both fingerprints with a value the server \
                    administrator confirms out-of-band. If you did not \
                    change the server key, Reject to be safe.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            DialogFootnote(text: "Reject unless you intentionally changed the server key.")
        }
    }
}

extension HostKeyChallenge {
    var isHostKeyMismatch: Bool {
        expectedFingerprintSha256 != nil
    }
}
