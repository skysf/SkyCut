import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Production checks for an explicit black ending and bounded edit_clips replies.
// Uses the existing isolated project and real commit/undo paths; never opens the installed app.
@MainActor enum EditingFeedbackChecks {
    static func run(_ f: ParameterFixture, root: URL, ffmpeg: URL, require: (Bool, String) -> Void) async throws {
        try ending(f, root: root, require: require)
        try await compactBatch(f, require: require)
        try await renderedEnding(f, root: root, ffmpeg: ffmpeg, require: require)
        try await emptyEnding(f, root: root, ffmpeg: ffmpeg, require: require)
    }

    private static func ending(_ f: ParameterFixture, root: URL, require: (Bool, String) -> Void) throws {
        f.reset()
        let before = f.project.state
        let args: JSONValue = ["duration": 141]
        require(MCPArgumentCheck.problem(tool: .setCanvas, arguments: args) == nil, "set_canvas discovers an explicit duration")
        do {
            let reply = try AIOverlayTools.setCanvas(AIToolArguments(args), f.project)
            require(reply.changedProject && reply.payload["duration"] == 141, "set_canvas reports the requested 141-second ending")
            require(f.project.state.duration == 141 && f.project.state.mainClips == before.mainClips
                    && f.project.state.shapes.isEmpty, "141-second ending needs no placeholder or clip changes")
            let held = f.project.state
            require(AudioEngineConfig.make(from: held, measuringSceneCompensation: false).duration == 141,
                    "the audio clock and offline renderer receive the same retained ending")
            require(!held.differsOnlyInAudioMix(from: before), "an ending edit rebuilds the preview instead of taking the audio-only fast path")
            require(ProjectVersionFiles.canonical(held) != ProjectVersionFiles.canonical(before),
                    "saved-version comparisons preserve the explicit ending")
            let path = root.appendingPathComponent("black-ending.skycut")
            _ = try VideoEditProjectIO.save(held, to: path)
            let loaded = try VideoEditProjectIO.load(from: path)
            require(loaded.timeline.duration == 141, "explicit ending survives the real project writer and reader")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == before && !f.project.effectiveUndoManager!.canUndo, "one undo removes the ending")
            f.project.effectiveUndoManager!.redo()
            require(f.project.state == held, "one redo restores the ending")
            f.project.effectiveUndoManager!.removeAllActions()
            let repeated = try AIOverlayTools.setCanvas(AIToolArguments(args), f.project)
            require(!repeated.changedProject && !f.project.effectiveUndoManager!.canUndo, "repeating duration creates no empty undo step")
            let canvasGeneration = f.project.canvasEditGeneration
            let repeatedRatio = try AIOverlayTools.setCanvas(AIToolArguments(["ratio": "auto"]), f.project)
            require(!repeatedRatio.changedProject && !f.project.effectiveUndoManager!.canUndo
                    && f.project.canvasEditGeneration == canvasGeneration + 1,
                    "a repeated ratio preserves recording-import intent without an empty undo group")
            for raw: JSONValue in [["duration": -1, "ratio": "9:16"], ["duration": 0.25, "fps": 30]] {
                do {
                    _ = try AIOverlayTools.setCanvas(AIToolArguments(raw), f.project)
                    require(false, "invalid ending must reject the entire canvas change")
                } catch {
                    require(f.project.state == held && !f.project.effectiveUndoManager!.canUndo,
                            "invalid ending preserves ratio, fps, content and undo history")
                }
            }
            _ = try AIOverlayTools.setCanvas(AIToolArguments(["duration": 0]), f.project)
            require(f.project.state.duration == before.duration, "duration zero clears the explicit ending")
            f.project.effectiveUndoManager!.removeAllActions()
            let cleared = f.project.state
            _ = try AIOverlayTools.setCanvas(AIToolArguments(["ratio": "9:16", "fps": 30, "duration": 141]), f.project)
            require(f.project.state.canvasRatio == .tall9x16 && f.project.state.frameRate.fps == 30
                    && f.project.state.duration == 141, "one canvas call applies shape, rate and ending together")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == cleared && !f.project.effectiveUndoManager!.canUndo,
                    "one undo restores shape, rate and ending from the combined call")
        } catch {
            require(false, "explicit ending failed: \(error)")
        }
        f.reset()
    }

    private static func compactBatch(_ f: ParameterFixture, require: (Bool, String) -> Void) async throws {
        var state = f.before
        let source = state.mainClips[0]
        state.mainClips = (0..<76).map { index in
            EditClip(sourceURL: source.sourceURL, sourceDuration: 1, timelineStart: Double(index), info: source.info)
        }
        f.reset(state)
        let ids = AIShortIDs(state: state)
        let entries: [JSONValue] = state.mainClips.map { ["clip_id": .string(ids.short($0.id)), "opacity": 0.5] }
        let args: JSONValue = ["clips": .array(entries), "compact": true]
        require(MCPArgumentCheck.problem(tool: .editClips, arguments: args) == nil, "edit_clips discovers compact at the batch level")
        let plan = try await AIBatchEditTools.planClips(AIToolArguments(args), f.project)
        let reply = try AIBatchEditTools.applyClips(plan, f.project)
        let text = reply.payload.encodedString()
        print("Compact batch reply: \(text.utf16.count) characters for 76 entries")
        require(text.utf16.count < 2_000, "76 ordinary edits return fewer than 2,000 JSON characters")
        require(reply.payload["count"] == 76 && reply.payload["clips"]?.arrayValue?.compactMap(\.stringValue)
                == state.mainClips.map { ids.short($0.id) }, "compact reply keeps every id in input order")
        require(f.project.state.mainClips.allSatisfy { $0.opacity == 0.5 }, "compact mode changes only the reply, all edits land")
        f.project.effectiveUndoManager!.undo()
        require(f.project.state == state && !f.project.effectiveUndoManager!.canUndo, "one undo restores all 76 clips")
        let fullPlan = try await AIBatchEditTools.planClips(AIToolArguments(["clips": .array(entries)]), f.project)
        let fullReply = try AIBatchEditTools.applyClips(fullPlan, f.project)
        let fullLength = fullReply.payload.encodedString().utf16.count
        print("Detailed batch reply: \(fullLength) characters for the same 76 entries")
        require(fullLength > 2_000, "the compact bound exercises a batch whose original detailed reply is large")

        // A later entry can change what an earlier one reports; exceptions must describe final values.
        f.reset()
        let id = JSONValue.string(AIShortIDs(state: f.before).short(f.id))
        let clamped: JSONValue = ["compact": true, "clips": [["clip_id": id, "opacity": 2], ["clip_id": id, "opacity": 0.25]]]
        let adjusted = try AIBatchEditTools.applyClips(try await AIBatchEditTools.planClips(AIToolArguments(clamped), f.project), f.project)
        require(adjusted.payload["notices"]?.arrayValue?.first?["adjustments"]?.arrayValue?.first?["applied"] == 0.25,
                "compact mode retains clamps and final-value adjustments instead of claiming requested values")
        f.reset()
        let fillArgs: JSONValue = ["compact": true, "clips": [["clip_id": id, "fit": "FILL", "focus": "center", "rotation": 45]]]
        let filled = try AIBatchEditTools.applyClips(try await AIBatchEditTools.planClips(AIToolArguments(fillArgs), f.project), f.project)
        require(filled.payload["notices"]?.arrayValue?.first?["picture"]?["fills_frame"] == false,
                "compact mode reports a requested fill whose retained rotation still uncovers corners")
        f.reset()
        do {
            _ = try await AIBatchEditTools.planClips(AIToolArguments(["compact": "invalid", "clips": [["clip_id": id, "start": 2]]]), f.project)
            require(false, "an invalid compact mode must fail before editing")
        } catch {
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo,
                    "invalid compact mode leaves the real project and undo history unchanged")
        }
        f.reset()
        let full: JSONValue = ["clips": [["clip_id": id, "opacity": 0.5]]]
        let detailed = try AIBatchEditTools.applyClips(try await AIBatchEditTools.planClips(AIToolArguments(full), f.project), f.project)
        require(detailed.payload["clips"]?.arrayValue?.first?["applied"]?["opacity"] == 0.5,
                "omitting compact preserves the detailed response contract")
        f.reset()
    }

    private static func renderedEnding(_ f: ParameterFixture, root: URL, ffmpeg: URL, require: (Bool, String) -> Void) async throws {
        f.reset()
        _ = try AIOverlayTools.setCanvas(AIToolArguments(["duration": 3]), f.project)
        require(f.project.state.duration == 3, "short rendered fixture holds two seconds after the clip")
        guard let built = await VideoEditCompositionBuilder.build(from: f.project.state) else {
            require(false, "black-ending production preview must build")
            return
        }
        require(abs(built.composition.duration.seconds - 3) < 0.01, "preview composition reaches the explicit ending")
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        let preview = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        require(try isBlack(preview), "preview renders the ending black")
        let plan = try await VideoEditExportGraph.plan(
            state: f.project.state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "ending-check"),
            subtitleFontURL: nil, output: root.appendingPathComponent("black-ending.mp4"), watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        try await FFmpegProcess().run(executable: ffmpeg, arguments: plan.arguments, workingDirectory: plan.workspace)
        let output = AVURLAsset(url: plan.tempOutput)
        let duration = try await output.load(.duration).seconds
        require(abs(duration - 3) < 1.0 / 24, "production export preserves the requested ending length")
        let frame = try await AVAssetImageGenerator(asset: output).image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        require(try isBlack(frame), "production export renders the ending black")
        f.reset()
    }

    private static func isBlack(_ image: CGImage) throws -> Bool {
        let color = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
                                      space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = context.data else { throw CocoaError(.coderInvalidValue) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        return (0..<(32 * 18)).allSatisfy { pixel in (0..<3).allSatisfy { bytes[pixel * 4 + $0] <= 5 } }
    }

    private static func emptyEnding(_ f: ParameterFixture, root: URL, ffmpeg: URL, require: (Bool, String) -> Void) async throws {
        f.reset(TimelineState())
        _ = try AIOverlayTools.setCanvas(AIToolArguments(["duration": 3]), f.project)
        let plan = try await VideoEditExportGraph.plan(
            state: f.project.state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "empty-ending"),
            subtitleFontURL: nil, output: root.appendingPathComponent("empty-ending.mp4"), watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        require(!plan.isAudioOnly && plan.totalDuration == 3, "a black-only project routes to a video export")
        try await FFmpegProcess().run(executable: ffmpeg, arguments: plan.arguments, workingDirectory: plan.workspace)
        let output = AVURLAsset(url: plan.tempOutput)
        require(abs(try await output.load(.duration).seconds - 3) < f.project.state.frameRate.secondsPerFrame,
                "black-only video exports the requested duration without placeholder clips")
        let image = try await AVAssetImageGenerator(asset: output).image(at: CMTime(seconds: 2.5, preferredTimescale: 600)).image
        require(try isBlack(image), "black-only video contains real black frames")

        // A malformed/manual file shorter than the segment gap tolerance must still produce a segment, not trap.
        var tiny = TimelineState()
        tiny.minimumDuration = 0.005
        let tinyPlan = try await VideoEditExportGraph.plan(
            state: tiny, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "tiny-ending"),
            subtitleFontURL: nil, output: root.appendingPathComponent("tiny-ending.mp4"), watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: tinyPlan.workspace) }
        require(tinyPlan.totalDuration == 0.005 && !tinyPlan.isAudioOnly,
                "a tiny persisted black ending makes a valid plan instead of indexing an empty segment list")
        var muted = f.before
        var sound = muted.mainClips.removeFirst()
        sound.isAudioOnly = true
        sound.isMuted = true
        muted.audioTracks = [EditLane(clips: [sound])]
        muted.minimumDuration = 3
        require(VideoEditExportGraph.isAudioOnly(muted), "muted audio with an ending keeps the existing audio-only route")
        do {
            _ = try await VideoEditExportGraph.plan(
                state: muted, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "muted-ending"),
                subtitleFontURL: nil, output: root.appendingPathComponent("muted-ending.m4a"), watermark: nil
            )
            require(false, "the existing no-audible-content refusal must not become video in an audio-only output")
        } catch is VideoEditExportGraph.PlanError {
            require(true, "muted-only audio retains its existing refusal instead of silently changing formats")
        }
        f.reset()
    }
}
