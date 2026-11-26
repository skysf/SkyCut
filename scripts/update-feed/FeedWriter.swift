import Foundation

// The feed writer's core (scripts/write-update-feed.sh): composes the update feed from the release's values with the app's
// own code (AppUpdateFeed.jsonObject), parses the result back with the app's own strict parser (AppUpdateFeed.parse, as a
// production feed: https on downloads.skylu.ai), and writes the file only when every field reads back the same and the
// notes have zh-Hans, en and es. Anything the app would refuse is refused here, before it is published. With a test feed's
// own address (the two-build test), it parses as the app does with that test hook: the DMG may then come from that origin.
// Usage: feed-writer <out.json> <version> <build> <minimum macOS> <dmg url> <dmg size> <dmg sha256> <notes.json> [test feed url]

@main
struct FeedWriter {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 9 || arguments.count == 10, let size = Int64(arguments[6]) else {
            fail("usage: feed-writer <out.json> <version> <build> <minimum macOS> <dmg url> <dmg size> <dmg sha256> <notes.json> [test feed url]")
        }
        let source = arguments.count == 10 ? AppUpdateFeed.Source.resolve(override: arguments[9]) : .production
        if arguments.count == 10, !source.isTestHook { fail("not a test feed address SkyCut accepts: \(arguments[9])") }
        let out = URL(fileURLWithPath: arguments[1])
        let (version, build, minimum, url, sha) = (arguments[2], arguments[3], arguments[4], arguments[5], arguments[7])
        guard let notesData = FileManager.default.contents(atPath: arguments[8]),
              let notes = try? JSONSerialization.jsonObject(with: notesData) as? [String: Any] else {
            fail("the notes file is not a JSON object: \(arguments[8])")
        }
        guard Set(notes.keys) == ["zh-Hans", "en", "es"] else {
            fail("the notes must have exactly zh-Hans, en and es (got \(notes.keys.sorted()))")
        }
        let object: [String: Any] = [
            "schema": AppUpdateFeed.schema, "bundle_id": AppUpdateFeed.bundleIdentifier, "version": version, "build": build,
            "minimum_macos": minimum, "dmg_url": url, "dmg_size": size, "dmg_sha256": sha, "notes": notes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            fail("the feed could not be encoded")
        }
        guard let feed = AppUpdateFeed.parse(data, from: source) else {
            fail("SkyCut's parser refuses this feed (a field is malformed, the DMG isn't https on \(AppUpdateFeed.downloadHost), "
                 + "or a note is empty, too long or more than \(AppUpdateFeed.maxNotes) lines)")
        }
        let readBack = feed.version.description == version && feed.build == build && feed.dmgURL.absoluteString == url
            && feed.dmgSize == size && feed.dmgSHA256 == sha && AppUpdateSystemVersion(minimum) == feed.minimumSystem
            && ["zh-Hans", "en", "es"].allSatisfy { feed.notes[$0] == (notes[$0] as? [String])?.map { $0.trimmingCharacters(in: .whitespaces) } }
        guard readBack else { fail("the feed does not read back as written") }
        do {
            try data.write(to: out, options: .atomic)
        } catch {
            fail("could not write \(out.path): \(error.localizedDescription)")
        }
        print("feed: SkyCut \(feed.version) (build \(feed.build), macOS \(minimum)+), \(size) bytes, \(sha.prefix(12))…, notes in zh-Hans / en / es → \(out.path)")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("✗ write-update-feed: \(message)\n".utf8))
        exit(1)
    }
}
