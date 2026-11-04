import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MCP 成片检查的执行适配：冻结调用时的工程，长任务、权限、取消与媒体证据；没有提交/撤销/存工程的路径。
@MainActor
enum AIInspectionTool {
    static func start(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> AIToolResult {
        let state = project.state
        let scope = try AIInspection.scope(state: state, from: args.double("from"), to: args.double("to"))
        let db = try args.double("silence_db") ?? -45
        let minimum = try args.double("min_silence") ?? 0.5
        guard (-80 ... -10).contains(db), (0.1...10).contains(minimum) else {
            throw AIToolError("silence_db must be -80...-10; min_silence must be 0.1...10.")
        }
        let image = try args.bool("image") ?? true
        var file: URL?
        if let path = try args.string("file") {
            let url = AIWorkspace.shared.resolve(path)
            if let ask = try AIWorkspace.shared.confirmReading([url], verb: "inspect", args: args, project: project) { return ask }
            let asset = MediaAssetCache.asset(for: url).asset
            let duration = try await asset.load(.duration).seconds
            guard abs(duration - state.duration) <= max(0.1, state.frameRate.secondsPerFrame * 2) else {
                throw AIToolError("file must be an export of this timeline with matching timestamps/length; open the matching project first.")
            }
            file = url
        }
        let style = state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        let token = ExportCancellationToken()
        let job = AIJobs.shared.start(.inspection, progress: { nil }, cancel: { token.cancel() })
        let input = file
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-inspection-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let result = try await inspect(state, style: style, scope: scope, file: input, db: db, minimum: minimum,
                                               image: image, folder: folder, token: token)
                if token.isCancelled { throw CancellationError() }
                job.images = result.images
                AIJobs.shared.finish(job, .done, detail: result.payload)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                AIJobs.shared.finish(job, token.isCancelled ? .cancelled : .failed,
                                     message: (error as? AIToolError)?.message ?? error.localizedDescription)
            }
        }
        return .ok(["job_id": .string(job.id), "status": "running", "checked_ranges": scope.json,
                    "next_step": "Wait with get_job; findings are suspects only. The project will not be changed."])
    }

    private static func inspect(
        _ state: TimelineState, style: BurnInStyle, scope: AIInspection.Scope, file: URL?, db: Double, minimum: Double,
        image: Bool, folder: URL, token: ExportCancellationToken
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
        findings += try await cuts(state, config: config, scope: scope, limitations: &limitations, token: token)
        let hasPicture = !VideoEditExportGraph.isAudioOnly(state)
        let sampling = hasPicture ? AIInspection.sampleTimes(scope, frame: state.frameRate.secondsPerFrame) : (times: [Double](), omitted: 0)
        var frames: [AIFrameSampler.Frame] = []
        // 每批只保留少量大图；截图只保留疑点，黑场分析同 look 的亮度来源。
        var pictureFindings: [AIInspection.Finding] = []
        for start in stride(from: 0, to: sampling.times.count, by: 12) {
            try cancelled(token)
            let times = Array(sampling.times[start..<min(start + 12, sampling.times.count)])
            let batch = try await pictures(state, style: style, file: file, at: times)
            if batch.count != times.count { limitations.append("Some requested pictures were unreadable; missing frames were not treated as black.") }
            for frame in batch {
                if let luma = AIBlackBars.luma(of: frame.image), AIInspection.isBlack(luma) {
                    pictureFindings.append(.init(kind: "black_frame", from: frame.time, to: frame.time,
                                                 reason: "More than 99.5% of sampled pixels are near black; this may be an intended fade or dark shot."))
                    if frames.count < 6 { frames.append(frame) }
                }
            }
        }
        findings += pictureFindings
        findings.sort { $0.from < $1.from }
        let shown = Array(findings.prefix(150))
        let evidence = AIInspection.evidence(findings, duration: scope.duration)
        var seen: Set<Double> = []
        let evidenceTimes = evidence.map { min(max(0, $0.time), max(0, scope.duration - state.frameRate.secondsPerFrame)) }
        let wanted = hasPicture ? Array(evidenceTimes.filter { seen.insert($0).inserted }.prefix(6)) : []
        // 优先把音频和字幕疑点也画出来；同一刻的证据只取一次。
        if image { frames = try await pictures(state, style: style, file: file, at: wanted) }
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
            "coverage_complete": .bool(limitations.isEmpty && sampling.omitted == 0),
            "findings": .array(shown.map { $0.json(ids: ids) }), "more_findings": .number(Double(findings.count - shown.count)),
            "checked_ranges": scope.json, "sampled_picture_times": .array(sampling.times.map(AIFormat.seconds)),
            "omitted_picture_samples": .number(Double(sampling.omitted)), "auditions": .array(auditions),
            "screenshot_times": .array((image ? frames : []).map { AIFormat.seconds($0.time) }),
            "subtitle_style": ["font": .string(style.fontName), "font_size": .number(style.fontSize)],
            "limitations": .array(Array(Set(limitations)).sorted().map { .string($0) }),
            "note": "Suspects only, not proof of defects. Pictures are sampled (0.5 s spacing, up to 120); brief flashes may be missed. Source cuts and subtitle geometry use the frozen project; file pictures/audio use the supplied export. Same duration cannot prove the file matches. Transcripts are cache-only; no automatic edits. Auditions last this session."
        ]
        // 没有疑点就没有截图请求；仅在实际请求证据后失败才报告画不出来。
        return AILookTool.finish(&payload, frames: frames, size: .medium, wantsImage: image && !wanted.isEmpty)
    }

    private static func cuts(
        _ state: TimelineState, config: AudioEngineConfig, scope: AIInspection.Scope,
        limitations: inout [String], token: ExportCancellationToken
    ) async throws -> [AIInspection.Finding] {
        var result: [AIInspection.Finding] = []
        let deadline = Date().addingTimeInterval(40)
        var heard: [URL: AISpeechHearing] = [:]
        for track in config.tracks where track.fader > 0 && config.master > 0 {
            for segment in track.segments {
                try cancelled(token)
                guard scope.contains(segment.start) || scope.contains(segment.end), let clip = state.clip(with: segment.clipID) else { continue }
                if heard[segment.url] == nil {
                    if case .ready(let peaks) = await AISpeechCutTool.wholeFile(of: clip, until: deadline) {
                        let transcript = await AISpeechCutTool.transcript(of: clip, in: state, language: "auto")
                        heard[segment.url] = AISpeechHearing(levels: AIAudioLevels.windows(peaks, from: 0, to: peaks.duration), transcript: transcript?.words)
                    }
                }
                guard let hearing = heard[segment.url] else { limitations.append("Source cut analysis incomplete: \(clip.name)"); continue }
                for (at, side) in [(segment.start, AISpeechCutPoints.Side.start), (segment.end, .end)] where scope.contains(at) {
                    // 渐变/转场已把声音降下来的边不再当作截断。
                    let inside = side == .start ? at + 0.01 : at - 0.01
                    guard segment.gain.gain(at: inside) * track.fader * config.master > 0.1 else { continue }
                    let checked = AICutCheck.side(of: clip, end: side, at: at, sound: clip,
                                                 points: hearing.points(silenceDB: nil), frame: state.frameRate.secondsPerFrame)
                    if case .onSpeech(let word, let why) = checked.verdict {
                        result.append(.init(kind: "audio_cutoff", from: at, to: at,
                                            reason: "Source cut on audible sound (\(word ?? "no cached word")): \(why). May be intentional music or an effect.", items: [clip.id]))
                    }
                }
            }
        }
        return result
    }

    private static func pictures(_ state: TimelineState, style: BurnInStyle, file: URL?, at times: [Double]) async throws -> [AIFrameSampler.Frame] {
        if let file { return await AIFrameSampler.frames(ofVideo: file, at: times, maxSide: 1280, tolerance: 0.001) }
        return try await AIFrameComposer.frames(of: state, at: times, subtitleStyle: style)
    }

    private static func cancelled(_ token: ExportCancellationToken) throws {
        if token.isCancelled { throw CancellationError() }
    }
}
