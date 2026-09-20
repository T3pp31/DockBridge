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
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// Formats POSIX permission bits (e.g. 0o755 -> "rwxr-xr-x").
enum PermissionFormatter {
    static func string(from mode: UInt32) -> String {
        // Bit 8 = owner-read ... bit 0 = other-execute
        let bits: [(shift: UInt32, ch: Character)] = [
            (8, "r"), (7, "w"), (6, "x"),
            (5, "r"), (4, "w"), (3, "x"),
            (2, "r"), (1, "w"), (0, "x"),
        ]
        return bits.map { (shift, ch) in
            (mode & (1 << shift)) != 0 ? String(ch) : "-"
        }.joined()
    }
}
