import SwiftUI

struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    var transferSummary: String?
    var remoteEditSessions: [MainViewModel.RemoteEditSession] = []
    var onRetryRemoteEditSession: (UUID) -> Void = { _ in }
    var onStopRemoteEditSession: (MainViewModel.RemoteEditSession) -> Void = { _ in }
    var onStopAllRemoteEditSessions: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            // The indicator is the single accessibility owner for connection
            // status (Issue #231); the visible title below is decorative.
            ConnectionStatusIndicator(status: status)

            Text(status.statusTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            if let transferSummary {
                Text(transferSummary)
                    .font(DesignTokens.Fonts.monospacedDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .accessibilityLabel(String(format: String(localized: "Transfer activity: %@"), transferSummary))
            }

            if !remoteEditSessions.isEmpty {
                Divider()
                    .frame(height: 14)

                Menu {
                    ForEach(remoteEditSessions) { session in
                        Section(session.localURL.lastPathComponent) {
                            Label(session.state.title, systemImage: session.state.systemImage)

                            if session.state.canRetry {
                                Button(String(localized: "Retry Upload")) {
                                    onRetryRemoteEditSession(session.id)
                                }
                            }

                            Button(String(localized: "Stop Watching"), role: .destructive) {
                                onStopRemoteEditSession(session)
                            }
                        }
                    }

                    Divider()

                    Button(String(localized: "Stop All Watching"), role: .destructive) {
                        onStopAllRemoteEditSessions()
                    }
                } label: {
                    Label(remoteEditSummary, systemImage: remoteEditSummaryImage)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(remoteEditSummary)
            }

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.statusBarHorizontal)
        .padding(.vertical, DesignTokens.Spacing.statusBarVertical)
        .background(.bar)
    }

    private var remoteEditSummary: String {
        let failures = remoteEditSessions.filter { $0.state.canRetry }.count
        if failures > 0 {
            return String(
                format: String(localized: "%lld edit upload(s) need attention"),
                Int64(failures)
            )
        }
        return String(
            format: String(localized: "Watching %lld external edit(s)"),
            Int64(remoteEditSessions.count)
        )
    }

    private var remoteEditSummaryImage: String {
        remoteEditSessions.contains { $0.state.canRetry }
            ? "exclamationmark.triangle"
            : "pencil.and.outline"
    }
}
