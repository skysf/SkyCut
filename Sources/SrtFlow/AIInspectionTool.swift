import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MCP 成片检查的执行适配：冻结调用时的工程，长任务、权限、取消与媒体证据；没有提交/撤销/存工程的路径。
// 画面那一半（抽帧黑场、成片逐帧扫、每段对着素材的刀）在 AIInspectionPicture；成片比工程旧先说一句在 AIInspectionFreshness。
@MainActor
enum AIInspectionTool {
    static func start(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let state = project.state
        let scope = try AIInspection.scope(state: state, from: args.double("from"), to: args.double("to"))
        // AI 点名的范围（画面逐帧的那几样只报这一段；没点名报整条，默认范围是声音的接缝）。
        let named = args.has("from") || args.has("to") ? scope.ranges.first : nil
        let db = try args.double("silence_db") ?? -45
        let minimum = try args.double("min_silence") ?? 0.5
        guard (-80 ... -10).contains(db), (0.1...10).contains(minimum) else {
            throw AIToolError("silence_db must be -80...-10; min_silence must be 0.1...10.")
        }
        let image = try args.bool("image") ?? true
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
        let token = ExportCancellationToken()
        let job = AIJobs.shared.start(.inspection, progress: { nil }, cancel: { token.cancel() })
        let input = file
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-inspection-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = try await inspect(state, style: style, scope: scope, named: named, file: input, attention: attention,
                                               db: db, minimum: minimum, image: image, folder: folder, token: token)
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
        attention: String?, db: Double, minimum: Double, image: Bool, folder: URL, token: ExportCancellationToken
    ) async throws -> AIToolResult {
        let ids = AIShortIDs(state: state)
        var findings = AIInspection.subtitles(state, style: style, scope: scope)
        let config = AudioEngineConfig.make(from: state)
        findings += AIInspection.overlaps(config, scope: scope)
        var limitations: [String] = []
        let audio: URL?
        if let file { audio = file } else { audio = try await AIInspectionAudio.mix(state, into: folder, cancellation: token) }
        if let audio {
            guard let peaks = await AIListenTool.waveform(of: audio, until: Date().addingTimeInterval(40)), peaks.isComplete else {
                throw AIToolError("Audio analysis is incomplete or unreadable; inspection has not passed. Try again.")
            }
            let levels = AIAudioLevels.windows(peaks, from: 0, to: scope.duration)
            findings += AIInspection.silence(levels, scope: scope, db: db, minimum: minimum)
            if scope.contains(scope.duration), let last = levels.last, last.decibels > -32 {
                findings.append(.init(kind: "audio_cutoff", from: max(0, scope.duration - 0.05), to: scope.duration,
                                      reason: "The mix is still above -32 dBFS in its final audio window; the ending may cut off abruptly."))
            }
        } else { limitations.append("No audible segments: there was no mixed audio to analyze.") }
        try cancelled(token)
        var unchecked: Set<UUID> = []
        findings += try await cuts(state, config: config, scope: scope, limitations: &limitations, unchecked: &unchecked, token: token)
        let hasPicture = !VideoEditExportGraph.isAudioOnly(state)
        let picture = try await AIInspectionPicture.inspect(state, style: style, scope: scope, named: named, file: file,
                                                            limitations: &limitations, token: token)
        findings += picture.findings
        findings.sort { $0.from < $1.from }
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
            for finding in evidence where finding.kind.hasPrefix("audio_") {
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
            "checked_ranges": scope.json, "sampled_picture_times": .array(picture.sampled.map(AIFormat.seconds)),
            "omitted_picture_samples": .number(Double(picture.omitted)), "auditions": .array(auditions),
            "screenshot_times": .array((image ? frames : []).map { AIFormat.seconds($0.time) }),
            "subtitle_style": ["font": .string(style.fontName), "font_size": .number(style.fontSize)],
            "limitations": .array(Array(Set(limitations)).sorted().map { .string($0) }),
            "note": "Suspects only, not proof of defects. With file, every frame is scanned (frame_scan); without it pictures are only sampled (0.5 s spacing, up to 120) and brief flashes may be missed. Source cuts and subtitle geometry use the frozen project; file pictures/audio use the supplied export. Same duration cannot prove the file matches. Cuts on speech are judged only from cached transcripts and narration subtitles; no automatic edits. Auditions last this session."
        ]
        if let scanned = picture.frameScan { payload["frame_scan"] = scanned }
        // 成片比工程旧：键名排在最前面（结果按键名排序），AI 第一眼就看到（MCP-65）。
        if let attention { payload["attention"] = .string(attention) }
        if !unchecked.isEmpty {
            payload["speech_unchecked"] = [
                "clips": .array(unchecked.map { ids.short($0) }.sorted().map { .string($0) }),
                "why": "These clips are cut where sound plays, but they have no transcript or narration subtitles, so SkyCut cannot tell whether a word is cut. Call transcribe on the ones with speech, then inspect again."
            ]
        }
        // 没有疑点就没有截图请求；仅在实际请求证据后失败才报告画不出来。
        return AILookTool.finish(&payload, frames: frames, size: .medium, wantsImage: image && !wanted.isEmpty)
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
