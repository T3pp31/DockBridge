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
            title: isMismatch ? String(localized: "Host Key Changed") : String(localized: "Unknown Host Key"),
            titleSystemImage: isMismatch ? "exclamationmark.triangle" : nil
        ) {
            if isMismatch {
                mismatchContent
            } else {
                unknownContent
            }
        } footer: {
            if isMismatch {
                Button(String(localized: "Reject"), role: .cancel, action: onReject)
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "Accept"), role: .destructive, action: onAccept)
            } else {
                Button(String(localized: "Reject"), role: .cancel, action: onReject)
                Button(String(localized: "Accept"), action: onAccept)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var unknownContent: some View {
        Group {
            Text(String(
                format: String(localized: "The authenticity of host %@:%@ can't be established."),
                challenge.host,
                challenge.port.portLabel
            ))
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection(String(localized: "SHA256 Fingerprint")) {
                Text(challenge.fingerprintSha256)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            DialogDetailSection(String(localized: "How to verify")) {
                Text(String(localized: "Compare the fingerprint above with a value the server administrator or hosting provider publishes out-of-band (their website, setup email, or console). Match the characters exactly before accepting."))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            DialogFootnote(text: String(localized: "Accept only if you trust this fingerprint."))
        }
    }

    private var mismatchContent: some View {
        Group {
            Text(String(
                format: String(localized: "The host key for %@:%@ has changed. This may indicate a man-in-the-middle attack. Verify the new fingerprint with the server administrator before accepting."),
                challenge.host,
                challenge.port.portLabel
            ))
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                DialogDetailSection(String(localized: "Previous SHA256")) {
                    Text(challenge.expectedFingerprintSha256 ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                DialogDetailSection(String(localized: "New SHA256")) {
                    Text(challenge.fingerprintSha256)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            DialogDetailSection(String(localized: "How to verify")) {
                Text(String(localized: "Compare both fingerprints with a value the server administrator confirms out-of-band. If you did not change the server key, Reject to be safe."))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            DialogFootnote(text: String(localized: "Reject unless you intentionally changed the server key."))
        }
    }
}

extension HostKeyChallenge {
    var isHostKeyMismatch: Bool {
        expectedFingerprintSha256 != nil
    }
}
