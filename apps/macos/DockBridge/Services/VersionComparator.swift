import Foundation

enum VersionComparisonResult {
    case orderedAscending
    case orderedSame
    case orderedDescending
}

enum VersionComparator {
    static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    static func compare(_ lhs: String, _ rhs: String) -> VersionComparisonResult {
        let left = versionComponents(normalize(lhs))
        let right = versionComponents(normalize(rhs))
        let maxCount = max(left.count, right.count)

        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue {
                return .orderedAscending
            }
            if leftValue > rightValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part) ?? 0
        }
    }
}
