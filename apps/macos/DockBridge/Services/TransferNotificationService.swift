import UserNotifications

enum TransferNotificationService {
    static func requestAuthorizationIfNeeded(for config: AppConfig) {
        guard config.notifyWhenTransfersFinish else { return }

        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound]
                )
            } catch {
                AppLogging.transfer.error(
                    "Failed to request transfer notification authorization: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    static func post(
        identifier: String,
        title: String,
        body: String,
        playSound: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = playSound ? .default : nil

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                AppLogging.transfer.error(
                    "Failed to post transfer notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
