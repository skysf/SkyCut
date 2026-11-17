import AppKit
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Exercises the actual clip planner and look with synthetic baked-in bars. The fixtures include
// thin asymmetric bars and two shots in one file; no detector substitute or private footage is used.
@MainActor enum BlackBarAppChecks {
    static func run(_ fixture: ParameterFixture, root: URL, ffmpeg: URL,
                    require: (Bool, String) -> Void) async throws {
        let source = root.appendingPathComponent("thin-bars.mp4")
        var info = try await MediaProbe.probe(url: source, ffmpeg: ffmpeg).get()
        info.keyframeInterval = 0
        var state = fixture.before
        state.mainClips[0].sourceURL = source
        state.mainClips[0].sourceDuration = 0.5
        state.mainClips[0].info = info
        fixture.reset(state)
        let before = try await look(file: source, fixture)
        let measured = before.payload["frames"]?.arrayValue?.first?["black_bars"]
        require(measured?["top"]?.doubleValue ?? 0 > 0.015 && measured?["bottom"]?.doubleValue ?? 0 > 0.02,
                "look must see both thin, asymmetric source bars")

        let result = try await fixture.edit(["remove_black_bars": true, "fit": "fill", "focus": "center"])
        let crop = fixture.project.state.mainClips[0].crop
        require((crop?.top ?? 0) >= 23.0 / 1080 && (crop?.bottom ?? 0) >= 31.0 / 1080,
                "automatic crop includes both complete bar boundaries, rather than leaving a low-resolution row")
        for edge in ["top", "bottom"] {
            let seen = measured?[edge]?.doubleValue ?? -1
            let used = result.payload["black_bars"]?[edge]?.doubleValue ?? -2
            require(abs(seen - used) <= 0.002, "look and removal agree on the same source's \(edge) bar")
        }
        let removed = try await look(file: nil, fixture)
        require(removed.payload["frames"]?.arrayValue?.first?["black_bars"] == nil,
                "one removal leaves no baked-in bars in the actual rendered timeline look")
        fixture.project.effectiveUndoManager!.undo()
        require(fixture.project.state == state && !fixture.project.effectiveUndoManager!.canUndo,
                "black-bar removal is exactly one undo step")

        fixture.reset(state)
        let notice = try await fixture.edit(["fit": "fill", "focus": "center"])
        require(notice.payload["black_bars"] != nil && notice.payload["warning"]?.stringValue?.contains("remove_black_bars") == true,
                "fill alone reports baked-in bars and explains how to remove them")
        require(fixture.project.state.mainClips[0].crop?.top ?? 0 < 23.0 / 1080,
                "the fill notice does not silently remove source bars")

        let shots = root.appendingPathComponent("changing-bars.mp4")
        var shotInfo = try await MediaProbe.probe(url: shots, ffmpeg: ffmpeg).get()
        shotInfo.keyframeInterval = 0
        state.mainClips[0].sourceURL = shots
        state.mainClips[0].sourceDuration = 1
        state.mainClips[0].info = shotInfo
        fixture.reset(state)
        let shotLook = try await look(file: shots, fixture)
        require(shotLook.payload["frames"]?.arrayValue?.first?["black_bars"] != nil,
                "the first shot has bars even though the second shot fills the source")
        let trimmed = try await fixture.edit(["source_out": 0.5, "remove_black_bars": true, "fit": "fill", "focus": "center"])
        require(trimmed.payload["black_bars"]?["top"]?.doubleValue ?? 0 > 0.09,
                "a simultaneous trim and removal samples the requested source window")
        let trimmedLook = try await look(file: nil, fixture)
        require(trimmedLook.payload["frames"]?.arrayValue?.first?["black_bars"] == nil,
                "a source-window edit removes the selected shot's bars in one call")
        fixture.project.effectiveUndoManager!.undo()
        require(fixture.project.state == state && !fixture.project.effectiveUndoManager!.canUndo,
                "source-window change and removal undo together")

        fixture.reset(state)
        let mixed = try await fixture.edit(["remove_black_bars": true, "fit": "fill", "focus": "center"])
        require(mixed.payload["black_bars"] == "none",
                "different shots keep the per-side minimum: removal must not crop the full-frame shot")
        fixture.reset()
    }

    private static func look(file: URL?, _ fixture: ParameterFixture) async throws -> AIToolResult {
        var fields: [String: JSONValue] = ["time": 0.25, "image": false]
        if let file { fields["file"] = .string(file.path) }
        return try await AILookTool.look(AIToolArguments(.object(fields)), fixture.project)
    }
}
