import Foundation

// MARK: - A DMG that downloaded whole and then failed: when an automatic check may fetch it again (pure)
//
// What it does: the one record, kept across launches in Updates/retry.json (AppUpdateFiles), of the DMG (by the feed's
// SHA-256) whose download completed and then failed its check (size, SHA-256) or its staging (the image, the copy, the
// verification): how many times in a row, and when last. An automatic check doesn't fetch that DMG again within 24 hours
// of its last failure, and never after the third, until the feed names another DMG. A check the person starts (the app
// menu or Settings) always fetches it, and a failure there counts too. A download that didn't complete (offline, a server
// error, stopped) says nothing about the DMG and isn't counted; any successful staging removes the record. Nothing is
// shown.
// What it doesn't: download (AppUpdatePipeline), keep the state (AppUpdateState), where the file lives (AppUpdateFiles).
// Rules: docs/architecture/app-updates.md "Downloading and verifying".

struct AppUpdateRetryRecord: Equatable, Sendable {
    static let schema = 1
    /// An automatic check leaves the DMG alone this long after its last failure.
    static let hold: TimeInterval = 24 * 60 * 60
    /// After this many failures in a row an automatic check never fetches it again.
    static let maxFailures = 3

    let dmgSHA256: String
    let failures: Int
    let lastFailure: Date

    /// The record after `feed`'s DMG failed at `now`: one more for the same DMG, the first for another.
    static func counting(_ record: Self?, failureOf feed: AppUpdateFeed, at now: Date) -> Self {
        guard let record, record.dmgSHA256 == feed.dmgSHA256 else {
            return Self(dmgSHA256: feed.dmgSHA256, failures: 1, lastFailure: now)
        }
        return Self(dmgSHA256: feed.dmgSHA256, failures: min(record.failures + 1, 999), lastFailure: now)
    }

    /// Whether an automatic check may fetch `feed`'s DMG at `now`: any other DMG, yes; this one a day after its last failure,
    /// and never after the third. A clock set back by more than a day doesn't hold it for ever.
    static func allowsAutomaticDownload(_ record: Self?, of feed: AppUpdateFeed, at now: Date) -> Bool {
        guard let record, record.dmgSHA256 == feed.dmgSHA256 else { return true }
        guard record.failures < maxFailures else { return false }
        return abs(now.timeIntervalSince(record.lastFailure)) >= hold
    }

    func data() throws -> Data {
        let object: [String: Any] = ["schema": Self.schema, "dmg_sha256": dmgSHA256, "failures": failures,
                                     "last_failure": lastFailure.timeIntervalSince1970]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }

    init(dmgSHA256: String, failures: Int, lastFailure: Date) {
        self.dmgSHA256 = dmgSHA256
        self.failures = failures
        self.lastFailure = lastFailure
    }

    /// Strict, like the feed: a file that isn't exactly right reads as none (an automatic check then fetches the DMG).
    init?(data: Data) {
        guard data.count <= 4096, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema"] as? NSNumber)?.intValue == Self.schema,
              let digest = object["dmg_sha256"] as? String, AppUpdateFeed.isSHA256(digest),
              let count = object["failures"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
              (1...999).contains(count.intValue), count.doubleValue == Double(count.intValue),
              let last = (object["last_failure"] as? NSNumber)?.doubleValue, last.isFinite else { return nil }
        self.init(dmgSHA256: digest, failures: count.intValue, lastFailure: Date(timeIntervalSince1970: last))
    }
}
