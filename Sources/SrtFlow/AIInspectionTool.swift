import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// Inspection freezes the project and reports suspects through a job. Explicit review requests
// delegate to AIInspectionReview and save only the requested intentional decision.
// 画面那一半（抽帧黑场、成片逐帧扫、每段对着素材的刀）在 AIInspectionPicture；成片比工程旧先说一句在 AIInspectionFreshness。
@MainActor
enum AIInspectionTool {
    private final class Run { var task: Task<Void, Never>? }

    static func start(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        if let reviewed = try AIInspectionReview.change(args, project: project) { return reviewed }
        let generation = project.documentGeneration
        let session = AICallContext.current?.session
        let state = project.state
        let scope = try AIInspection.scope(state: state, from: args.double("from"), to: args.double("to"))
        // An explicit range bounds the frame scan; otherwise the entire export is inspected.
        let named = args.has("from") || args.has("to") ? scope.ranges.first : nil
        let db = try args.double("silence_db") ?? -45
        let minimum = try args.double("min_silence") ?? 0.5
        guard (-80 ... -10).contains(db), (0.1...10).contains(minimum) else {
            throw AIToolError("silence_db must be -80...-10; min_silence must be 0.1...10.")
        }
        let image = try args.bool("image") ?? true
        let sounds = try AIDeliverySoundRoles.request(args, state: state)
        var file: URL?
        var attention: String?
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "inspect", args: args, project: project) { return ask }
            let asset = MediaAssetCache.asset(for: url).asset
            let duration = try await asset.load(.duration).seconds
            guard abs(duration - state.duration) <= max(0.1, state.frameRate.secondsPerFrame * 2) else {
                throw AIToolError("file must be an export of this timeline with matching timestamps/length; open the matching project first.")
            }
            file = url
            attention = AIInspectionFreshness.note(file: url, project: project)
        }
        let style = state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        // Frozen with the rest: does the editing style the film was cut with expect music (no music = suspect, not hint)?
        let musicStyle = AIDeliveryStyleMusic.expecting(state.editingStyle)
        let token = ExportCancellationToken()
        let run = Run()
        let job = AIJobs.shared.start(.inspection, progress: { nil }, cancel: { token.cancel(); run.task?.cancel() })
        let input = file
        run.task = Task {
            defer { run.task = nil }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-inspection-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = try await inspect(state, style: style, scope: scope, named: named, file: input, attention: attention,
                                               db: db, minimum: minimum, image: image, sounds: sounds, musicStyle: musicStyle,
                                               folder: folder, token: token, job: job.id, generation: generation, session: session)
                if token.isCancelled { throw CancellationError() }
                job.images = result.images
                AIJobs.shared.finish(job, .done, detail: result.payload)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                AIJobs.shared.finish(job, token.isCancelled ? .cancelled : .failed,
                                     message: (error as? AIToolError)?.message ?? error.localizedDescription)
            }
        }
        var started: [String: JSONValue] = ["job_id": .string(job.id), "status": "running", "checked_ranges": scope.json,
                                            "next_step": "Wait with get_job; findings are suspects only. The project will not be changed."]
        if let attention { started["attention"] = .string(attention) }
        return .ok(.object(started))
    }

    private static func inspect(
        _ state: TimelineState, style: BurnInStyle, scope: AIInspection.Scope, named: ClosedRange<Double>?, file: URL?,
        attention: String?, db: Double, minimum: Double, image: Bool, sounds: AIDeliverySoundRoles.Request,
        musicStyle: AIDeliveryStyleMusic.Style?, folder: URL, token: ExportCancellationToken, job: String, generation: Int,
        session: String?
    ) async throws -> AIToolResult {
        let ids = AIShortIDs(state: state)
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        var limitations: [String] = []
        let audio: URL?
        if let file { audio = file } else { audio = try await AIInspectionAudio.mix(state, into: folder, cancellation: token) }
        let measurement = try await AIInspectionMeasurement.measure(state, config: config, file: file, audio: audio, token: token)
        try cancelled(token)
        var unchecked: Set<UUID> = []
        var sourceSpeech = try await cuts(state, config: config, scope: scope, limitations: &limitations, unchecked: &unchecked, token: token)
        let hasPicture = !VideoEditExportGraph.isAudioOnly(state)
        let picture = try await AIInspectionPicture.inspect(state, style: style, scope: scope, named: named, file: file,
                                                            limitations: &limitations, token: token)
        if scope.contains(scope.duration), let last = measurement.frames.last, last.db > -32 {
            sourceSpeech.append(.init(kind: "audio_cutoff", from: max(0, scope.duration - 0.05), to: scope.duration,
                                      reason: "The final mixed frame is above -32 dBFS; review whether the abrupt ending is intentional."))
        }
        let spoken = try await AIDeliverySentences.collect(state, config: config, scope: scope, unchecked: &unchecked, token: token)
        let sound = try await AIDeliverySound.prepare(state, request: sounds, scope: scope, spoken: spoken, token: token)
        limitations += sound.limitations
        try cancelled(token)
        let all = try await AIDeliveryChecks.run(.init(state: state, scope: scope, style: style, config: config, measurement: measurement,
            spoken: spoken, picture: picture.findings, sourceSpeech: sourceSpeech, attention: attention,
            silenceDB: db, minimum: minimum, file: file != nil, sound: sound, musicStyle: musicStyle))
        let reviewed = AIInspectionReview.partition(all, state: state, job: job, generation: generation, session: session)
        // Grey hints are listed apart from the suspects: no evidence slots, not counted with them (FL-61).
        let hints = reviewed.findings.filter { AIDeliveryChecks.hintKinds.contains($0.kind) }
        let findings = reviewed.findings.filter { !AIDeliveryChecks.hintKinds.contains($0.kind) }
        var frames: [AIFrameSampler.Frame] = []
        let shown = Array(findings.prefix(150))
        let evidence = AIInspection.evidence(findings, duration: scope.duration)
        var seen: Set<Double> = []
        let evidenceTimes = evidence.map { min(max(0, $0.time), max(0, scope.duration - state.frameRate.secondsPerFrame)) }
        let wanted = hasPicture ? Array(evidenceTimes.filter { seen.insert($0).inserted }.prefix(6)) : []
        // 优先把音频和字幕疑点也画出来；同一刻的证据只取一次。
        if image { frames = try await AIInspectionPicture.pictures(state, style: style, file: file, at: wanted) }
        var auditions: [JSONValue] = []
        if let audio {
            var selected: [AIInspection.Finding] = []
            for finding in evidence where finding.kind.hasPrefix("audio_") || finding.kind == "sentence_cut" {
                if !selected.contains(where: { abs($0.time - finding.time) < 0.25 }) { selected.append(finding) }
            }
            for (index, finding) in selected.prefix(6).enumerated() {
                try cancelled(token)
                let from = min(max(0, finding.time - 1.5), max(0, scope.duration - 3))
                let to = min(scope.duration, from + 3)
                let output = folder.appendingPathComponent("audition-\(index + 1).wav")
                do {
                    try await AIInspectionAudio.audition(audio, from: from, to: to, output: output)
                    auditions.append(["path": .string(output.path), "from": AIFormat.seconds(from), "to": AIFormat.seconds(to),
                                      "finding_at": AIFormat.seconds(finding.time)])
                } catch { limitations.append("Could not write audition at \(finding.time): \(error.localizedDescription)") }
            }
        }
        if file == nil, let audio { try? FileManager.default.removeItem(at: audio) }
        var payload: [String: JSONValue] = [
            "inspected": .string(file?.path ?? "timeline snapshot"), "changed": false,
            "coverage_complete": .bool(limitations.isEmpty && picture.omitted == 0),
            "findings": .array(shown.map { $0.json(ids: ids) }), "more_findings": .number(Double(findings.count - shown.count)),
            "intentional": .array(reviewed.intentional), "mix_measurement": measurement.summary,
            "checks": .array(AIDeliveryChecks.registry.map { .string($0.id) }),
            "checked_ranges": scope.json, "sampled_picture_times": .array(picture.sampled.map(AIFormat.seconds)),
            "omitted_picture_samples": .number(Double(picture.omitted)), "auditions": .array(auditions),
            "screenshot_times": .array((image ? frames : []).map { AIFormat.seconds($0.time) }),
            "subtitle_style": ["font": .string(style.fontName), "font_size": .number(style.fontSize)],
            "limitations": .array(Array(Set(limitations)).sorted().map { .string($0) }),
            "note": "Suspects only, not proof of defects. With file, every frame is scanned (frame_scan); without it pictures are only sampled (0.5 s spacing, up to 120) and brief flashes may be missed. Layers, limiter history, source cuts and subtitle geometry use the frozen project; file pictures/audio use the supplied export. Same duration cannot prove the file matches. Cuts on speech are judged only from cached transcripts and narration subtitles; no automatic edits. Intentional findings are listed separately; mark one with intentional={job_id,key,reason}. Grey hints are suggestions, not suspects. sound_roles is what each track's sound was taken to be; correct it with sounds. Auditions last this session."
        ]
        if let scanned = picture.frameScan { payload["frame_scan"] = scanned }
        if !hints.isEmpty { payload["hints"] = .array(hints.map { $0.json(ids: ids) }) }
        if sound.roles.summary.objectValue?.isEmpty == false { payload["sound_roles"] = sound.roles.summary }
        // 成片比工程旧：键名排在最前面（结果按键名排序），AI 第一眼就看到（MCP-65）。
        if let attention { payload["attention"] = .string(attention) }
        if !unchecked.isEmpty {
            payload["speech_unchecked"] = [
                "clips": .array(unchecked.map { ids.short($0) }.sorted().map { .string($0) }),
                "why": "These clips are cut where sound plays, but they have no transcript or narration subtitles, so SkyCut cannot tell whether a word or sentence is cut. Call transcribe on the ones with speech, then inspect again."
            ]
        }
        // 没有疑点就没有截图请求；仅在实际请求证据后失败才报告画不出来。
        // The measured mix goes under the evidence screenshots (#n marks each one; MCP-66).
        let strip = frames.isEmpty ? nil : AISoundStripMeasure.inspection(measurement.frames, state: state, config: config, scope: scope)
        return AILookTool.finish(&payload, frames: frames, size: .medium, wantsImage: image && !wanted.isEmpty, sound: strip)
    }

    /// 素材切口：电平上切在有声处、又有人声证据说这一刻在说话，才报「切在说话上」（`AIInspectionSpeech`，MCP-14）；
    /// 没有人声证据的记进 `unchecked`（结果里的 `speech_unchecked`）。
    private static func cuts(
        _ state: TimelineState, config: AudioEngineConfig, scope: AIInspection.Scope,
        limitations: inout [String], unchecked: inout Set<UUID>, token: ExportCancellationToken
    ) async throws -> [AIInspection.Finding] {
        var result: [AIInspection.Finding] = []
        let deadline = Date().addingTimeInterval(40)
        var heard: [URL: AISpeechHearing] = [:]
        let subtitled = AIInspectionSpeech.subtitled(in: state)
        let frame = state.frameRate.secondsPerFrame
        for track in config.tracks where track.fader > 0 && config.master > 0 {
            for segment in track.segments {
                try cancelled(token)
                guard scope.contains(segment.start) || scope.contains(segment.end), let clip = state.clip(with: segment.clipID) else { continue }
                // 这一段的转写（缓存得盖住它用到的源秒才算；判切在不在词上用识别器原样的词）。
                let transcript = await AISpeechCutTool.transcript(of: clip, in: state, language: "auto")
                if heard[segment.url] == nil {
                    if case .ready(let peaks) = await AISpeechCutTool.wholeFile(of: clip, until: deadline) {
                        heard[segment.url] = AISpeechHearing(levels: AIAudioLevels.windows(peaks, from: 0, to: peaks.duration), transcript: transcript?.words)
                    }
                }
                guard let hearing = heard[segment.url] else { limitations.append("Source cut analysis incomplete: \(clip.name)"); continue }
                for (at, side) in [(segment.start, AISpeechCutPoints.Side.start), (segment.end, .end)] where scope.contains(at) {
                    // 渐变/转场已把声音降下来的边不再当作截断。
                    let inside = side == .start ? at + 0.01 : at - 0.01
                    guard segment.gain.gain(at: inside) * track.fader * config.master > 0.1 else { continue }
                    // 素材自己的头尾：什么都没切掉（音效、旁白、从头放的音乐都从第 0 秒开始）。
                    guard !AIInspectionSpeech.isFileEdge(clip, start: side == .start, tolerance: frame) else { continue }
                    let checked = AICutCheck.side(of: clip, end: side, at: at, sound: clip,
                                                 points: hearing.points(silenceDB: nil), frame: frame)
                    guard case .onSpeech(_, let why) = checked.verdict else { continue }
                    switch AIInspectionSpeech.voice(atSource: clip.sourceTime(atTimeline: at), words: transcript?.words, subtitles: subtitled[clip.sourceURL]) {
                    case .on(let said):
                        result.append(.init(kind: "audio_cutoff", from: at, to: at,
                                            reason: "Source cut on speech (\"\(said)\"): \(why).", items: [clip.id]))
                    case .off:
                        continue
                    case .unknown:
                        unchecked.insert(clip.id)
                    }
                }
            }
        }
        return result
    }

    private static func cancelled(_ token: ExportCancellationToken) throws {
        if token.isCancelled { throw CancellationError() }
    }
}
