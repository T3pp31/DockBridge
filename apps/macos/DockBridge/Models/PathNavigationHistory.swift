import Foundation

/// Tracks back/forward navigation for a file pane path.
struct PathNavigationHistory: Equatable {
    private(set) var current: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    init(current: String) {
        self.current = current
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func navigate(to path: String) {
        guard path != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = path
    }

    mutating func goBack() -> String? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return current
    }

    mutating func goForward() -> String? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return current
    }

    mutating func reset(to path: String) {
        current = path
        backStack.removeAll()
        forwardStack.removeAll()
    }
}

enum PathBreadcrumb {
    struct Segment: Identifiable, Equatable {
        let path: String
        let title: String

        var id: String { path }
    }

    static func segments(forLocalPath path: String) -> [Segment] {
        let normalized = (path as NSString).standardizingPath
        guard normalized != "/" else {
            return [Segment(path: "/", title: "/")]
        }

        var segments: [Segment] = [Segment(path: "/", title: "/")]
        var accumulated = ""
        for component in normalized.split(separator: "/").map(String.init) where !component.isEmpty {
            accumulated += "/\(component)"
            segments.append(Segment(path: accumulated, title: component))
        }
        return segments
    }

    static func segments(forRemotePath path: String) -> [Segment] {
        let normalized = path.hasSuffix("/") && path != "/"
            ? String(path.dropLast())
            : path
        guard normalized != "/" else {
            return [Segment(path: "/", title: "/")]
        }

        var segments: [Segment] = [Segment(path: "/", title: "/")]
        var accumulated = ""
        for component in normalized.split(separator: "/").map(String.init) where !component.isEmpty {
            accumulated += "/\(component)"
            segments.append(Segment(path: accumulated, title: component))
        }
        return segments
    }
}
