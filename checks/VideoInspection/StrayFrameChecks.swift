import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 夹帧提醒和成片逐帧扫走真文件、真工具（docs/architecture/stray-frames.md）。两个合成片由 scripts/check-video-inspection.sh 现做：
// - cuts-source.mp4：24 帧每秒、8 秒，第 129 帧（5.375 秒）从会动的测试图切到彩条（照南极第二稿保温箱那一条的帧号）；
// - scan-film.mp4：会动的测试图里夹 2 帧彩条（3.0 秒）、9 帧闪白（5.0 秒）、7 秒不动的彩条（6.375 秒起）、1 秒黑（13.375 秒起），
//   带一条正弦音（没有声音的文件，成片检查的声音那一半读不了）。
@MainActor
enum StrayFrameChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let source = root.appendingPathComponent("cuts-source.mp4")
        let scanned = try await AIShotScan.result(for: source, waiting: 60)
        require(scanned.map { AIShotDetector.hardCuts(changes: $0.signals.changes) } == [129],
                "the real decoder path finds exactly the cut at frame 129 and no cut inside the moving test picture")
        if let changes = scanned?.signals.changes { margins("cuts-source.mp4", changes) }
        try await placing(project, source: source, require: require)
        try await film(project, root: root, require: require)
        if let changes = AIShotScan.cached(root.appendingPathComponent("scan-film.mp4"))?.signals.changes { margins("scan-film.mp4", changes) }
    }

    /// 打印合成片上刀和别的帧各自的变化、倍数（门槛的余量写进 docs/architecture/stray-frames.md）。
    private static func margins(_ name: String, _ changes: [Double]) {
        let cuts = Set(AIShotDetector.hardCuts(changes: changes))
        let frames = changes.indices.dropFirst()
        let cut = frames.filter(cuts.contains), other = frames.filter { !cuts.contains($0) }
        func text(_ values: [Double]) -> String { values.map { String(format: "%.1f", $0) }.joined(separator: "/") }
        let cutChange = text([cut.map { changes[$0] * 255 }.min() ?? 0]), cutRatio = text([cut.map { AIShotDetector.cutRatio(changes, at: $0) }.min() ?? 0])
        let otherChange = text([other.map { changes[$0] * 255 }.max() ?? 0])
        let otherRatio = text([other.map { AIShotDetector.cutRatio(changes, at: $0) }.max() ?? 0])
        print("MEASURED \(name): \(cut.count) cuts, smallest change \(cutChange)/255 ratio \(cutRatio); other frames largest change \(otherChange)/255 ratio \(otherRatio)")
    }

    // MARK: 放素材、改入点出点

    private static func placing(_ project: VideoEditProject, source: URL, require: (Bool, String) -> Void) async throws {
        project.restoreTimeline(TimelineState())
        let added = try await AITimelineTools.addClips(AIToolArguments([
            "clips": [["file": .string(source.path), "source_in": 1.95, "source_out": 5.45]]
        ]), project)
        let state = project.state
        guard let clip = state.mainClips.first else { return require(false, "add_clips placed the clip") }
        let ids = AIShortIDs(state: state)
        let cuts = added.payload["source_cuts"]?.arrayValue ?? []
        require(cuts.count == 1 && cuts.first?["clip"]?.stringValue == ids.short(clip.id) && cuts.first?["source_frame"] == 129
                    && cuts.first?["frames_after_cut"] == 2 && cuts.first?["suggested_source_out"] == 5.375
                    && cuts.first?["at"]?.doubleValue.map { abs($0 - 3.425) < 0.001 } == true,
                "add_clips reminds about the 2 frames past the file's own cut, with where and what to change: \(cuts)")
        require(abs(clip.sourceStart - 1.95) < 1e-9 && abs(clip.sourceStart + clip.sourceDuration - 5.45) < 1e-9,
                "the reminder changes nothing: the clip keeps the asked window")
        let early = try await AITimelineTools.addClips(AIToolArguments([
            "clips": [["file": .string(source.path), "source_in": .number(1.95 - 2.0 / 24), "source_out": .number(5.45 - 2.0 / 24)]]
        ]), project)
        require(early.payload["source_cuts"] == nil && early.payload["source_cuts_unchecked"] == nil,
                "two frames earlier there is nothing to remind")
        let id = JSONValue.string(ids.short(clip.id))
        let trimmed = try AIClipTools.apply(try await AIClipTools.plan(AIToolArguments(["clip_id": id, "source_out": 5.3]), project), project)
        require(trimmed.payload["source_cuts"] == nil, "edit_clip with an out point before the cut reminds nothing")
        let crossing = try AIClipTools.apply(try await AIClipTools.plan(AIToolArguments(["clip_id": id, "source_out": 5.45]), project), project)
        require(crossing.payload["source_cuts"]?.arrayValue?.first?["suggested_source_out"] == 5.375,
                "edit_clip that moves the out point past the cut reminds again")
        let opacity = try AIClipTools.apply(try await AIClipTools.plan(AIToolArguments(["clip_id": id, "opacity": 0.8]), project), project)
        require(opacity.payload["source_cuts"] == nil, "edits that do not move the source window do not repeat the reminder")

        // 交片前再查一遍（时间线快照，没有 file）：同一段报 source_cut，位置是夹进来的那 2 帧。
        let detail = try await inspect(project, ["image": false])
        let found = detail["findings"]?.arrayValue?.filter { $0["kind"] == "source_cut" } ?? []
        require(found.count == 1 && found.first?["items"]?.arrayValue?.first?.stringValue == ids.short(clip.id)
                    && found.first?["from"]?.doubleValue.map { abs($0 - 3.425) < 0.001 } == true
                    && found.first?["suggested_source_out"] == 5.375,
                "inspect_video reports the clip's stray frames again before delivery: \(found)")
        require(detail["frame_scan"] == nil, "without file there is no frame-by-frame scan")
    }

    // MARK: 成片逐帧扫

    private static func film(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let film = root.appendingPathComponent("scan-film.mp4")
        // 文件做出来是一分钟以前（不赌这台机器跑到这儿用了几秒）。
        let earlier = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.creationDate: earlier, .modificationDate: earlier], ofItemAtPath: film.path)
        guard let info = await project.mediaProbes.probeVideo(film) else { return require(false, "scan film is readable") }
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = [EditClip(sourceURL: film, sourceDuration: info.duration, timelineStart: 0, info: info)]
        // 工程存过盘、又改过（换上这条时间线）：文件比工程旧 —— 结果开头先说一句（MCP-65）。
        _ = project.saveDocument(as: root.appendingPathComponent("stray-check.skycut"))
        project.restoreTimeline(state)
        let started = try await AIInspectionTool.start(AIToolArguments(["file": .string(film.path), "image": false]), project)
        require(started.payload["attention"]?.stringValue?.contains("not the current cut") == true,
                "a file made before the project's last change says so first: \(started.payload)")
        let job = AIJobs.shared.job(started.payload["job_id"]!.stringValue!)!
        await AIJobs.shared.wait(for: job, seconds: 30)
        if job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
        let detail = AIJobs.shared.json(job)
        require(job.status == .done && detail["attention"] != nil && detail.encodedString().hasPrefix("{\"attention\""),
                "the stale-file note is the first thing in the finished result: \(job.message ?? "")")
        let findings = detail["findings"]?.arrayValue ?? []
        func spans(_ kind: String) -> [(Double, Double)] {
            findings.filter { $0["kind"]?.stringValue == kind }.compactMap { finding in
                finding["from"]?.doubleValue.flatMap { from in finding["to"]?.doubleValue.map { (from, $0) } }
            }
        }
        func near(_ spans: [(Double, Double)], _ from: Double, _ to: Double) -> Bool {
            spans.count == 1 && abs(spans[0].0 - from) < 0.05 && abs(spans[0].1 - to) < 0.05
        }
        require(near(spans("stray_frames"), 3.0, 3.083), "2 inserted frames are found frame-accurately: \(spans("stray_frames"))")
        require(near(spans("flash"), 5.0, 5.375), "a 9-frame white flash is found: \(spans("flash"))")
        require(near(spans("frozen_picture"), 6.375, 13.375), "7 seconds without movement are found: \(spans("frozen_picture"))")
        require(near(spans("black_frame"), 13.375, 14.375), "one second of black is one finding, from the frame scan: \(spans("black_frame"))")
        require(near(spans("source_cut"), 3.0, 3.083), "the timeline clip's own file shows the same 2 frames: \(spans("source_cut"))")
        require(detail["frame_scan"]?["frames"] == 393, "every frame of the file was scanned: \(detail["frame_scan"] ?? "nil")")

        // 点名一段：只报这一段里的。
        let ranged = try await inspect(project, ["file": .string(film.path), "from": 2, "to": 4, "image": false])
        let kinds = Set(ranged["findings"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? [])
        require(kinds.contains("stray_frames") && kinds.isDisjoint(with: ["flash", "frozen_picture", "black_frame"]),
                "a named range keeps only the frame findings inside it: \(kinds)")

        // 没给 file：抽帧的黑场连着的合成一条（MCP-14 B）。
        let sampled = try await inspect(project, ["image": false])
        let black = sampled["findings"]?.arrayValue?.filter { $0["kind"] == "black_frame" } ?? []
        require(black.count == 1 && (black.first?["to"]?.doubleValue ?? 0) > (black.first?["from"]?.doubleValue ?? 0),
                "consecutive black samples are one finding with its length: \(black)")

        // 存好盘以后再导出（拷一份新文件）：文件比工程新，不说。
        _ = project.flushAutosave()
        let fresh = root.appendingPathComponent("scan-film-again.mp4")
        try? FileManager.default.removeItem(at: fresh)
        // 新写一个文件（拷贝会连创建时间一起拷过去，不像导出）。
        try Data(contentsOf: film).write(to: fresh)
        let again = try await AIInspectionTool.start(AIToolArguments(["file": .string(fresh.path), "image": false]), project)
        require(again.payload["attention"] == nil, "a file made after the last save is not called stale: \(again.payload)")
        if let id = again.payload["job_id"]?.stringValue, let running = AIJobs.shared.job(id) {
            AIJobs.shared.cancel(running)
            await AIJobs.shared.wait(for: running, seconds: 30)
        }
    }

    private static func inspect(_ project: VideoEditProject, _ args: [String: JSONValue]) async throws -> JSONValue {
        let started = try await AIInspectionTool.start(AIToolArguments(.object(args)), project)
        let job = AIJobs.shared.job(started.payload["job_id"]!.stringValue!)!
        await AIJobs.shared.wait(for: job, seconds: 30)
        if job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
        return AIJobs.shared.json(job)
    }
}
