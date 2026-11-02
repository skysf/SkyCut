import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - MCP 按旁白段落同步（本地长任务）
// 管什么：快照 → 实测音频 / 本机转写 → 共用定格素材准备 → 全量校验 → 现有批量提交。
// 不管什么：语音生成 / 付费、猜画面、另建事务机制；任何准备失败都不碰时间线。

@MainActor
final class AIVoiceoverSyncTool {
    struct Services {
        var duration: (URL) async throws -> Double = MediaProbeCache.measuredAudioDuration
        var words: (URL, String) async throws -> [TimedWord] = { url, language in
            let locale = try await SkyStudioVoiceAudio.splitLocale(language: language)
            return try await SkyStudioVoiceAudio.transcribe(url, locale: locale)
        }
    }

    private weak var project: VideoEditProject?
    private let input: AIVoiceoverSyncInput
    private let before: TimelineState
    private let generation: Int
    private let services: Services
    private var task: Task<Void, Never>?
    private var progress = 0.0
    private var phase = "reading_audio"
    private var createdImages: [URL] = []

    init(_ args: AIToolArguments, _ project: VideoEditProject, services: Services = Services()) throws {
        guard project.liveEditOrigin == nil else { throw AIToolError("Finish the current drag or slider edit before syncing narration.") }
        input = try AIVoiceoverSyncInput(args, state: project.state)
        before = project.state
        generation = project.documentGeneration
        self.project = project
        self.services = services
    }

    func start() -> AIToolResult {
        let job = AIJobs.shared.start(.voiceover, progress: { [weak self] in self?.progress }, liveDetail: { [weak self] in
            ["operation": "sync_voiceover", "phase": .string(self?.phase ?? "preparing")]
        }, cancel: { [weak self] in self?.task?.cancel() })
        task = Task { @MainActor in
            var applied = false
            defer { if !applied { for image in self.createdImages { try? FileManager.default.removeItem(at: image) } } }
            do {
                let plan = try await self.prepare()
                let result = try self.apply(plan)
                applied = true
                AIJobs.shared.finish(job, .done, detail: result.payload)
            } catch {
                let message = (error as? AIToolError)?.message ?? error.localizedDescription
                AIJobs.shared.finish(job, error is CancellationError ? .cancelled : .failed, message: message,
                    detail: ["operation": "sync_voiceover", "applied": false, "failure_stage": .string(self.phase),
                             "next_step": "Keep the existing new audio. Correct the mapping or alignment problem, get_timeline, then retry sync_voiceover. No voice generation was requested."])
            }
        }
        return .ok(["status": "started", "job_id": .string(job.id),
                    "next_step": "Wait with get_job. Local audio alignment completes before one atomic timeline edit. Keep new audio on failure; no generation is requested."])
    }

    func prepare() async throws -> AIVoiceoverSyncPlan {
        var audio: [UUID: AIVoiceoverSyncPlan.Audio] = [:]
        for (index, p) in input.paragraphs.enumerated() {
            try checkCurrent()
            phase = "reading_audio"
            let voice = before.clip(with: p.voice)!
            let actual = try await services.duration(voice.sourceURL)
            // 未裁过的旁白用文件实际长度；裁过的旁白只用原先明确选中的窗口。
            let whole = abs(voice.sourceStart) < 0.000001 && abs(voice.sourceDuration - voice.assetDuration) < 0.05
            let length = whole ? actual : voice.sourceDuration
            guard length.isFinite, length > 0, voice.sourceStart >= 0, voice.sourceStart + length <= actual + 0.001 else {
                throw AIToolError("The selected narration window exceeds its actual audio file. Nothing was applied.")
            }
            var words: [TimedWord] = []
            if !p.subtitles.isEmpty {
                phase = "subtitle_alignment"
                words = try await services.words(voice.sourceURL, input.language)
                words = words.filter { $0.end > voice.sourceStart && $0.start < voice.sourceStart + length }.map {
                    TimedWord(text: $0.text, start: max(0, $0.start - voice.sourceStart),
                              end: min(length, $0.end - voice.sourceStart), confidence: $0.confidence)
                }
            }
            audio[p.voice] = .init(sourceDuration: length, assetDuration: actual, words: words)
            progress = Double(index + 1) / Double(input.paragraphs.count) * 0.75
        }
        try checkCurrent()
        phase = "validation"
        var plan = try AIVoiceoverSyncPlan(input: input, state: before, audio: audio)
        // 先查参数和普通落点，再产生定格文件；带尾帧的最终完整时间线仍在全部准备好后再查。
        try plan.validate()
        for request in plan.freezes {
            phase = "freeze_preparation"
            let frozen = try await freeze(request, state: before)
            try plan.addFreeze(frozen, for: request)
        }
        phase = "validation"
        try plan.validate()
        try checkCurrent()
        return plan
    }

    private func freeze(_ request: AIVoiceoverSyncPlan.Freeze, state: TimelineState) async throws -> EditClip {
        try checkCurrent()
        guard let project, let clip = state.clip(with: request.id), !project.isFreezing,
              project.isFreezeEligible(clip, at: request.at), let ffmpeg = MediaToolchain.shared.runtime?.url else {
            throw AIToolError("That picture cannot provide a freeze tail (hidden, unavailable, inside a transition, or video engine not ready). Nothing was applied.")
        }
        let frame = try await VideoEditProject.extractFrame(from: clip.sourceURL, atSourceTime: clip.sourceTime(atTimeline: request.at),
            tolerance: KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: clip.speed))
        try checkCurrent()
        let image = try project.writeFreezeImage(frame.image, clipName: clip.name, at: request.at)
        createdImages.append(image)
        let still = try await StillImageClipFactory.stillVideo(for: image, ffmpeg: ffmpeg,
            nativeResolution: StillImageClipFactory.needsNativeResolution(for: .init(width: frame.image.width, height: frame.image.height)))
        guard let info = await project.mediaProbes.probeVideo(still) else { throw AIToolError("Could not read the prepared freeze video. Nothing was applied.") }
        try checkCurrent()
        return clip.makeFreezeClip(image: image, still: still, info: info, at: request.at, duration: request.duration,
                                   canvas: VideoEditCompositionBuilder.renderSize(for: state))
    }

    func apply(_ plan: AIVoiceoverSyncPlan) throws -> AIToolResult {
        try checkCurrent()
        guard let project else { throw AIToolError("The project was closed. Nothing was applied.") }
        try plan.validate()
        phase = "commit"
        _ = try AIBatchEditTools.commit(plan.edit, project, rebuildsPreview: true, alreadySettled: true)
        let ids = AIShortIDs(state: project.state)
        var result = AIToolResult.ok([
            "operation": "sync_voiceover", "applied": .bool(plan.edit.changed),
            "paragraphs": .array(plan.spans.enumerated().map { index, span in
                ["index": .number(Double(index)), "voiceover_id": .string(ids.short(span.paragraph.voice)),
                 "from": .number(span.paragraph.from), "to": .number(span.paragraph.to),
                 "start": .number(span.start), "end": .number(span.end)]
            }),
            "timeline_duration": .number(project.state.duration), "linkage_reapplied": false,
            "note": "Only explicitly mapped items were synchronized. Other items and global Linkage/Magnet settings were kept. All subtitle text and styles were preserved."
        ], changed: plan.edit.changed)
        if plan.edit.changed {
            AISession.shared.round(for: project).noteChange()
            result = AIProjectTools.saveIfNeverSaved(project, after: result)
        }
        return result
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard let project, project.isCurrentGeneration(generation), project.state == before, project.liveEditOrigin == nil else {
            throw AIToolError("The project or timeline changed while SkyCut prepared the synchronization. Nothing was applied; get_timeline and retry.")
        }
    }
}
