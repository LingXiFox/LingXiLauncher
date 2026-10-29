import Foundation

/// Shared, deterministic update selection for Modrinth projects.
///
/// Modrinth version numbers are not required to be semantic versions. The policy compares
/// numeric/text runs naturally and never treats a different release channel as an automatic
/// upgrade. If the installed version is missing from the compatible set, callers must not guess.
enum ModrinthUpdatePolicy {
    static func compareVersionNumbers(_ lhs: String, _ rhs: String) -> Int {
        let left = versionTokens(lhs)
        let right = versionTokens(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            switch (index < left.count ? left[index] : .numeric(0),
                    index < right.count ? right[index] : .numeric(0)) {
            case let (.numeric(a), .numeric(b)):
                if a != b { return a < b ? -1 : 1 }
            case let (.text(a), .text(b)):
                if a != b { return a < b ? -1 : 1 }
            case (.numeric, .text), (.text, .numeric):
                // Different token shapes are not reliably comparable. Use a deterministic
                // textual fallback rather than claiming a newer/downgrade relationship.
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending ? -1 : 1
            }
        }
        return 0
    }

    static func allowedVersionTypes(for current: ModrinthVersionType) -> Set<ModrinthVersionType> {
        switch current {
        case .release: return [.release]
        case .beta: return [.release, .beta]
        case .alpha: return [.release, .beta, .alpha]
        case .unknown: return [.release, .beta, .alpha]
        }
    }

    /// Selects the highest strictly newer compatible version whose channel is allowed by the
    /// installed version's channel. `file` filters out versions without a usable artifact.
    static func selectUpdate(
        current: ModrinthVersion,
        from versions: [ModrinthVersion],
        file: (ModrinthVersion) -> ModrinthFile?
    ) -> ModrinthVersion? {
        let allowed = allowedVersionTypes(for: current.versionType)
        return versions
            .filter {
                $0.id != current.id
                    && allowed.contains($0.versionType)
                    && file($0) != nil
                    && compareVersionNumbers($0.versionNumber, current.versionNumber) > 0
            }
            .max { compareVersionNumbers($0.versionNumber, $1.versionNumber) < 0 }
    }

    private enum VersionToken: Equatable {
        case numeric(Int)
        case text(String)
    }

    private static func versionTokens(_ value: String) -> [VersionToken] {
        var result: [VersionToken] = []
        var current = ""
        var currentIsDigit: Bool?
        for character in value.lowercased() {
            let isDigit = character.isNumber
            if currentIsDigit != nil, currentIsDigit != isDigit {
                result.append(currentIsDigit == true
                    ? .numeric(Int(current) ?? 0)
                    : .text(String(current)))
                current = ""
            }
            current.append(character)
            currentIsDigit = isDigit
        }
        if !current.isEmpty {
            result.append(currentIsDigit == true
                ? .numeric(Int(current) ?? 0)
                : .text(String(current)))
        }
        return result
    }
}
