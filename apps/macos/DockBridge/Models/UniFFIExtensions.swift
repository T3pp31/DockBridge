import Foundation

extension RemoteFileRecord: Identifiable {
    public var id: String { path }
}

extension TransferTaskRecord: Identifiable {}
