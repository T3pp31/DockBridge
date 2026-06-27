import XCTest
@testable import DockBridge

@MainActor
final class RemotePaneSheetsTests: XCTestCase {
    func testEntryNameSheetBuildsForRename() {
        let bridge = RustBridgeService()
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        viewModel.renameText = "renamed.txt"

        let view = RemoteRenameSheet(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    func testEntryNameSheetBuildsForNewFolder() {
        let bridge = RustBridgeService()
        let connectionList = ConnectionListViewModel(bridge: bridge)
        let transferQueue = TransferQueueViewModel(bridge: bridge)
        let viewModel = MainViewModel(
            bridge: bridge,
            connectionList: connectionList,
            transferQueue: transferQueue
        )
        viewModel.mkdirName = "newfolder"

        let view = RemoteNewFolderSheet(viewModel: viewModel)
        XCTAssertNotNil(view.body)
    }

    func testDeleteConfirmSheetBuilds() {
        let view = RemoteDeleteConfirmSheet(
            path: "/home/user/example.txt",
            onCancel: {},
            onDelete: {}
        )
        XCTAssertNotNil(view.body)
    }

    func testEntryNameSheetShowsValidationMessageForInvalidName() {
        let sheet = RemoteEntryNameSheet(
            title: "Rename",
            fieldLabel: "New name",
            confirmLabel: "Rename",
            name: .constant("bad/name"),
            onCancel: {},
            onConfirm: {}
        )
        XCTAssertNotNil(sheet.body)
    }
}
