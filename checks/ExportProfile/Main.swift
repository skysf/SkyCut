import AppKit
import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 生产子进程收尾、导出计时、设置、排队/取消与 PNG 解码计数；无用户工程、云端请求或硬件编码依赖。
@main enum ExportProfileChecks {
    @MainActor static func main() async {
        guard Bundle.main.bundleIdentifier == "com.srtflow.SrtFlow.exportprofilecheck" else { fatalError("Isolated bundle required") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_EXPORT_PROFILE_CHECK_DIR"]!)
        let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
        var count = 0, failures = 0
        func require(_ condition: Bool, _ why: String) { count += 1; if !condition { failures += 1; print("FAIL: \(why)") } }
        do {
            try await FFmpegProcessChecks.run(root: root, require: require)
            var base = VideoEncodeSettings.default
            base.crf = 21; base.hardwareQuality = 70; base.resolution = .fhd1080
            let unchanged = try AIExportOptions.parse(AIToolArguments([:]), base: base)
            require(unchanged.settings == base && unchanged.preset == "final", "formal defaults preserve every remembered setting")
            let hardware = try AIExportOptions.parse(AIToolArguments(["encoder": "hardware", "quality": "high"]), base: base)
            require(hardware.settings.encoder == .hardware && hardware.settings.hardwareQuality == 75 && hardware.settings.preset == base.preset,
                    "explicit hardware and quality reuse the existing mapping")
            let review = try AIExportOptions.parse(AIToolArguments(["preset": "quick_review"]), base: base)
            require(review.settings.encoder == .hardware && review.settings.hardwareQuality == 45 && review.settings.resolution == .hd720
                    && review.settings.audio.kbps == 128, "review has an explicit faster, smaller output contract")
            let override = try AIExportOptions.parse(AIToolArguments(["preset": "quick_review", "encoder": "software", "quality": "high", "resolution": "1080p"]), base: base)
            require(override.settings.encoder == .softwareCRF && override.settings.crf == 19 && override.settings.resolution == .fhd1080,
                    "explicit per-call overrides take priority over the review preset")
            do { _ = try AIExportOptions.parse(AIToolArguments(["encoder": "guess"]), base: base); require(false, "invalid encoder rejects") }
            catch { require(true, "invalid encoder rejects") }

            let clock = ExportTimings()
            clock.begin("queue")
            try await Task.sleep(nanoseconds: 30_000_000)
            clock.begin("preparation")
            try await Task.sleep(nanoseconds: 20_000_000)
            clock.finish()
            let frozen = clock.detail
            try await Task.sleep(nanoseconds: 10_000_000)
            require(clock.detail == frozen, "completed timing freezes instead of growing when polled")
            require(frozen["timings"]?["stages"]?["queue"]?.doubleValue ?? 0 >= 0.025, "queue is measured by an actual wait")

            let source = root.appendingPathComponent("source.mp4")
            MediaToolchain.shared.resolveIfNeeded()
            for _ in 0..<100 where MediaToolchain.shared.runtime == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            require(MediaToolchain.shared.runtime != nil, "native video engine is required")
            let info = try await MediaProbe.probe(url: source, ffmpeg: ffmpeg).get()
            var state = TimelineState()
            state.canvasRatio = .wide16x9
            state.mainClips = [EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 0, info: info)]
            state.shapes = [ShapeAnnotation(kind: .rectangle, timelineStart: 0.325, duration: 1.25)]
            let trace = ExportTimings()
            let plan = try await VideoEditExportGraph.plan(state: state, settings: .default, subtitleStyle: .default,
                subtitleFontURL: nil, output: root.appendingPathComponent("decoder.mp4"), watermark: nil,
                phase: { trace.begin($0) })
            defer { try? FileManager.default.removeItem(at: plan.workspace) }
            var verbose = plan.arguments
            verbose[verbose.firstIndex(of: "-loglevel")! + 1] = "debug"
            let log = try await ExportProfileRunner.run(ffmpeg, verbose, directory: plan.workspace, log: root.appendingPathComponent("decoder.log"))
            var inputs: [String] = []
            for index in plan.arguments.indices where plan.arguments[index] == "-i" { inputs.append(plan.arguments[index + 1]) }
            let png = inputs.firstIndex { $0 == "shape0.png" }!
            let marker = "Input stream #\(png):0 (video):"
            let decoded = log.components(separatedBy: "\n").first { $0.contains(marker) && $0.contains("frames decoded") } ?? ""
            require(decoded.contains("1 frames decoded"), "a static overlay is decoded exactly once: \(decoded)")
            require(!plan.arguments.contains("-loop"), "static PNGs do not use repeated demuxer decoding")
            require(trace.detail["timings"]?["stages"]?["overlay_render"]?.doubleValue ?? 0 > 0,
                    "real raster work is connected to the overlay timing stage")
            var animated = state
            var animation = ClipAnimation()
            animation.centerX = KeyframeTrack(keys: [Keyframe(time: 0, value: 0.5), Keyframe(time: 2, value: 0.51)])
            animated.mainClips[0].animation = animation
            let prerenderTrace = ExportTimings()
            let prepared = try await VideoEditExportGraph.plan(state: animated, settings: .default, subtitleStyle: .default,
                subtitleFontURL: nil, output: root.appendingPathComponent("animated.mp4"), watermark: nil,
                phase: { prerenderTrace.begin($0) })
            prerenderTrace.finish()
            require(prerenderTrace.detail["timings"]?["stages"]?["prerender"]?.doubleValue ?? 0 > 0,
                    "actual AVFoundation animation prerender is connected to its measured stage")
            try FileManager.default.removeItem(at: prepared.workspace)

            let project = OpenProjects.shared.primary
            project.newProject(); project.documentURL = root.appendingPathComponent("profile.skycut")
            project.restoreTimeline(state); project.effectiveUndoManager!.removeAllActions()
            let remembered = VideoEditExporter.shared.settings
            // 可靠占住现成队列，避免两秒小片在下一次字体 await 期间已经导完，排队断言变成竞速。
            let holding = AIJobs.shared.start(.export, progress: { nil }, cancel: {})
            AIWorkQueue.shared.submit(.export, jobID: holding.id) {}
            let first = try await AIExportTools.export(AIToolArguments(["path": .string(root.appendingPathComponent("formal.mp4").path), "encoder": "software"]), project)
            let second = try await AIExportTools.export(AIToolArguments(["path": .string(root.appendingPathComponent("review.mp4").path), "preset": "quick_review", "encoder": "software"]), project)
            let secondID = second.payload["job_id"]!.stringValue!
            let queued = AIJobs.shared.json(AIJobs.shared.job(secondID)!)
            require(queued["status"] == "queued" && queued["phase"] == "queue" && queued["timings"] != nil,
                    "queued get_job exposes measured queue timing")
            let third = try await AIExportTools.export(AIToolArguments(["path": .string(root.appendingPathComponent("cancel.mp4").path)]), project)
            let cancelled = AIJobs.shared.job(third.payload["job_id"]!.stringValue!)!
            AIJobs.shared.cancel(cancelled)
            let cancelledJSON = AIJobs.shared.json(cancelled)
            require(cancelled.status == .cancelled && cancelledJSON["timings"]?["complete"] == true
                    && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel.mp4").path), "queued cancellation freezes its timing without creating a video")
            AIJobs.shared.finish(holding, .done)
            for id in [first.payload["job_id"]!.stringValue!, secondID] {
                let job = AIJobs.shared.job(id)!
                for _ in 0..<4 where job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
                let result = try await AIExportTools.job(AIToolArguments(["job_id": .string(id)]))
                require(job.status == .done, "real export completes: \(job.message ?? "")")
                let detail = result.payload
                require(detail["timings"]?["complete"] == true && detail["timings"]?["stages"]?["video_encode"]?.doubleValue ?? 0 > 0,
                        "completed get_job retains actual encoding stage time")
                let stages = detail["timings"]?["stages"]?.objectValue ?? [:]
                let sum = stages.values.compactMap(\.doubleValue).reduce(0, +)
                require(abs(sum - (detail["timings"]?["total_seconds"]?.doubleValue ?? -1)) < 0.02,
                        "phase totals are mutually exclusive and account for the full elapsed time")
                let file = URL(fileURLWithPath: detail["path"]!.stringValue!)
                let delivered = try await MediaProbe.probe(url: file, ffmpeg: ffmpeg).get()
                let width = id == secondID ? 1280 : 1920
                require(Int(delivered.displaySize.width) == width && detail["video"]?["width"] == .number(Double(width)),
                        "reported dimensions match the actual formal/review file")
                require(detail["export_settings"]?["video_codec"] == "libx264" && detail["export_settings"]?["crf"] == .number(id == secondID ? 27 : Double(remembered.crf)),
                        "result reports the exact applied encoder and quality")
            }
            require(project.state == state && !project.effectiveUndoManager!.canUndo && VideoEditExporter.shared.settings == remembered,
                    "exports preserve project, undo stack and remembered formal quality")
        } catch { failures += 1; print("FAIL: \((error as? AIToolError)?.message ?? error.localizedDescription)") }
        print("Export profile: \(count) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
