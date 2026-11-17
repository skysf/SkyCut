import Foundation

// The explicit ending is real project data: lenient old-file defaults, protected format,
// round-trip persistence and selected-export isolation. No renderer or private media is used here.
enum ProjectDurationChecks {
    static func run(in root: URL) throws {
        let decoder = VideoEditProjectIO.makeDecoder()
        let empty = try decoder.decode(TimelineState.self, from: Data("{}".utf8))
        check(empty.minimumDuration == 0 && empty.duration == 0 && empty.isEmpty,
              "old projects without an explicit ending retain their empty state")
        let negative = try decoder.decode(TimelineState.self, from: Data("{\"minimumDuration\":-3}".utf8))
        checkEqual(negative.minimumDuration, 0, "invalid negative saved endings fall back to following content")

        let media = root.appendingPathComponent("ending-source.mp4")
        try Data(repeating: 7, count: 128).write(to: media)
        var state = TimelineState()
        state.mainClips = [EditClip(sourceURL: media, sourceDuration: 139.08)]
        check(!state.requiresFormatVersion36, "following content adds no v36 ending data")
        state.minimumDuration = 141
        check(state.duration == 141 && !state.isEmpty && state.requiresFormatVersion36,
              "an explicit ending keeps the project through 141 seconds without a placeholder")
        let destination = root.appendingPathComponent("explicit-ending.skycut")
        try VideoEditProjectIO.save(state, to: destination)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        checkEqual(raw["formatVersion"] as? Int, 36, "the explicit ending is protected from older writers by v36")
        checkEqual((raw["timeline"] as? [String: Any])?["minimumDuration"] as? Double, 141,
                   "the explicit ending is stored in the timeline")
        let restored = try VideoEditProjectIO.load(from: destination).timeline
        check(restored.minimumDuration == 141 && restored.duration == 141, "save/open retains the black ending")

        let selected = TimelineExportSelection.subset(of: state, ids: [state.mainClips[0].id])
        check(selected.minimumDuration == 0 && abs(selected.duration - 139.08) < 1e-9,
              "selected-only exports follow the selected content without the project-wide ending")
        var extended = state
        extended.mainClips[0].sourceDuration = 142
        checkEqual(extended.duration, 142, "later content may extend beyond the retained minimum")
        extended.mainClips.removeAll()
        check(extended.duration == 141 && !extended.isEmpty, "a pure black project with an explicit ending is not discarded as empty")
        state.minimumDuration = 0
        let encoded = try VideoEditProjectIO.makeEncoder().encode(state)
        let cleared = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        check(cleared["minimumDuration"] == nil && state.duration == 139.08,
              "clearing the ending removes its optional key and follows content again")

        // Keep this an external version truth, rather than comparing the writer's constant to itself.
        let future = root.appendingPathComponent("v37.skycut")
        try Data("{\"formatVersion\":37,\"timeline\":{},\"media\":[]}".utf8).write(to: future)
        check((try? VideoEditProjectIO.load(from: future)) == nil, "the reader rejects the next unsupported format v37")
    }
}
