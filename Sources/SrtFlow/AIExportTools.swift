import Combine
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：导出、任务进度、取消任务
//
// 管什么：export_video 走导出面板那同一个导出器（`VideoEditExporter`），只是不弹面板；导出器占着就排队（AIWorkQueue，2026-10-17）：
// 文件名默认是工程名、放在打开的文件夹的 SrtFlow/导出 里，已经有同名文件就加编号（从不覆盖，所以不问，方案第 34 条）；
// 烧字幕、分辨率的口径和面板一样（烧看得见的轨；分辨率封短边、只降不升）。
// get_job / cancel_job 管所有长任务（AIJobs）。
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）、导出本身。

@MainActor
enum AIExportTools {
    private static var subscriptions: [String: AnyCancellable] = [:]
    /// 排着队、还没写出来的成品路径：几个导出排在一起时各占各的名字，不会都算成同一个「没被占」的名字。
    private static var reservedOutputs: Set<String> = []

    static func export(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let exporter = VideoEditExporter.shared
        guard !project.state.mainClips.isEmpty else { throw AIToolError("V1 is empty. Add clips before exporting.") }
        guard MediaToolchain.shared.runtime != nil else {
            throw AIToolError("SkyCut's video engine is not ready yet. Try again in a moment.")
        }
        var state = project.stateForExport(selectionOnly: false)
        let audioOnly = VideoEditExportGraph.isAudioOnly(state)
        let requested = try outputURL(args, project: project, fileExtension: audioOnly ? "m4a" : "mp4")
        let output = ExportFileName.unoccupied(
            in: requested.deletingLastPathComponent(), stem: requested.deletingPathExtension().lastPathComponent,
            pathExtension: requested.pathExtension
        ) { FileManager.default.fileExists(atPath: $0.path) || reservedOutputs.contains($0.standardizedFileURL.path) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings = exporter.settings
        if let resolution = try args.choice("resolution", from: MCPVocabulary.resolutions) {
            settings.resolution = AIEncodeOptions.resolution(resolution)
        }
        // 烧不烧和面板同一个开关：烧的是时间线上看得见的那几条轨；不烧 = 两只眼睛都关。
        var options = SubtitleExportOptions()
        options.burnIn = try args.bool("burn_subtitles") ?? true
        options.applyBurnChoice(to: &state)
        if audioOnly {
            state.subtitle = nil
            state.subtitleCompanion = nil
        }
        let fonts = await FontCatalogStore.shared.loadedFonts()
        let style = state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        let fontURL = fonts.first { $0.familyName == style.fontName }?.fileURL

        // 成片多大、几帧（AI 不报这个就会拿 look 回的缩略图尺寸当成片尺寸，盲测里三条都以为是 720p）。
        let video: JSONValue? = audioOnly ? nil : AIVideoSize.output(
            canvas: VideoEditCompositionBuilder.renderSize(for: state), resolution: settings.resolution, fps: state.frameRate.fps
        )
        let reserved = output.standardizedFileURL.path
        reservedOutputs.insert(reserved)
        let work = AIQueuedWork()
        let job = AIJobs.shared.start(.export, progress: { work.started ? exporter.progress : nil }, cancel: {
            work.cancel(withdrawn: { reservedOutputs.remove(reserved) }, stop: { exporter.cancel() })
        })
        work.job = job
        // 导出器空着就马上导，占着（别的工程在导、面板在导）就排队：排的是调用这一刻的时间线。
        let position = AIWorkQueue.shared.submit(.export, jobID: job.id) {
            work.started = true
            exporter.export(for: project, state: state, to: output, subtitleStyle: style, subtitleFontURL: fontURL, settingsOverride: settings)
            guard exporter.isExporting else {
                reservedOutputs.remove(reserved)
                AIJobs.shared.finish(job, .failed, message: exporter.errorMessage ?? "The export could not start.")
                return
            }
            // 结局在 isExporting 变回 false 的那一刻记下（@Published 在赋值之前发，那时成品路径 / 错误已经写好了）。
            subscriptions[job.id] = exporter.$isExporting.dropFirst().filter { !$0 }.first().sink { _ in
                MainActor.assumeIsolated {
                    reservedOutputs.remove(reserved)
                    if exporter.finishedURL?.standardizedFileURL.path == output.standardizedFileURL.path {
                        let detail = finishedDetail(output, video: video, levels: exporter.finishedAudioLevels, watermarked: exporter.watermarked)
                        AIJobs.shared.finish(job, .done, detail: .object(detail))
                    } else if let error = exporter.errorMessage {
                        AIJobs.shared.finish(job, .failed, message: error)
                    } else {
                        AIJobs.shared.finish(job, .cancelled)
                    }
                    subscriptions[job.id] = nil
                }
            }
        }
        if job.status == .failed { throw AIToolError(job.message ?? "The export could not start.") }
        var result: [String: JSONValue] = [
            "job_id": .string(job.id),
            "status": position == nil ? "running" : "queued",
            "path": .string(output.path),
            "next_step": .string(position == nil
                ? "Call get_job with this job_id and wait_seconds 30 until the status is done."
                : "Another export is running; this one starts after it (queue_position). Wait with get_job.")
        ]
        if let position { result["queue_position"] = .number(Double(position)) }
        if let video { result["video"] = video }
        // 会带水印（没开通 / 体验期）：先说一声，用户要的是没水印的成片时 AI 能先停下来说清楚（做完 get_job 里还会说一遍）。
        if !audioOnly, WatermarkPolicy.required(byLicence: SkyStudioAccount.shared.exportsWithWatermark) {
            result["watermark"] = .string(SkyCutGates.watermarkNote)
        }
        return .ok(.object(result))
    }

    /// 成品的路径和画面（宽、高、帧率），带了水印的说为什么、怎么去掉，加混音的电平和响度：限幅器压过的说明压了多久多深，
    /// 压得超过 3 dB 的再叫 AI 把主推子降下来（docs/architecture/export-audio-mixdown.md 第二节第 3 条）。
    static func finishedDetail(
        _ output: URL, video: JSONValue?, levels: ExportAudioMixdown.Levels?, watermarked: Bool
    ) -> [String: JSONValue] {
        var detail: [String: JSONValue] = ["path": .string(output.path)]
        if let video { detail["video"] = video }
        if watermarked { detail["watermark"] = .string(SkyCutGates.watermarkNote) }
        guard let levels else { return detail }
        func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        if let loudness = levels.loudnessLUFS { detail["audio_loudness_lufs"] = tenths(loudness) }
        detail["audio_peak_dbfs"] = tenths(levels.peakDBFS)
        if levels.isLimited {
            detail["audio_limited_seconds"] = .number((levels.limitedSeconds * 100).rounded() / 100)
            detail["audio_max_reduction_db"] = tenths(levels.maxReductionDB)
        }
        if levels.needsAttention {
            detail["note"] = .string(String(
                format: "The mix went over -1 dBFS for %.2f s and the limiter pushed it down by up to %.1f dB. Lower the master fader "
                    + "(set_track master volume_db) by about %.1f dB, or the loud clips, and export again for a cleaner mix.",
                levels.limitedSeconds, levels.maxReductionDB, levels.suggestedReductionDB
            ))
        }
        return detail
    }

    /// 没给名字时成品叫什么：工程名，没存过就是 V1 第一段的名字（export_subtitles 也用它，字幕文件和视频同名配成一对）。
    static func defaultName(_ project: VideoEditProject) -> String {
        project.documentURL?.deletingPathExtension().lastPathComponent ?? project.state.mainClips.first?.name ?? "Timeline"
    }

    /// 给了完整路径就用它（扩展名按这次导出的类型改正）；否则 = 默认文件夹 + 名字（默认工程名）。
    private static func outputURL(_ args: AIToolArguments, project: VideoEditProject, fileExtension: String) throws -> URL {
        if let path = try args.string("path") {
            let url = AIWorkspace.shared.resolve(path)
            return url.pathExtension.lowercased() == fileExtension
                ? url : url.deletingPathExtension().appendingPathExtension(fileExtension)
        }
        let fallback = defaultName(project)
        // 同一个文件夹出几个版本：成片的名字带上版本（「南极 - 30s」，方案板 5；工程名里已经带着就不再叠）。
        let stem = AIVersionName.stem(ExportFileName.stem(
            from: try args.string("name") ?? fallback, droppingExtension: fileExtension, fallback: fallback
        ), version: AIVersionName.clean(try args.string("version")))
        return AIWorkspace.shared.outputFolder(.exports, project: project)
            .appendingPathComponent(stem).appendingPathExtension(fileExtension)
    }

    // MARK: get_job / cancel_job

    static func job(_ args: AIToolArguments) async throws -> AIToolResult {
        let job = try find(args)
        await job.refresh?()
        if let wait = try args.double("wait_seconds"), wait > 0 {
            await AIJobs.shared.wait(for: job, seconds: wait)
        }
        return .ok(AIJobs.shared.json(job))
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
