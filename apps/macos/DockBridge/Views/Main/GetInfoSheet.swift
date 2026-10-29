import SwiftUI

/// Get Info sheet (⌘I / context menu) showing metadata for a selected file.
/// For remote items only the fields reported by the SFTP server are available;
/// local items additionally show POSIX permission bits.
struct GetInfoSheet: View {
    let title: String
    let rows: [(label: String, value: String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DialogCard(title: title) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.label) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        Text(row.value.isEmpty ? "—" : row.value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } footer: {
            Button(String(localized: "Close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// Formats POSIX permission bits including setuid/setgid/sticky
/// (e.g. 0o4755 -> "rwsr-xr-x", 0o1777 -> "rwxrwxrwt").
enum PermissionFormatter {
    static func string(from mode: UInt32) -> String {
        func read(_ shift: UInt32) -> Bool { (mode & (1 << shift)) != 0 }

        let ownerX = read(6)
        let groupX = read(3)
        let otherX = read(0)

        var owner = read(8) ? "r" : "-"
        owner += read(7) ? "w" : "-"
        owner += read(11) ? (ownerX ? "s" : "S") : (ownerX ? "x" : "-")

        var group = read(5) ? "r" : "-"
        group += read(4) ? "w" : "-"
        group += read(10) ? (groupX ? "s" : "S") : (groupX ? "x" : "-")

        var other = read(2) ? "r" : "-"
        other += read(1) ? "w" : "-"
        other += read(9) ? (otherX ? "t" : "T") : (otherX ? "x" : "-")

        return owner + group + other
    }
}
