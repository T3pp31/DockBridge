import AppKit
import SwiftUI
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
        XCTAssertNotNil(RemoteEntryNameSheet.validationMessage(for: "bad/name"))
        XCTAssertNil(RemoteEntryNameSheet.validationMessage(for: "valid-name"))
        XCTAssertNil(RemoteEntryNameSheet.validationMessage(for: "  "))
    }
}

@MainActor
final class ExpandingFrameTests: XCTestCase {
    func testVerticalScrollContentCanGrowAndShrinkAfterMeasurement() {
        let probe = ExpandingFrameProbe()
        let window = makeWindow(ScrollView(.vertical) {
            ExpandingFrameProbeView(probe: probe)
        }.scrollIndicators(.hidden))
        defer { window.close() }

        assertLayout(in: window, probe: probe, height: 40)
        probe.contentSize.height = 420
        assertLayout(in: window, probe: probe, height: 420)
        probe.contentSize.height = 20
        assertLayout(in: window, probe: probe, height: 20)
    }

    func testHorizontalScrollContentCanGrowAndShrinkAfterMeasurement() {
        let probe = ExpandingFrameProbe()
        let window = makeWindow(ScrollView(.horizontal) {
            ExpandingFrameProbeView(probe: probe)
        }.scrollIndicators(.hidden))
        defer { window.close() }

        assertLayout(in: window, probe: probe, width: 40)
        probe.contentSize.width = 420
        assertLayout(in: window, probe: probe, width: 420)
        probe.contentSize.width = 20
        assertLayout(in: window, probe: probe, width: 20)
    }

    func testFiniteParentStillFillsAndPassesResizedFrameToContent() {
        let probe = ExpandingFrameProbe(usesMeasuredSize: true)
        let window = makeWindow(ExpandingFrameProbeView(probe: probe))
        defer { window.close() }

        assertLayout(in: window, probe: probe, width: 300, height: 200)
        window.setContentSize(CGSize(width: 180, height: 120))
        assertLayout(in: window, probe: probe, width: 180, height: 120)
        window.setContentSize(CGSize(width: 420, height: 260))
        assertLayout(in: window, probe: probe, width: 420, height: 260)
    }

    private func makeWindow<Content: View>(_ content: Content) -> NSWindow {
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        return window
    }

    private func assertLayout(
        in window: NSWindow,
        probe: ExpandingFrameProbe,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Wait for both the outer geometry and the size delivered back to the
        // content, so mutations happen only after the initial feedback pass.
        func isSettled() -> Bool {
            probe.frameSize != .zero
                && probe.frameSize == probe.receivedSize
                && (width == nil || probe.frameSize.width == width)
                && (height == nil || probe.frameSize.height == height)
                && (!probe.usesMeasuredSize || probe.childSize == probe.frameSize)
        }
        let deadline = Date().addingTimeInterval(2)
        while !isSettled(), Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(probe.receivedSize, probe.frameSize, file: file, line: line)
        if let width {
            XCTAssertEqual(probe.frameSize.width, width, file: file, line: line)
        }
        if let height {
            XCTAssertEqual(probe.frameSize.height, height, file: file, line: line)
        }
        if probe.usesMeasuredSize {
            XCTAssertEqual(probe.childSize, probe.frameSize, file: file, line: line)
        }
    }
}

@MainActor
private final class ExpandingFrameProbe: ObservableObject {
    @Published var contentSize = CGSize(width: 40, height: 40)
    let usesMeasuredSize: Bool
    var frameSize: CGSize = .zero
    var receivedSize: CGSize = .zero
    var childSize: CGSize = .zero

    init(usesMeasuredSize: Bool = false) {
        self.usesMeasuredSize = usesMeasuredSize
    }
}

private struct ExpandingFrameProbeView: View {
    @ObservedObject var probe: ExpandingFrameProbe

    var body: some View {
        ExpandingFrame { size in
            Color.clear
                .frame(
                    width: probe.usesMeasuredSize ? size.width : probe.contentSize.width,
                    height: probe.usesMeasuredSize ? size.height : probe.contentSize.height
                )
                .onChange(of: size, initial: true) { _, newSize in
                    probe.receivedSize = newSize
                }
                .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                    probe.childSize = newSize
                }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
            probe.frameSize = newSize
        }
    }
}
