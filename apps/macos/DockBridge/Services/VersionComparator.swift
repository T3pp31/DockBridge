import Foundation

enum VersionComparisonResult {
    case orderedAscending
    case orderedSame
    case orderedDescending
}

enum VersionComparatorError: Error {
    case invalidVersionFormat(String)
}

enum VersionComparator {
    static func normalize(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    /// Compares two version strings. Invalid (non-numeric) components cause
    /// the version to be treated as `0.0.0` so that malformed tags never
    /// appear newer than a real release. Use `compareStrict` when the caller
    /// needs to reject invalid versions outright.
    static func compare(_ lhs: String, _ rhs: String) -> VersionComparisonResult {
        let left = versionComponents(normalize(lhs)) ?? [0]
        let right = versionComponents(normalize(rhs)) ?? [0]
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

    /// Strict comparison that throws when either version contains
    /// non-numeric components. Use this to reject malformed release tags.
    static func compareStrict(_ lhs: String, _ rhs: String) throws -> VersionComparisonResult {
        guard let left = versionComponents(normalize(lhs)) else {
            throw VersionComparatorError.invalidVersionFormat(lhs)
        }
        guard let right = versionComponents(normalize(rhs)) else {
            throw VersionComparatorError.invalidVersionFormat(rhs)
        }
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

    /// Returns `true` only when `candidate` is strictly newer than `current`
    /// and both versions use valid numeric dot-separated components.
    static func isNewerStrict(_ candidate: String, than current: String) -> Bool {
        guard let left = versionComponents(normalize(candidate)),
              let right = versionComponents(normalize(current)) else {
            return false
        }
        let maxCount = max(left.count, right.count)
        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue {
                return false
            }
            if leftValue > rightValue {
                return true
            }
        }
        return false
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Parses dot-separated numeric version components.
    /// Returns `nil` when any component is not a non-negative integer,
    /// so malformed tags (e.g. `v999.0.bad`) are rejected rather than
    /// silently treated as `0`.
    private static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".")
        if parts.isEmpty {
            return nil
        }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else {
                return nil
            }
            components.append(value)
        }
        return components
    }
}
