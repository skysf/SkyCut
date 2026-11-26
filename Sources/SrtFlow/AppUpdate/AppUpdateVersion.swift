import Foundation

// MARK: - SkyCut's release versions, and the macOS a release needs
//
// What it does: parses a release version the way SkyCut ships one ("0.18.69": three whole numbers and nothing else, no
// leading zeros) and orders them; a local or development build ("0.18.67-local.20261126.d3a6c971") is not a release
// version. Parses a minimum macOS ("15.0", "15.4.1") and compares it with the running system. Pure: the checks feed it
// every case.
// What it doesn't: read Info.plist or the feed (AppUpdateEligibility, AppUpdateFeed).
// Rules: docs/architecture/app-updates.md "The feed".

struct AppUpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// "x.y.z", each part 1 to 6 ASCII digits without a leading zero ("0" itself is fine); nil for anything else.
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.wholeNumber(part) else { return nil }
            numbers.append(number)
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// 1 to 6 ASCII digits, no leading zero unless it is the only digit.
    static func wholeNumber(_ part: Substring) -> Int? {
        guard (1...6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if part.count > 1, part.first == "0" { return nil }
        return Int(part)
    }
}

/// The oldest macOS a release runs on (its LSMinimumSystemVersion): "15", "15.0" or "15.4.1".
struct AppUpdateSystemVersion: Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = AppUpdateVersion.wholeNumber(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// Whether `system` is this version or newer.
    func isSatisfied(by system: OperatingSystemVersion) -> Bool {
        (system.majorVersion, system.minorVersion, system.patchVersion) >= (major, minor, patch)
    }
}
