import Foundation
import os

/// Central logger definitions so subsystems keep consistent, searchable
/// categories in Console.app (`log show --predicate 'subsystem == "com.dockbridge.app"'`).
enum AppLogging {
    static let subsystem = "com.dockbridge.app"

    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let update = Logger(subsystem: subsystem, category: "update")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let security = Logger(subsystem: subsystem, category: "security")
}
