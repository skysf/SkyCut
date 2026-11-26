import Foundation

// scripts/check-app-update.sh: release versions and their order, the minimum macOS, the feed's strict parser (every field
// wrong on its own, unknown fields ignored, nothing newer or a newer macOS never offered), the test hook's address rules,
// where a DMG may come from, the notes' language fallback, and the two records on disk read back as written.

enum FeedChecks {
    static let sha = String(repeating: "ab", count: 32)
    static let url = "https://downloads.skylu.ai/skycut/SkyCut-0.19.0-abababababab-arm64.dmg"

    static func run(check: (Bool, String) -> Void) {
        print("==> versions and the feed")
        versions(check)
        parsing(check)
        sources(check)
        notesAndRecords(check)
    }

    static func feed(_ data: Data, _ source: AppUpdateFeed.Source = .production) -> AppUpdateFeed? {
        AppUpdateFeed.parse(data, from: source)
    }

    static func valid(version: String = "0.19.0", extra: [String: Any] = [:]) -> Data {
        UpdateFixture.feedJSON(version: version, url: url, size: 42_431_367, sha: sha, extra: extra)
    }

    private static func versions(_ check: (Bool, String) -> Void) {
        for good in ["0.18.69", "1.0.0", "0.0.0", "10.200.3000", "999999.0.1"] {
            check(AppUpdateVersion(good)?.description == good, "a release version: \(good)")
        }
        for bad in ["0.18", "0.18.69.1", "0.18.67-local.20261126.d3a6c971", "v0.18.69", "0.018.69", "0.18.69 ", "", "0..1",
                    "1.2.x", "1000000.0.0", "+1.2.3", "１.2.3"] {
            check(AppUpdateVersion(bad) == nil, "not a release version: \(bad.debugDescription)")
        }
        let v = { AppUpdateVersion($0)! }
        check(v("0.18.69") < v("0.18.70") && v("0.18.70") < v("0.19.0") && v("0.19.0") < v("1.0.0"), "versions order by number")
        check(v("0.18.100") > v("0.18.99"), "0.18.100 is newer than 0.18.99 (numbers, not text)")
        let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 1)
        check(AppUpdateSystemVersion("15.0")?.isSatisfied(by: system) == true, "macOS 15.4.1 runs a 15.0 release")
        check(AppUpdateSystemVersion("15")?.isSatisfied(by: system) == true, "a bare major version")
        check(AppUpdateSystemVersion("15.4.1")?.isSatisfied(by: system) == true, "the same macOS runs it")
        check(AppUpdateSystemVersion("15.4.2")?.isSatisfied(by: system) == false, "a newer patch is not satisfied")
        check(AppUpdateSystemVersion("26.0")?.isSatisfied(by: system) == false, "macOS 26 needed: not on 15.4.1")
        for bad in ["", "15.", "15.0.0.1", "fifteen"] {
            check(AppUpdateSystemVersion(bad) == nil, "not a macOS version: \(bad.debugDescription)")
        }
    }

    private static func parsing(_ check: (Bool, String) -> Void) {
        guard let parsed = feed(valid()) else { return check(false, "a valid feed parses") }
        check(parsed.version.description == "0.19.0" && parsed.build == "1" && parsed.dmgSize == 42_431_367
              && parsed.dmgSHA256 == sha && parsed.dmgURL.absoluteString == url && parsed.minimumSystem.description == "15.0.0",
              "every field read as written")
        check(feed(valid(extra: ["published_at": "2026-11-28", "channel": ["x": 1]])) == parsed, "unknown fields are ignored")
        let wrong: [(String, Any?)] = [
            ("schema", 2), ("schema", "1"), ("schema", true), ("schema", 1.5), ("schema", nil),
            ("bundle_id", "com.srtflow.SrtFlow.beta"), ("bundle_id", nil),
            ("version", "0.19"), ("version", "0.19.0-beta"), ("version", 19), ("version", nil),
            ("build", ""), ("build", "1a"), ("build", 1), ("build", "1.2.3.4"), ("build", nil),
            ("minimum_macos", "fifteen"), ("minimum_macos", nil),
            ("dmg_url", "http://downloads.skylu.ai/skycut/x.dmg"), ("dmg_url", "https://skylu.ai/download/skycut"),
            ("dmg_url", "https://downloads.skylu.ai/skycut/x.zip"), ("dmg_url", "https://evil.example/x.dmg"),
            ("dmg_url", "https://user:pw@downloads.skylu.ai/x.dmg"), ("dmg_url", "https://downloads.skylu.ai/x.dmg#frag"),
            ("dmg_url", "http://127.0.0.1:8000/x.dmg"), ("dmg_url", nil),
            ("dmg_size", 0), ("dmg_size", -5), ("dmg_size", 2_000_000_000), ("dmg_size", "42"), ("dmg_size", 4.5), ("dmg_size", nil),
            ("dmg_sha256", String(repeating: "AB", count: 32)), ("dmg_sha256", String(repeating: "a", count: 63)),
            ("dmg_sha256", String(repeating: "g", count: 64)), ("dmg_sha256", nil),
            ("notes", ["zh-Hans": ["只有中文"]]), ("notes", ["en": []]), ("notes", ["en": [""]]), ("notes", ["en": ["a\nb"]]),
            ("notes", ["en": Array(repeating: "x", count: 9)]), ("notes", ["en": [String(repeating: "x", count: 301)]]),
            ("notes", ["en": "one line"]), ("notes", ["e n": ["x"]]), ("notes", [String: Any]()), ("notes", nil),
        ]
        for (field, value) in wrong {
            var object = try! JSONSerialization.jsonObject(with: valid()) as! [String: Any]
            object[field] = value
            let data = try! JSONSerialization.data(withJSONObject: object)
            check(feed(data) == nil, "refused: \(field) = \(value.map { "\($0)" } ?? "missing")")
        }
        check(feed(Data("not json".utf8)) == nil, "not JSON: refused")
        check(feed(Data("[1,2]".utf8)) == nil, "a JSON array: refused")
        let padded = try! JSONSerialization.data(withJSONObject: [
            "schema": 1, "padding": String(repeating: "x", count: AppUpdateFeed.maxFeedBytes)])
        check(feed(padded) == nil, "a feed over 64 KB: refused")
        // What is offered.
        let running = AppUpdateVersion("0.18.69")!
        let system = ProcessInfo.processInfo.operatingSystemVersion
        check(parsed.isOffered(to: running, on: system), "a newer version on this macOS is offered")
        check(!parsed.isOffered(to: AppUpdateVersion("0.19.0")!, on: system), "the same version is never offered (no reinstall)")
        check(!parsed.isOffered(to: AppUpdateVersion("0.20.0")!, on: system), "an older version is never offered (no downgrade)")
        let future = feed(UpdateFixture.feedJSON(version: "0.19.0", minimum: "99.0", url: url, size: 1, sha: sha))
        check(future.map { !$0.isOffered(to: running, on: system) } == true, "a release needing a newer macOS is never offered")
    }

    private static func sources(_ check: (Bool, String) -> Void) {
        typealias Source = AppUpdateFeed.Source
        check(Source.resolve(override: nil) == .production, "no override: production")
        check(Source.production.feedURL.absoluteString == "https://skylu.ai/updates/skycut.json", "the production feed's address")
        for good in ["https://example.com/feed.json", "http://127.0.0.1:8123/skycut.json", "http://localhost:9/x.json",
                     "http://[::1]:8000/x.json", "  https://test.skylu.ai/updates/skycut.json  "] {
            check(Source.resolve(override: good).isTestHook, "accepted test hook: \(good)")
        }
        for bad in ["http://example.com/feed.json", "ftp://127.0.0.1/x", "file:///tmp/x.json", "not a url", "",
                    "https://user:pw@example.com/x.json", "http://192.168.1.2/x.json"] {
            check(Source.resolve(override: bad) == .production, "refused test hook falls back to production: \(bad.debugDescription)")
        }
        let loopback = Source.resolve(override: "http://127.0.0.1:8123/skycut.json")
        check(loopback.isLoopback && !Source.resolve(override: "https://example.com/f.json").isLoopback, "loopback test hooks are told apart")
        check(loopback.allowsDMG(URL(string: "http://127.0.0.1:8123/SkyCut-0.19.0.dmg")!), "the hook's own origin may serve the DMG")
        check(!loopback.allowsDMG(URL(string: "http://127.0.0.1:9999/SkyCut-0.19.0.dmg")!), "another port may not")
        check(loopback.allowsDMG(URL(string: url)!), "downloads.skylu.ai stays allowed with the hook")
        check(!Source.production.allowsDMG(URL(string: "http://127.0.0.1:8123/SkyCut-0.19.0.dmg")!), "production never takes loopback DMGs")
        let hooked = AppUpdateFeed.parse(UpdateFixture.feedJSON(version: "0.19.0", url: "http://127.0.0.1:8123/a.dmg", size: 1, sha: sha),
                                         from: loopback)
        check(hooked != nil, "a loopback feed naming its own DMG parses with the hook")
    }

    private static func notesAndRecords(_ check: (Bool, String) -> Void) {
        let notes = ["en": ["Hello"], "zh-Hans": ["你好"], "es": ["Hola"]]
        check(AppUpdateFeed.notes(notes, forLanguage: "zh-Hans") == ["你好"], "notes: the in-app language")
        check(AppUpdateFeed.notes(notes, forLanguage: "zh-hans") == ["你好"], "notes: letter case ignored (SwiftPM lowercases lproj names)")
        check(AppUpdateFeed.notes(notes, forLanguage: "zh-Hant") == ["你好"], "notes: the same language when the script differs")
        check(AppUpdateFeed.notes(notes, forLanguage: "es-MX") == ["Hola"], "notes: a regional variant")
        check(AppUpdateFeed.notes(notes, forLanguage: "fr") == ["Hello"], "notes: English when the language has none")
        guard let parsed = feed(valid()) else { return }
        let record = AppUpdateStagedRecord(feed: parsed, appPath: "/Users/x/Library/Application Support/SrtFlow/Updates/staged.noindex/0.19.0/SkyCut.app",
                                           asked: true)
        check((try? record.data()).flatMap(AppUpdateStagedRecord.init(data:)) == record, "the staged record reads back as written")
        check(AppUpdateStagedRecord(data: Data("{}".utf8)) == nil, "an empty staged record is none")
        let note = AppUpdateInstalledNote(from: AppUpdateVersion("0.18.69")!, to: AppUpdateVersion("0.19.0")!, notes: notes)
        check((try? note.data()).flatMap(AppUpdateInstalledNote.init(data:)) == note, "the installed marker reads back as written")
        let backwards = try! JSONSerialization.data(withJSONObject: ["schema": 1, "from": "0.19.0", "to": "0.18.69", "notes": notes])
        check(AppUpdateInstalledNote(data: backwards) == nil, "a marker that goes backwards is none")
        let now = Date()
        let reopen = AppUpdateReopenRecord(primary: "/Users/x/a.skycut", windows: ["/Users/x/b.skycut"], at: now)
        check(AppUpdateReopenRecord(dictionary: reopen.dictionary) == AppUpdateReopenRecord(primary: "/Users/x/a.skycut",
              windows: ["/Users/x/b.skycut"], at: Date(timeIntervalSince1970: now.timeIntervalSince1970)), "the reopen record reads back")
        check(reopen.isFresh(now: now.addingTimeInterval(120), freshness: 600), "reopen: a restart two minutes ago")
        check(!reopen.isFresh(now: now.addingTimeInterval(3600), freshness: 600), "reopen: an hour-old record is dropped")
        check(!reopen.isFresh(now: now.addingTimeInterval(-3600), freshness: 600), "reopen: a record from the future is dropped")
        check(AppUpdateReopenRecord(dictionary: ["windows": ["relative.skycut"], "at": 1.0]) == nil, "reopen: relative paths refused")
        retryRecord(check)
    }

    /// The retry record (U1) on disk: read back as written; anything not exactly right is none.
    private static func retryRecord(_ check: (Bool, String) -> Void) {
        let retry = AppUpdateRetryRecord(dmgSHA256: sha, failures: 2, lastFailure: Date(timeIntervalSince1970: 1_800_000_000))
        check((try? retry.data()).flatMap(AppUpdateRetryRecord.init(data:)) == retry, "the retry record reads back as written")
        let good: [String: Any] = ["schema": 1, "dmg_sha256": sha, "failures": 2, "last_failure": 1_800_000_000.0]
        let wrong: [(String, Any?)] = [("schema", 2), ("dmg_sha256", String(repeating: "AB", count: 32)), ("dmg_sha256", nil),
                                       ("failures", 0), ("failures", 1000), ("failures", true), ("failures", 1.5), ("failures", "2"),
                                       ("last_failure", "yesterday"), ("last_failure", nil)]
        for (field, value) in wrong {
            var object = good
            object[field] = value
            let data = try! JSONSerialization.data(withJSONObject: object)
            check(AppUpdateRetryRecord(data: data) == nil, "a retry record with \(field) = \(value.map { "\($0)" } ?? "missing") is none")
        }
    }
}
