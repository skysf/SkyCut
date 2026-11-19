import Combine
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：导出、任务进度、取消任务
//
// 管什么：export_video 走导出面板那同一个导出器（`VideoEditExporter`），只是不弹面板；导出器占着就排队（AIWorkQueue，2026-10-17）：
// 文件名默认是工程名、放在打开的文件夹的 SrtFlow/导出 里，已经有同名文件就加编号（从不覆盖，所以不问，方案第 34 条；
// which file, and the folder's checks, off the main thread, the name reserved until the video is written: AIExportDestination;
// a file that appears meanwhile is never replaced either, the video gets a later number: ExportTarget.newFile）；
// 烧字幕、分辨率的口径和面板一样（烧看得见的轨；分辨率封短边、只降不升）。
// get_job / cancel_job 管所有长任务（AIJobs）。
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）、导出本身。

@MainActor
enum AIExportTools {
    private static var subscriptions: [String: AnyCancellable] = [:]

    /// `destination` / `deadline`: the checks pass a drive that never answers or is read-only (ExportDestinationProbe).
    static func export(
        _ args: AIToolArguments, _ project: VideoEditProject,
        destination: ExportDestinationProbe = .shared, deadline: TimeInterval = AIExportDestination.deadline
    ) async throws -> AIToolResult {
        let exporter = VideoEditExporter.shared
        guard !project.state.mainClips.isEmpty else { throw AIToolError("V1 is empty. Add clips before exporting.") }
        guard MediaToolchain.shared.runtime != nil else {
            throw AIToolError("SkyCut's video engine is not ready yet. Try again in a moment.")
        }
        let timing = ExportTimings()
        let choice = try AIExportOptions.parse(args, base: exporter.settings)
        let settings = choice.settings
        var state = project.stateForExport(selectionOnly: false)
        let audioOnly = VideoEditExportGraph.isAudioOnly(state)
        // 烧不烧和面板同一个开关：烧的是时间线上看得见的那几条轨；不烧 = 两只眼睛都关。
        var options = SubtitleExportOptions()
        options.burnIn = try args.bool("burn_subtitles") ?? true
        // The folder is made, checked and listed off the main thread (a slow, stuck or read-only drive never freezes
        // SkyCut, and is said before anything is encoded); the name is picked and reserved in one step, until the video
        // is written (AIExportDestination.release).
        let chosen = try await AIExportDestination.output(
            args, project: project, fileExtension: audioOnly ? "m4a" : "mp4", probe: destination, deadline: deadline
        )
        options.applyBurnChoice(to: &state)
        if audioOnly {
            state.subtitle = nil
            state.subtitleCompanion = nil
        }
        let fonts = await FontCatalogStore.shared.loadedFonts()
        let style = state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        let fontURL = fonts.first { $0.familyName == style.fontName }?.fileURL
        let reported = AIExportOptions.describe(choice, frameRate: state.frameRate)
        let live = { timing.detail.merging(["export_settings": reported]) { current, _ in current } }

        // 成片多大、几帧（AI 不报这个就会拿 look 回的缩略图尺寸当成片尺寸，盲测里三条都以为是 720p）。
        let video: JSONValue? = audioOnly ? nil : AIVideoSize.output(
            canvas: VideoEditCompositionBuilder.renderSize(for: state), resolution: settings.resolution, fps: state.frameRate.fps
        )
        let canvasSize = VideoEditCompositionBuilder.renderSize(for: state)
        let videoSources = state.mainClips.filter { !$0.isStillImage && !$0.isAudioOnly }.compactMap(\.info)
        let sourceShort = videoSources.map { min($0.displaySize.width, $0.displaySize.height) }.max() ?? 0
        let outputShort = min(video?["width"]?.doubleValue ?? 0, video?["height"]?.doubleValue ?? 0)
        let resolutionReport: JSONValue = [
            "canvas": ["width": .number(Double(canvasSize.width)), "height": .number(Double(canvasSize.height))],
            "output": video ?? .null, "video_source_sizes": .array(videoSources.map {
                ["width": .number(Double($0.displaySize.width)), "height": .number(Double($0.displaySize.height))]
            }), "downscaled_from_video_source": .bool(outputShort > 0 && Double(sourceShort) > outputShort + 0.5),
            "notification": "Report source, canvas and delivered sizes separately in the conversation language. Explain any downscale; never describe a lower-resolution export as 2K because its source was 2K. Original media remains available; do not regenerate merely to change export settings."
        ]
        let work = AIQueuedWork()
        timing.begin("queue")
        let job = AIJobs.shared.start(.export, progress: { work.started ? exporter.progress : nil }, liveDetail: live, cancel: {
            if !work.started { timing.finish() }
            work.cancel(withdrawn: { AIExportDestination.release(chosen) }, stop: { exporter.cancel() })
            if !work.started, let job = work.job { AIJobs.shared.updateDetail(job, live()) }
        })
        work.job = job
        // 导出器空着就马上导，占着（别的工程在导、面板在导）就排队：排的是调用这一刻的时间线。
        let position = AIWorkQueue.shared.submit(.export, jobID: job.id) {
            work.started = true
            timing.begin("preparation")
            exporter.export(for: project, state: state, to: chosen.target, subtitleStyle: style, subtitleFontURL: fontURL, settingsOverride: settings, timing: timing)
            guard exporter.isExporting else {
                AIExportDestination.release(chosen)
                timing.finish()
                AIJobs.shared.finish(job, .failed, message: exporter.errorMessage ?? "The export could not start.", detail: .object(live()))
                return
            }
            // 结局在 isExporting 变回 false 的那一刻记下（@Published 在赋值之前发，那时成品路径 / 错误已经写好了）。
            subscriptions[job.id] = exporter.$isExporting.dropFirst().filter { !$0 }.first().sink { _ in
                MainActor.assumeIsolated {
                    AIExportDestination.release(chosen)
                    if exporter.finishedTarget == chosen.target, let output = exporter.finishedURL {
                        var detail = finishedDetail(output, video: video, levels: exporter.finishedAudioLevels, watermarked: exporter.watermarked)
                        detail["resolution_report"] = resolutionReport
                        if output.standardizedFileURL.path != chosen.target.url.standardizedFileURL.path {
                            detail["path_note"] = .string(
                                "\(chosen.target.url.lastPathComponent) appeared in the folder while exporting, so this video is "
                                    + "\(output.lastPathComponent). Nothing was replaced; tell the user the file name."
                            )
                        }
                        detail.merge(live()) { current, _ in current }
                        AIJobs.shared.finish(job, .done, detail: .object(detail))
                    } else if let error = exporter.errorMessage {
                        AIJobs.shared.finish(job, .failed, message: error, detail: .object(live()))
                    } else {
                        AIJobs.shared.finish(job, .cancelled, detail: .object(live()))
                    }
                    subscriptions[job.id] = nil
                }
            }
        }
        if job.status == .failed { throw AIToolError(job.message ?? "The export could not start.") }
        var result: [String: JSONValue] = [
            "job_id": .string(job.id), "resolution_report": resolutionReport, "export_settings": reported,
            "status": position == nil ? "running" : "queued",
            "path": .string(chosen.target.url.path),
            "next_step": .string(position == nil
                ? "Call get_job with this job_id and wait_seconds 30 until the status is done."
                : "Another export is running; this one starts after it (queue_position). Wait with get_job.")
        ]
        if let position { result["queue_position"] = .number(Double(position)) }
        if let video { result["video"] = video }
        // 会带水印（没开通 / 体验期）：先说一声，用户要的是没水印的成片时 AI 能先停下来说清楚（做完 get_job 里还会说一遍）。
        if !audioOnly, WatermarkPolicy.required(byLicence: SkyStudioAccount.shared.exportsWithWatermark) {
            result["watermark"] = .string(SkyCutGates.watermarkNote(license: SkyStudioAccount.shared.license))
        }
        return .ok(.object(result))
    }

    /// 成品的路径和画面（宽、高、帧率），带了水印的说为什么、怎么去掉，加混音的电平和响度（ExportAudioReport：成片自己的真峰值、
    /// 限幅器干的活单独标出来，docs/architecture/export-audio-mixdown.md 第二节第 3 条）。
    static func finishedDetail(
        _ output: URL, video: JSONValue?, levels: ExportAudioMixdown.Levels?, watermarked: Bool
    ) -> [String: JSONValue] {
        var detail: [String: JSONValue] = ["path": .string(output.path)]
        if let video { detail["video"] = video }
        if watermarked { detail["watermark"] = .string(SkyCutGates.watermarkNote(license: SkyStudioAccount.shared.license)) }
        guard let levels else { return detail }
        detail.merge(ExportAudioReport.detail(levels)) { _, audio in audio }
        return detail
    }

    /// 没给名字时成品叫什么：工程名，没存过就是 V1 第一段的名字（export_subtitles 也用它，字幕文件和视频同名配成一对）。
    static func defaultName(_ project: VideoEditProject) -> String {
        project.documentURL?.deletingPathExtension().lastPathComponent ?? project.state.mainClips.first?.name ?? "Timeline"
    }

    // MARK: get_job / cancel_job

    static func job(_ args: AIToolArguments) async throws -> AIToolResult {
        let id = try args.requiredString("job_id")
        if AIJobs.shared.job(id) == nil { _ = try await SkyStudioCharacterJobs.restore(id, project: nil) }
        let job = try find(args)
        await job.refresh?()
        if let wait = try args.double("wait_seconds"), wait > 0 {
            await AIJobs.shared.wait(for: job, seconds: wait)
        }
        var result = AIToolResult.ok(AIJobs.shared.json(job))
        result.images = job.images
        return result
    }

    static func cancel(_ args: AIToolArguments) throws -> AIToolResult {
        let job = try find(args)
        // 只取消自己会话起的（方案 B.5）：几个会话共用一个 App 时，别人的导出不许被顺手停掉。
        if let owner = job.session, owner != (AICallContext.current?.session ?? AIProjectSessions.anonymous) {
            throw AIToolError("Not cancelled: \(job.id) was started by another AI session, and only that session may cancel it.")
        }
        AIJobs.shared.cancel(job)
        return .ok(AIJobs.shared.json(job))
    }

    private static func find(_ args: AIToolArguments) throws -> AIJobs.Job {
        let id = try args.requiredString("job_id")
        guard let job = AIJobs.shared.job(id) else {
            throw AIToolError("There is no job \(id). Jobs are forgotten when SkyCut quits.")
        }
        return job
    }
}
