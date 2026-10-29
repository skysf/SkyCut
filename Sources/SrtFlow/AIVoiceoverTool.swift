import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：配旁白（add_voiceover，方案第 42、43 条）
//
// 管什么：AI 写好的几句旁白，用这台 Mac 的声音一句一个文件读出来（`<起点>/SrtFlow/配音`，撞名加编号），放上音频轨；
// 要字幕的话按词的时间切成字幕加进原文轨（AIVoiceoverSubtitles）。
// 分两步（同 edit_clip）：`plan` 可以 await（合成、读文件），`apply` 同步提交、路由包在 `AIUndoGrouping.step` 里 ——
// 放素材和加字幕在同一次 perform 里，一个工具 = 一步撤销。
// 放上时间线走 add_clips 那一套（`AITimelineEdits.place`：撞上往上抬一轨；这一批都放进第一句新开的那条轨）。
// 声音分三档（第 42、48 条）：用户接了 Sky Studio 就用 Sky Studio 的声音（`SkyStudioVoiceoverRun`：有 Key、没超每日上限、Key 读得出来；不行就退到下一档并在结果里说为什么），
// 其次下载了 SrtFlow 自己的声音（本机的 Kokoro），没下载 / 它读不了的语言用这台 Mac 的；
// `download_voices=true` 开始下载、回任务号（第 50 条：AI 也能直接下，下的时候告诉用户）。
// `clone_from`（第 52 条）：用一段素材里的声音当参考、让 Sky Studio 的克隆模型读 —— 只有 Sky Studio 能克隆，用不了就报错、不退档。
// 不管什么：挑声音（AIVoiceChoice）、怎么合成（SkyStudioVoiceoverRun / KokoroVoiceSpeech / AISpeechSynthesis）、下载（KokoroVoicePack）。

@MainActor
enum AIVoiceoverTool {
    typealias Line = VoiceoverLine

    struct Spoken {
        var line: Line
        var output: AISpeechSynthesis.Output
        var clip: EditClip
    }

    struct Plan {
        var spoken: [Spoken]
        var starts: [Double]
        var target: TrackDropTarget
        var choice: AIVoiceChoice
        var language: String
        var subtitles: Bool
        /// `max_lines`：这次说了就按它切、并记进工程；nil = 按工程记的（默认单行）。
        var maxLines: Int?
        var generation: Int
    }

    /// `download_voices=true`：开始下载 SrtFlow 自己的声音（已经装好就直接说），回任务号；这一次不配音、不改工程。
    static func startDownloadIfAsked(_ args: AIToolArguments) async throws -> AIToolResult? {
        guard try args.bool("download_voices") == true else { return nil }
        let pack = KokoroVoicePack.shared
        if pack.isInstalled {
            return .ok(["status": "installed", "next_step": "SkyCut's voices are ready: call add_voiceover with your lines."])
        }
        let job = AIJobs.shared.start(.voices, progress: { pack.fraction }, cancel: { pack.cancel() })
        Task { @MainActor in
            do {
                try await pack.install()
                AIJobs.shared.finish(job, .done, message: "SkyCut's voices are downloaded. Call add_voiceover with your lines.")
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                AIJobs.shared.finish(job, cancelled ? .cancelled : .failed,
                                     message: cancelled ? "The download was stopped." : error.localizedDescription)
            }
        }
        return .ok([
            "status": "downloading", "job_id": .string(job.id), "size": .string(KokoroVoicePack.approximateSize),
            "next_step": .string("Tell the user SkyCut is downloading its own voices (about \(KokoroVoicePack.approximateSize); "
                + "progress also shows in Settings → AI). Wait with get_job, then call add_voiceover again without download_voices.")
        ])
    }

    /// 克隆用的素材在点名的文件夹以外：要发给 Sky Studio，先问用户一次（同读别处的文件）。要问就回 needs_confirmation。
    static func confirmations(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult? {
        guard let clone = try AIVoiceoverInput.cloneSource(args) else { return nil }
        return try AIWorkspace.shared.confirmReading([clone.url], verb: "send to Sky Studio", args: args, project: project)
    }

    static func plan(_ input: AIVoiceoverInput, _ project: VideoEditProject,
                     outputs: [AISpeechSynthesis.Output]? = nil) async throws -> Plan {
        guard project.isCurrentGeneration(input.generation) else {
            throw AIToolError("The project changed while the voiceover was being made. No lines were added.")
        }
        if let outputs, outputs.count != input.lines.count { throw AIToolError("The voiceover did not return all the lines.") }
        var spoken: [Spoken] = []
        for (index, line) in input.lines.enumerated() {
            try Task.checkCancellation()
            let output: AISpeechSynthesis.Output
            if let outputs {
                output = outputs[index]
            } else {
                output = try await AIVoiceoverFile.make(text: line.text, folder: input.folder) { url in
                    switch input.choice.engine {
                    case .skyStudio: throw AIToolError("A cloud voiceover must be awaited with get_job.")
                    case .kokoro(let voice, let language):
                        return try await KokoroVoiceSpeech.shared.speak(line.text, language: language, voice: voice, speed: input.speed, to: url)
                    case .system:
                        return try await AISpeechSynthesis.speak(line.text, choice: input.choice, speed: input.speed, to: url)
                    }
                }
            }
            guard let media = await project.probeImports([output.url]).first else {
                throw AIToolError("lines[\(index)]: SkyCut could not read back the voiceover file \(output.url.lastPathComponent).")
            }
            spoken.append(Spoken(line: line, output: output, clip: project.clip(for: media)))
        }
        guard project.isCurrentGeneration(input.generation) else {
            throw AIToolError("The project changed while the voiceover was being made. No lines were added.")
        }
        return Plan(spoken: spoken, starts: starts(for: spoken, playhead: project.clock.time), target: input.target, choice: input.choice,
                    language: input.language, subtitles: input.subtitles, maxLines: input.maxLines, generation: input.generation)
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation) else {
            throw AIToolError("The project changed while the voiceover was being made. Try again.")
        }
        let placed = zip(plan.spoken, plan.starts).map { spoken, start in
            AITimelineEdits.PlannedClip(clip: spoken.clip, isAudio: true, target: plan.target, start: start)
        }
        // 几行：AI 这次说了就按它、并记进工程（和面板同一个开关）；没说按工程记的（默认单行）。
        let maxLines = plan.maxLines ?? project.state.subtitleMaxLines
        let config = AIVoiceoverSubtitles.config(
            languageCode: plan.language, frameDuration: project.state.frameRate.secondsPerFrame,
            maxLineEms: SubtitleLineFit.ems(for: project.state, appWide: EncodeQueue.burnIn.burnInStyle,
                                            renderSize: project.renderSize),
            maxLineCount: maxLines
        )
        var subtitles = AIVoiceoverSubtitles.Outcome()
        let linkage = project.linkageEnabled
        project.perform { state in
            if let requested = plan.maxLines { state.subtitleMaxLines = requested }
            AITimelineEdits.place(placed, insert: false, linkage: linkage, in: &state)
            guard plan.subtitles else { return }
            let pieces = plan.spoken.compactMap { spoken -> AIVoiceoverSubtitles.Piece? in
                guard let clip = state.clip(with: spoken.clip.id), let location = state.location(of: clip.id) else { return nil }
                let rank: Int
                if case .audio(let index) = location.track { rank = 1 + index } else { rank = 1 }
                return .init(clipID: clip.id, timelineStart: clip.timelineStart, duration: spoken.output.duration,
                             laneRank: rank, words: spoken.output.words)
            }
            subtitles = AIVoiceoverSubtitles.add(pieces, language: plan.language, config: config, to: &state)
        }
        return result(plan, subtitles: subtitles, project: project)
    }

    // MARK: 参数与结果

    static func starts(for spoken: [Spoken], playhead: Double) -> [Double] {
        AIVoiceoverPlacement.starts(given: spoken.map(\.line.start), durations: spoken.map(\.clip.timelineDuration),
                                    playhead: playhead)
    }

    private static func result(_ plan: Plan, subtitles: AIVoiceoverSubtitles.Outcome, project: VideoEditProject) -> AIToolResult {
        let state = project.state
        let ids = AIShortIDs(state: state)
        let added: [JSONValue] = plan.spoken.compactMap { spoken in
            guard let clip = state.clip(with: spoken.clip.id), let location = state.location(of: clip.id) else { return nil }
            return [
                "id": .string(ids.short(clip.id)),
                "track": .string(AITrackName.name(of: location.track)),
                "start": AIFormat.seconds(clip.timelineStart),
                "end": AIFormat.seconds(clip.timelineEnd),
                "file": .string(AIWorkspace.shared.display(spoken.output.url)),
                "text": .string(spoken.line.text)
            ]
        }
        var voice: [String: JSONValue] = [
            "name": .string(plan.choice.name), "quality": .string(plan.choice.qualityName)
        ]
        if let note = plan.choice.note { voice["note"] = .string(note) }
        var result: [String: JSONValue] = ["added": .array(added), "voice": .object(voice),
                                           "timeline_duration": AIFormat.seconds(state.duration)]
        if plan.subtitles {
            var summary: [String: JSONValue] = ["added": .number(Double(subtitles.added.count))]
            if subtitles.skipped > 0 {
                summary["skipped"] = .string("\(subtitles.skipped) lines overlap subtitles that were already there and were not added.")
            }
            if let refusal = subtitles.refusal { summary["note"] = .string(refusal) }
            // Sky Studio 没报词时间（或报的读不出来）：那几句就没有字幕，别让 AI 以为加上了。
            if case .skyStudio = plan.choice.engine, plan.spoken.contains(where: { $0.output.words.isEmpty }) {
                let note = "Sky Studio did not say when each word is spoken for some lines, so those lines have no subtitles. "
                    + "Run generate_subtitles on the voiceover clips, or use SkyCut's own voice."
                summary["note"] = .string([summary["note"]?.stringValue, note].compactMap { $0 }.joined(separator: " "))
            }
            result["subtitles"] = .object(summary)
        }
        let first = plan.spoken.compactMap { state.clip(with: $0.clip.id)?.timelineStart }.min()
        AIEditorPresenter.reveal(.init(clips: Set(plan.spoken.map(\.clip.id)), time: first), project: project)
        return .ok(.object(result), changed: true)
    }
}
