import AppKit
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 完整 App 对象验收：短 / 长音频，V1 / V2 / 文字 / 形状 / 原稿字幕，原生定格和一次撤销。
@main enum VoiceoverSyncChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.voiceoversynccheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Isolated check bundle required") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_VOICE_SYNC_CHECK_DIR"]!).standardizedFileURL.resolvingSymlinksInPath()
        let video = root.appendingPathComponent("source.mp4")
        var count = 0
        var failures = 0
        func require(_ value: Bool, _ message: String) {
            count += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        do {
            // 真正初始化现有视频引擎，用于复用末帧抽取和静帧转码。
            MediaToolchain.shared.resolveIfNeeded()
            for _ in 0..<100 where MediaToolchain.shared.runtime == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            require(MediaToolchain.shared.runtime != nil, "native video engine is required, never skip freeze acceptance")
            for lengths in [[4.0, 6.0], [12.0, 15.0]] {
                let f = try VoiceoverSyncFixture(folder: root.appendingPathComponent("speed-\(Int(lengths[0]))"), video: video, lengths: lengths)
                let generation = rebuildGeneration(f.project)
                let result = try await f.run()
                require(result["status"] == "done", "short/long narration must complete: \(result)")
                let state = f.project.state
                require(f.calls == 2, "each new paragraph uses fresh audio word times")
                require(result["paragraphs"]?.arrayValue?[1]["start"] == .number(10 + lengths[0]), "later paragraph follows actual first audio, not cached metadata")
                require(rebuildGeneration(f.project) == generation + 1, "whole synchronization schedules exactly one preview rebuild")
                require(state.mainMagnet && f.project.linkageEnabled, "synchronization leaves Magnet and Linkage settings intact")
                for i in 0..<2 {
                    let start = 10 + (i == 0 ? 0 : lengths[0])
                    let clip = state.clip(with: f.videos[i])!
                    let old = f.before.clip(with: clip.id)!
                    require(close(clip.timelineStart, start) && close(clip.timelineEnd, start + lengths[i]), "picture boundaries match narration without extra magnet/linkage")
                    require(close(clip.speed, 10 / lengths[i]), "picture uses existing speed editor")
                    require(clip.opacity == old.opacity && clip.crop == old.crop && clip.placement == old.placement
                            && clip.rotationDegrees == old.rotationDegrees && clip.flippedHorizontally == old.flippedHorizontally,
                            "picture framing and appearance survive")
                    let upper = state.clip(with: f.upper[i])!
                    require(close(upper.timelineStart, start + lengths[i] * 0.2) && state.location(of: upper.id)?.track == .overlay(0), "upper picture keeps its track and proportional paragraph position")
                    let title = state.textOverlays.first { $0.id == f.texts[i] }!
                    let oldTitle = f.before.textOverlays[i]
                    require(close(title.timelineStart, start + lengths[i] * 0.1) && close(title.duration, lengths[i] * 0.5)
                            && title.style == oldTitle.style && title.row == oldTitle.row, "title timing changes, style and row stay")
                    let shape = state.shapes.first { $0.id == f.shapes[i] }!
                    require(close(shape.timelineStart, start + lengths[i] * 0.2) && close(shape.duration, lengths[i] * 0.4)
                            && shape.kind == f.before.shapes[i].kind && shape.centerX == f.before.shapes[i].centerX,
                            "shape timing and geometry survive")
                    let a = state.subtitleCue(f.cues[i * 2])!
                    let b = state.subtitleCue(f.cues[i * 2 + 1])!
                    require(close(a.start, start + lengths[i] * 0.05) && close(a.end, start + lengths[i] * 0.3)
                            && close(b.start, start + lengths[i] * 0.75), "cue boundaries follow newly recognized speech, not old proportional time")
                    require(a.words?.count == 2 && b.words?.count == 1, "fresh word times replace old highlight times")
                    require(a.text == f.before.subtitleCue(a.id)!.text && b.text == f.before.subtitleCue(b.id)!.text, "original traditional Chinese is byte-for-byte preserved")
                    require(state.subtitleCompanion?.cueMeta[a.id]?.provenance?.clipID == f.voices[i], "cue source points to the new voice")
                    require(state.clip(with: f.oldVoices[i]) == nil && close(state.clip(with: f.voices[i])!.timelineStart, start), "old audio removal and new audio move are atomic")
                }
                require(state.shapes.last == f.before.shapes.last, "unmapped shape stays at its absolute position with Linkage on")
                require(state.mainClips.count == 2 && state.overlayTracks.count == 1 && state.shapes.map(\.id) == f.before.shapes.map(\.id), "no duplicate clips and original stacking order")
                f.project.effectiveUndoManager!.undo()
                require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "one undo restores every item, metadata, old audio and original timings")
                f.project.effectiveUndoManager!.redo()
                require(f.project.state == state, "one redo restores complete synchronized content")
                print("PASS: actual audio \(lengths), all layers, script, boundaries and one undo")
            }
            for (fit, lengths) in [("trim", [4.0, 6.0]), ("freeze", [12.0, 15.0])] {
                let f = try VoiceoverSyncFixture(folder: root.appendingPathComponent(fit), video: video, lengths: lengths, fit: fit)
                let result = try await f.run()
                require(result["status"] == "done", "\(fit) must complete through production preparation: \(result)")
                if fit == "trim" {
                    require(f.project.state.clip(with: f.videos[0])?.speed == 1 && f.project.state.clip(with: f.videos[0])?.sourceDuration == 4, "trim preserves speed and uses the source window")
                } else {
                    let frozen = f.project.state.mainClips.filter(\.isStillImage)
                    require(frozen.count == 2 && frozen.allSatisfy { !$0.needsStillConversion && FileManager.default.fileExists(atPath: $0.stillImageURL!.path) }, "long narration uses two real, ready freeze assets")
                    require(frozen.map(\.sourceDuration) == [2, 5] && close(frozen.last!.timelineEnd, 37), "freeze tails fill the new paragraph ends")
                    require(frozen.allSatisfy { $0.opacity == 0.8 && $0.flippedHorizontally }, "freeze uses existing appearance snapshot")
                }
                let next = f.project.state
                f.project.effectiveUndoManager!.undo()
                require(f.project.state == f.before, "\(fit) undo restores the complete original project")
                f.project.effectiveUndoManager!.redo()
                require(f.project.state == next, "\(fit) redo restores assets and timings")
            }
            try await failuresAndStale(root: root, video: video, require: require)
        } catch {
            failures += 1
            print("FAIL: unexpected \((error as? AIToolError)?.message ?? error.localizedDescription)")
        }
        print("Voiceover sync: \(count) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func rebuildGeneration(_ project: VideoEditProject) -> Int {
        guard let value = Mirror(reflecting: project).children.first(where: { $0.label == "rebuildGeneration" })?.value as? Int else {
            fatalError("The preview counter could not be inspected; never skip the rebuild assertion")
        }
        return value
    }

    @MainActor static func failuresAndStale(root: URL, video: URL, require: (Bool, String) -> Void) async throws {
        let f = try VoiceoverSyncFixture(folder: root.appendingPathComponent("failure"), video: video, lengths: [4, 6])
        func rejected(_ args: AIToolArguments, _ why: String) {
            do { _ = try AIVoiceoverSyncTool(args, f.project, services: f.services); require(false, why) }
            catch { require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, why) }
        }
        var raw = f.args.raw.objectValue!
        var mappings = raw["paragraphs"]!.arrayValue!
        var second = mappings[1].objectValue!
        second["texts"] = .array([.string(f.texts[0].uuidString)])
        mappings[1] = .object(second); raw["paragraphs"] = .array(mappings)
        rejected(AIToolArguments(.object(raw)), "duplicate mapping must reject before any edit")
        raw = f.args.raw.objectValue!; mappings = raw["paragraphs"]!.arrayValue!; second = mappings[1].objectValue!
        second["from"] = 21; mappings[1] = .object(second); raw["paragraphs"] = .array(mappings)
        rejected(AIToolArguments(.object(raw)), "nonconsecutive old paragraphs reject")
        raw = f.args.raw.objectValue!; mappings = raw["paragraphs"]!.arrayValue!; second = mappings[1].objectValue!
        second["to"] = 25; mappings[1] = .object(second); raw["paragraphs"] = .array(mappings)
        rejected(AIToolArguments(.object(raw)), "cross-boundary objects reject")
        let rebuild = rebuildGeneration(f.project)
        f.badWords = true
        let alignment = try await f.run()
        require(alignment["status"] == "failed" && f.project.state == f.before && rebuildGeneration(f.project) == rebuild
                && !f.project.effectiveUndoManager!.canUndo, "alignment failure leaves no partial edit, undo or preview")
        f.badWords = false; f.cancelOnWords = true
        require(try await f.run()["status"] == "cancelled" && f.project.state == f.before, "local cancellation leaves original timeline intact")
        f.cancelOnWords = false
        let tool = try AIVoiceoverSyncTool(f.args, f.project, services: f.services)
        let plan = try await tool.prepare()
        f.project.perform { $0.mainClips[0].opacity = 0.33 }
        let userEdit = f.project.state
        do { _ = try tool.apply(plan); require(false, "stale prepared plan must reject") }
        catch { require(f.project.state == userEdit, "stale plan must not overwrite a user's intervening edit") }

        let during = try VoiceoverSyncFixture(folder: root.appendingPathComponent("during-alignment"), video: video, lengths: [4, 6])
        during.mutateOnWords = true
        let intervened = try await during.run()
        require(intervened["status"] == "failed" && during.project.state.mainClips[0].opacity == 0.4
                && during.oldVoices.allSatisfy { during.project.state.clip(with: $0) != nil },
                "edits during ASR abort synchronization and retain the user's change")
        let conflict = try VoiceoverSyncFixture(folder: root.appendingPathComponent("conflict"), video: video, lengths: [12, 15])
        var obstructed = conflict.before
        var blocker = EditClip(sourceURL: video, sourceDuration: 2, timelineStart: 31, info: conflict.before.mainClips[0].info)
        blocker.opacity = 0.5
        obstructed.mainClips.append(blocker)
        conflict.project.restoreTimeline(obstructed)
        conflict.project.effectiveUndoManager!.removeAllActions()
        let failure = try await conflict.run()
        require(failure["status"] == "failed" && conflict.project.state == obstructed
                && !conflict.project.effectiveUndoManager!.canUndo, "final overlap with an unmapped clip rejects the entire synchronization")
        let brokenFreeze = try VoiceoverSyncFixture(folder: root.appendingPathComponent("broken-freeze"), video: video,
                                                    lengths: [12, 15], fit: "freeze")
        var missing = brokenFreeze.before
        missing.update(brokenFreeze.videos[1]) { $0.sourceURL = root.appendingPathComponent("not-present.mp4") }
        brokenFreeze.project.restoreTimeline(missing)
        brokenFreeze.project.effectiveUndoManager!.removeAllActions()
        let freezeFailed = try await brokenFreeze.run()
        let images = try FileManager.default.contentsOfDirectory(at: brokenFreeze.project.documentURL!.deletingLastPathComponent(),
                                                                includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
        require(freezeFailed["status"] == "failed" && freezeFailed["failure_stage"] == "freeze_preparation"
                && brokenFreeze.project.state == missing && !brokenFreeze.project.effectiveUndoManager!.canUndo,
                "failure preparing the second freeze cannot insert the first half")
        require(images.isEmpty, "a later freeze failure cleans all newly prepared, unreferenced PNGs")
        let limit = try VoiceoverSyncFixture(folder: root.appendingPathComponent("limit"), video: video, lengths: [0.2, 6])
        let tooFast = try await limit.run()
        require(tooFast["status"] == "failed" && limit.project.state == limit.before, "required speed outside limits rejects before modification")
    }
}
