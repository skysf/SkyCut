import Foundation
import SrtFlowMCPKit

// MARK: - Names published Sky Studio content uses still exist (MCP-62, SkyCut's half)
//
// Every name in checks/MCP/published-content-names.json is checked against this build's tools: the tool exists, each name
// belongs to it at any depth, each value is one of its options and in range. A SkyCut change that renames or removes a
// name a published style or card uses turns red in its own PR, offline, with no content in the repo. Before that, the
// rules themselves are run on a made-up vocabulary (each one catches what it should, lets through what it should) and the
// snapshot's shape rules on made-up snapshots. Rules: docs/architecture/ai-control-mcp.md section 4 item 32.

func runPublishedNamesChecks() {
    entryRuleChecks()
    snapshotShapeChecks()
    guard let data = FileManager.default.contents(atPath: PublishedNamesSnapshot.path), let file = try? JSONValue.decode(data) else {
        check(false, "\(PublishedNamesSnapshot.path) is JSON")
        return
    }
    let (snapshot, problems) = PublishedNamesSnapshot.read(file)
    check(problems.isEmpty, "\(PublishedNamesSnapshot.path) is a names-only snapshot: \(problems.joined(separator: "; "))")
    let live = ToolVocabulary.live()
    checkEqual(Set(live.tools.keys), Set(MCPToolName.allCases.map(\.rawValue)), "the live vocabulary has every tool")
    check(catalogKnownNames().isSubset(of: live.names), "the live vocabulary accepts every name SkyCut's own text checks accept")
    var count = 0
    for item in snapshot.items {
        for entry in item.names {
            count += 1
            let found = PublishedNameEntry.problems(entry, in: live)
            check(found.isEmpty, "published \(item.kind) \(item.id) \(item.version) uses `\(entry)`: \(found.joined(separator: "; ")). "
                + "Keep that name working, or republish the content without it first and refresh \(PublishedNamesSnapshot.path) "
                + "(docs/architecture/ai-control-mcp.md section 4 item 32)")
        }
    }
    let release = snapshot.release.map { "release \($0)" } ?? "nothing published yet (release null)"
    print("MCP published names: \(release), \(snapshot.items.count) items, \(count) names checked against the live tools.")
}

/// A made-up vocabulary with one of each kind of name the content gate knows.
private func sampleVocabulary() -> ToolVocabulary {
    let curvePoint: JSONValue = ["type": "object", "properties": ["time": ["type": "number", "minimum": 0], "db": ["type": "number"]]]
    let duration: JSONValue = ["anyOf": [["type": "number", "minimum": 0.1], ["type": "string", "enum": ["auto"]]]]
    let editClip: JSONValue = ["type": "object", "properties": [
        "clip_id": ["type": "string"], "volume_curve": ["type": "array", "items": curvePoint],
        "fade_in": ["type": "number", "minimum": 0, "maximum": 10], "muted": ["type": "boolean"],
        "fit": ["type": "string", "enum": ["fill", "fit"]], "tilt": ["type": "number", "enum": [-45, 0, 45]], "duration": duration
    ]]
    let effect: JSONValue = ["type": "object", "properties": ["preset": ["type": "string", "enum": ["whoosh", "impact"]]]]
    let clip: JSONValue = ["type": "object", "properties": ["file": ["type": "string"], "sound_effect": effect,
                                                             "hit_at": ["type": "number", "minimum": 0]]]
    let addClips: JSONValue = ["type": "object", "properties": ["clips": ["type": "array", "items": clip]]]
    let guide: JSONValue = ["type": "object", "properties": ["topic": ["type": "string"], "section": ["type": "string"]]]
    let shape: JSONValue = ["type": "object", "properties": ["width": ["type": "number"]]]
    return ToolVocabulary(
        tools: [("edit_clip", editClip, []), ("add_clips", addClips, []), ("skycut_guide", guide, []), ("set_shape", shape, ["length"])],
        anywhere: ["project"],
        topics: [("skycut_guide", ["overview", "fields"]), ("paid", ["overview", "spending"])],
        resultFields: ["music_credits"])
}

/// Each rule on its own: what content may write passes, each kind of wrong name is caught with its reason.
private func entryRuleChecks() {
    let vocabulary = sampleVocabulary()
    let good = [
        "edit_clip volume_curve", "edit_clip clip_id muted=true", "add_clips sound_effect.preset=impact hit_at=<cut>",
        "add_clips clips.sound_effect.preset=whoosh|impact", "edit_clip fade_in=0.5–2", "edit_clip fade_in=10", "edit_clip tilt=45",
        "edit_clip duration=auto", "edit_clip duration=3", "set_shape length=120", "edit_clip project=p1",
        #"edit_clip volume_curve=[{"time":0,"db":-6}]"#, "skycut_guide topic=paid section=spending", "music_credits",
        "fill", "V1 A2 master", "0.5–2", "#FF00AA", "<cut>", "edit_clip", "new_video"
    ]
    for entry in good {
        let found = PublishedNameEntry.problems(entry, in: vocabulary)
        check(found.isEmpty, "the entry rules let `\(entry)` through (got \(found))")
    }
    let bad: [(entry: String, reason: String)] = [
        ("no_such_tool clip_id", "no_such_tool is not a SkyCut tool"),
        ("edit_clip no_such_param", "edit_clip has no parameter no_such_param"),
        ("edit_clip volume_curve.nope", "edit_clip has no parameter volume_curve.nope"),
        ("add_clips sound_effect.preset=boom", "not one of its options (whoosh | impact)"),
        ("edit_clip fade_in=11", "11 is above the maximum 10"),
        ("edit_clip fade_in=-1", "-1 is below the minimum 0"),
        ("edit_clip fade_in=0.5–12", "is above the maximum 10"),
        ("edit_clip fade_in=abc", "must be a number"),
        ("edit_clip muted=maybe", "only true or false"),
        ("edit_clip tilt=30", "not one of its options (-45 | 0 | 45)"),
        ("edit_clip duration=0.05", "below the minimum 0.1"),
        ("edit_clip fit=fill|", "an empty option"),
        ("edit_clip =3", "=3 is not a name or name=value"),
        ("skycut_guide topic=nope", "the guide has no topic nope"),
        ("skycut_guide topic=paid section=nope", "guide topic paid has no section nope"),
        ("fade_in=1", "name=value must follow a tool name"),
        ("the music", "the is not a SkyCut tool"),
        ("15 dB", "dB is not a SkyCut tool")
    ]
    for (entry, reason) in bad {
        let found = PublishedNameEntry.problems(entry, in: vocabulary)
        check(found.contains { $0.contains(reason) }, "the entry rules catch `\(entry)` (\(reason)); got \(found)")
    }
}

/// Made-up snapshots: the real file's shape rules refuse each kind of wrong shape, and prose with it.
private func snapshotShapeChecks() {
    let item: JSONValue = ["kind": "card", "id": "512", "version": "3", "names": ["edit_clip volume_curve", "volume_db_at"]]
    func snapshot(_ release: JSONValue, _ items: [JSONValue], extra: [String: JSONValue] = [:]) -> JSONValue {
        var top: [String: JSONValue] = ["format": .string(PublishedNamesSnapshot.format), "release": release, "items": .array(items)]
        top.merge(extra) { _, new in new }
        return .object(top)
    }
    let empty = PublishedNamesSnapshot.read(snapshot(.null, []))
    check(empty.problems.isEmpty && empty.snapshot.release == nil, "nothing published yet: release null, no items")
    let one = PublishedNamesSnapshot.read(snapshot(3, [item], extra: ["published_at": "2026-11-21T10:00:00Z"]))
    check(one.problems.isEmpty && one.snapshot.release == 3 && one.snapshot.items.first?.names.count == 2, "a published release reads")
    func withItem(_ change: [String: JSONValue]) -> JSONValue {
        var object = item.objectValue ?? [:]
        object.merge(change) { _, new in new }
        return snapshot(1, [.object(object)])
    }
    let cases: [(file: JSONValue, reason: String)] = [
        (.array([]), "not a JSON object"),
        (snapshot(.null, [], extra: ["format": "skycut-published-names/2"]), "format is not"),
        (snapshot(.null, [item]), "only published content belongs here"),
        (snapshot(0, [item]), "a release number from 1"),
        (snapshot("1", [item]), "a release number from 1"),
        (snapshot(1, [item], extra: ["notes": "the trailer now lands hits on the cut"]), "keys a names-only snapshot doesn't have: notes"),
        (withItem(["kind": "recipe"]), "kind recipe is not one of"),
        (withItem(["id": "Film Trailer"]), "id Film Trailer is not a content id"),
        (withItem(["version": ""]), "is not a version"),
        (withItem(["text": "## In SkyCut"]), "instead of exactly kind, id, version, names"),
        (withItem(["names": ["edit_clip\nvolume_curve"]]), "is not one code span or name"),
        (withItem(["names": ["`edit_clip`"]]), "is not one code span or name"),
        (withItem(["names": .string(String(repeating: "x", count: 10))]), "names is a list"),
        (withItem(["names": [.string(String(repeating: "word ", count: 50))]]), "is not one code span or name"),
        (snapshot(1, [item, item]), "card 512 is listed twice")
    ]
    for (file, reason) in cases {
        let problems = PublishedNamesSnapshot.read(file).problems
        check(problems.contains { $0.contains(reason) }, "a snapshot with a wrong shape is refused (\(reason)); got \(problems)")
    }
}
