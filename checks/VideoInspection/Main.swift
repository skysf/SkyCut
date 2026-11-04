import AppKit
import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 真正的 MCP 工具/任务/混音/取帧，不注入分析结果；只创建临时工程，不启动用户 App。
@main enum VideoInspectionChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.inspectioncheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Isolated check bundle required") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_INSPECTION_CHECK_DIR"]!)
        var failures = 0, count = 0
        func require(_ condition: Bool, _ why: String) {
            count += 1
            if !condition { failures += 1; print("FAIL: \(why)") }
        }
        do {
            let source = root.appendingPathComponent("source.mp4")
            let project = OpenProjects.shared.primary
            project.newProject()
            project.documentURL = root.appendingPathComponent("inspection.skycut")
            let info = await project.mediaProbes.probeVideo(source)!
            var state = TimelineState()
            state.frameRate = .fps24
            state.mainClips = [EditClip(sourceURL: source, sourceDuration: 3, timelineStart: 0, info: info),
                               EditClip(sourceURL: source, sourceStart: 4, sourceDuration: 4, timelineStart: 4, info: info)]
            // 同一条音轨重叠两段，重复源；音乐床不应让所有跨轨组合都被当成问题。
            state.audioTracks = [EditLane(clips: [
                EditClip(sourceURL: source, isAudioOnly: true, sourceDuration: 1, timelineStart: 1, audioAssetDuration: 8),
                EditClip(sourceURL: source, isAudioOnly: true, sourceDuration: 1, timelineStart: 1.5, audioAssetDuration: 8)
            ])]
            var style = BurnInStyle.default
            style.fontSize = 160
            state.subtitleCompanion = SubtitleCompanion(origin: .imported)
            state.projectSubtitleStyle = style
            let a = SubtitleCue(id: UUID(), start: 0.5, end: 2, text: String(repeating: "W", count: 100))
            let b = SubtitleCue(id: UUID(), start: 1, end: 2.5, text: "second line")
            state.subtitle = SubtitleDocumentModel(cues: [a, b], format: .srt)
            project.restoreTimeline(state)
            project.effectiveUndoManager!.removeAllActions()
            let before = project.state
            let clock = project.clock.time
            let args = AIToolArguments(["from": 0, "to": 8])
            let started = try await AIInspectionTool.start(args, project)
            let job = AIJobs.shared.job(started.payload["job_id"]!.stringValue!)!
            await AIJobs.shared.wait(for: job, seconds: 30)
            let result = try await AIExportTools.job(AIToolArguments(["job_id": .string(job.id)]))
            print(result.payload.encodedString())
            require(job.status == .done, "production inspection finishes: \(job.message ?? "")")
            let kinds = Set(result.payload["findings"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? [])
            for kind in ["audio_cutoff", "audio_overlap", "audio_silence", "black_frame", "subtitle_bounds", "subtitle_overlap"] {
                require(kinds.contains(kind), "deliberate \(kind) is found through the real tool")
            }
            require(project.state == before && project.clock.time == clock && !project.effectiveUndoManager!.canUndo,
                    "inspection preserves the full project, playhead and undo stack")
            require(result.payload["changed"] == false && result.payload["subtitle_style"]?["font_size"] == 160,
                    "result is nonediting and uses the project's current style")
            require(!result.images.isEmpty && result.json["content"]?.arrayValue?.contains(where: { $0["type"] == "image" }) == true,
                    "get_job returns actual suspect screenshots as MCP image content")
            let auditions = result.payload["auditions"]!.arrayValue!
            require(!auditions.isEmpty, "audio suspicions have playable evidence")
            for entry in auditions {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: entry["path"]!.stringValue!))
                let duration = Double(file.length) / file.processingFormat.sampleRate
                require(duration > 0 && duration <= 3.001 && abs(duration - (entry["to"]!.doubleValue! - entry["from"]!.doubleValue!)) < 0.01,
                        "short audition is real audio matching its reported timeline interval")
            }
            // 范围不能泄漏别处的结尾、黑场或字幕。
            let scope = try AIInspection.scope(state: before, from: 5, to: 6)
            require(!scope.contains(8) && AIInspection.subtitles(before, style: style, scope: scope).isEmpty, "range excludes unrelated ending and subtitle findings")
            let defaults = try AIInspection.scope(state: before, from: nil, to: nil)
            require(defaults.contains(8) && defaults.contains(3) && defaults.contains(4), "defaults prioritize all audio seams and ending")
            var outside = before
            outside.subtitle = SubtitleDocumentModel(cues: [.init(id: UUID(), start: 9, end: 10, text: "past the end")], format: .srt)
            require(AIInspection.subtitles(outside, style: style, scope: defaults).contains { $0.kind == "subtitle_time_bounds" },
                    "ending check includes a subtitle entirely beyond the video's end")
            outside.subtitle = SubtitleDocumentModel(cues: [.init(id: UUID(), start: -2, end: -1, text: "before the start")], format: .srt)
            require(AIInspection.subtitles(outside, style: style, scope: defaults).contains { $0.kind == "subtitle_time_bounds" },
                    "opening check includes a subtitle entirely before the video's start")
            var stacked = before
            stacked.subtitle = SubtitleDocumentModel(cues: [.init(id: UUID(), start: 1, end: 2, text: "Hello")], format: .srt)
            stacked.subtitleCompanion!.translation = SubtitleDocumentModel(cues: [.init(id: UUID(), start: 1, end: 2, text: "Bonjour")], format: .srt)
            require(!AIInspection.subtitles(stacked, style: style, scope: defaults).contains { $0.kind == "subtitle_overlap" },
                    "native stacked bilingual subtitles do not create false collision findings")
            var hidden = before
            hidden.subtitleHidden = true
            require(AIInspection.subtitles(hidden, style: style, scope: defaults).isEmpty, "hidden subtitles are not falsely inspected")
            var quiet = before
            quiet.audioTracks[0].isHidden = true
            quiet.mainHidden = true
            require(AIInspection.overlaps(AudioEngineConfig.make(from: quiet), scope: defaults).isEmpty, "hidden tracks cannot cause overlap suspicions")
            let badRange = AIToolArguments(["from": 7, "to": 9])
            do { _ = try await AIInspectionTool.start(badRange, project); require(false, "out-of-range request rejects") }
            catch { require(project.state == before, "bad range does not modify project") }
            // 提供的成片真正走文件的像素和声音，字幕依然按冻结工程的样式量。
            AIWorkspace.shared.register(root)
            let fileStart = try await AIInspectionTool.start(AIToolArguments([
                "file": .string(root.appendingPathComponent("rendered.mp4").path), "from": 3, "to": 4, "image": false
            ]), project)
            let fileJob = AIJobs.shared.job(fileStart.payload["job_id"]!.stringValue!)!
            await AIJobs.shared.wait(for: fileJob, seconds: 30)
            let detail = AIJobs.shared.json(fileJob)
            require(fileJob.status == .done && detail["inspected"]?.stringValue?.hasSuffix("rendered.mp4") == true,
                    "export file inspection completes with the actual file")
            require(detail["findings"]!.arrayValue!.contains { $0["kind"] == "black_frame" }, "actual export black interval is detected")
            // 真实干净范围仍采样画面/测声音，但没有疑点，因此没有请求证据截图。
            let cleanStart = try await AIInspectionTool.start(AIToolArguments(["from": 5, "to": 6]), project)
            let cleanJob = AIJobs.shared.job(cleanStart.payload["job_id"]!.stringValue!)!
            await AIJobs.shared.wait(for: cleanJob, seconds: 30)
            let cleanResult = try await AIExportTools.job(AIToolArguments(["job_id": .string(cleanJob.id)]))
            require(cleanJob.status == .done && cleanResult.payload["coverage_complete"] == true,
                    "clean range inspection completes its actual analysis")
            require(cleanResult.payload["findings"]?.arrayValue?.isEmpty == true,
                    "continuous bright picture and sound inside the clip produce no suspect")
            require(cleanResult.payload["screenshot_times"]?.arrayValue?.isEmpty == true && cleanResult.images.isEmpty,
                    "no suspect requests no evidence screenshot")
            require(cleanResult.payload["image"] == nil,
                    "no requested evidence does not falsely report a drawing failure")
            // look 仍要如实报告确实要求了图片却没拿到帧；不能在共用拼图层吞掉失败。
            var missingPayload: [String: JSONValue] = [:]
            let missing = AILookTool.finish(&missingPayload, frames: [], size: .medium, wantsImage: true)
            require(missing.payload["image"]?.stringValue?.contains("could not draw") == true,
                    "a requested but unavailable picture retains its failure notice")
            let cancelStart = try await AIInspectionTool.start(args, project)
            let cancelled = AIJobs.shared.job(cancelStart.payload["job_id"]!.stringValue!)!
            AIJobs.shared.cancel(cancelled)
            await AIJobs.shared.wait(for: cancelled, seconds: 30)
            require(cancelled.status == .cancelled && project.state == before, "cancellation leaves project untouched")
            require(MCPToolName.inspectVideo.takesProject && AIProjectBinding.usesProject(.inspectVideo, args), "inspection is bound to its calling project")
            require(!MCPToolName.inspectVideo.definition.readOnly, "temporary evidence is honestly declared as file writing")
            // 清掉本次的短试听，避免验收给机器留下合成媒体。
            if let path = auditions.first?["path"]?.stringValue { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        } catch { failures += 1; print("FAIL: \((error as? AIToolError)?.message ?? error.localizedDescription)") }
        print("Video inspection: \(count) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
