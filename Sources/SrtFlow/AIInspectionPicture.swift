import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 成片检查的画面那一半：抽帧看黑场、成片逐帧扫、每段对着素材的刀
//
// 管什么（inspect_video 的画面疑点，只报不改）：
// - 抽帧（每 0.5 秒、最多 120 帧，结尾和范围两头优先）看黑场：连着几帧都黑的合成一条，写多长（MCP-14 B）。
// - 给了 file：成片**每一帧**扫一遍（`AIShotScan` 同一次解码、`AIFrameScan` 判）：夹帧、闪白、6 秒以上不动、黑场（MCP-64）。
//   扫到了，黑场就用逐帧的那一份（抽帧的不再报）。点名 from / to 时只报那一段，不点名报整个文件（默认范围是声音的接缝，
//   夹帧可能在任何一段的头尾）。
// - 交片前再查一遍放素材时那一条（MCP-36）：每段看得见的画面用到的源范围，跨过素材自己的刀、刀那一头只露出不到
//   `AIFrameScan.shortShot` 帧的，报 `source_cut`（哪一段、素材第几帧、建议的入点 / 出点）；时间线和成片两种都查。
// 门槛和来历见 docs/architecture/stray-frames.md；合同见 docs/architecture/finished-video-inspection.md。
// 不管什么：声音、字幕那几种疑点（AIInspection、AIInspectionTool）；怎么判（AIFrameScan、AISourceCuts）。

@MainActor
enum AIInspectionPicture {
    struct Outcome {
        var findings: [AIInspection.Finding] = []
        var sampled: [Double] = []
        var omitted = 0
        /// 逐帧扫了多少帧、扫的是哪一段（没给 file、没扫成是 nil）。
        var frameScan: JSONValue?
    }

    /// 成片逐帧扫最多等多少秒（它在任务里跑；没扫完照实报 limitations，扫描接着跑、进缓存）。
    static let scanSeconds = 180.0
    /// 交片前扫素材最多等多少秒。
    static let sourceSeconds = 90.0

    static func inspect(
        _ state: TimelineState, style: BurnInStyle, scope: AIInspection.Scope, named: ClosedRange<Double>?, file: URL?,
        limitations: inout [String], token: ExportCancellationToken
    ) async throws -> Outcome {
        var outcome = Outcome()
        guard !VideoEditExportGraph.isAudioOnly(state) else { return outcome }
        let sampling = AIInspection.sampleTimes(scope, frame: state.frameRate.secondsPerFrame)
        (outcome.sampled, outcome.omitted) = (sampling.times, sampling.omitted)
        var black: [Double] = []
        for start in stride(from: 0, to: sampling.times.count, by: 12) {
            if token.isCancelled { throw CancellationError() }
            let times = Array(sampling.times[start..<min(start + 12, sampling.times.count)])
            let batch = try await pictures(state, style: style, file: file, at: times)
            if batch.count != times.count { limitations.append("Some requested pictures were unreadable; missing frames were not treated as black.") }
            black += batch.filter { AIBlackBars.luma(of: $0.image).map(AIInspection.isBlack) ?? false }.map(\.time)
        }
        let range = named ?? 0...scope.duration
        var scanned = false
        if let file, let found = try await scanFile(file, state: state, range: range, limitations: &limitations, token: token) {
            outcome.findings += found.findings
            outcome.frameScan = found.summary
            scanned = true
        }
        if !scanned { outcome.findings += AIInspection.blackRuns(sampled: sampling.times, black: black) }
        outcome.findings += try await sourceCuts(state, range: range, limitations: &limitations, token: token)
        return outcome
    }

    /// 时间线那一刻的画面（时间线快照），或者成片文件里的那一帧。
    static func pictures(_ state: TimelineState, style: BurnInStyle, file: URL?, at times: [Double]) async throws -> [AIFrameSampler.Frame] {
        if let file { return await AIFrameSampler.frames(ofVideo: file, at: times, maxSide: 1280, tolerance: 0.001) }
        return try await AIFrameComposer.frames(of: state, at: times, subtitleStyle: style)
    }

    // MARK: 成片逐帧扫

    private static func scanFile(
        _ file: URL, state: TimelineState, range: ClosedRange<Double>, limitations: inout [String], token: ExportCancellationToken
    ) async throws -> (findings: [AIInspection.Finding], summary: JSONValue)? {
        _ = try? await AIShotScan.result(for: file, waiting: 0)
        let deadline = Date().addingTimeInterval(scanSeconds)
        while AIShotScan.isScanning(file), Date() < deadline {
            if token.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let result = AIShotScan.cached(file) else {
            limitations.append(AIShotScan.failure(of: file).map { "The frame-by-frame scan could not read the file: \($0)" }
                ?? "The frame-by-frame scan of the file did not finish in time; it keeps running, so inspect again shortly.")
            return nil
        }
        let signals = result.signals
        let found = AIFrameScan.findings(signals).compactMap { found -> AIInspection.Finding? in
            let from = signals.times[found.first], to = signals.end(of: found.last)
            guard from < range.upperBound, to > range.lowerBound else { return nil }
            let items = visiblePictures(state, from: from, to: to)
            // 画面上只有静帧（图片、定格）时一直不动是本来就该的样子。
            if found.kind == .frozen, !items.isEmpty, items.allSatisfy({ $0.isStillImage || $0.isScreenRecording }) { return nil }
            return AIInspection.Finding(kind: found.kind.rawValue, from: from, to: to,
                                        reason: reason(found, frames: found.last - found.first + 1, seconds: to - from, total: signals.count),
                                        items: items.map(\.id))
        }
        let summary: JSONValue = ["frames": .number(Double(signals.count)), "from": AIFormat.seconds(range.lowerBound),
                                  "to": AIFormat.seconds(range.upperBound)]
        return (found, summary)
    }

    private static func reason(_ found: AIFrameScan.Finding, frames: Int, seconds: Double, total: Int) -> String {
        let length = String(format: "%.2f", seconds)
        switch found.kind {
        case .strayFrames:
            let place = found.first == 0 ? "The video starts with" : found.last == total - 1 ? "The video ends with" : "There are"
            return "\(place) \(frames) frame(s) of a different picture between abrupt changes: a stray piece of another shot or a glitch. "
                + "Look at it; trim the clip if it is not wanted."
        case .flash:
            return "The picture flashes bright for \(frames) frame(s) and falls back within \(AIFrameScan.flashWindow) s; may be an intended flash."
        case .frozen:
            return "The picture does not move for \(length) s; may be an intended still or pause."
        case .black:
            return "\(length) s (\(frames) frames) of near-black picture; may be an intended fade or dark shot."
        }
    }

    // MARK: 每段对着素材的刀

    /// 看得见的画面段（轨没藏、段没藏、不是纯声音）里压着 [from, to) 的。
    static func visiblePictures(_ state: TimelineState, from: Double, to: Double) -> [EditClip] {
        let lanes = (state.mainHidden ? [] : [state.mainClips]) + state.overlayTracks.filter { !$0.isHidden }.map(\.clips)
        return lanes.flatMap { ClipVisibility.visible($0) }.filter {
            !$0.isAudioOnly && $0.timelineStart < to && $0.timelineEnd > from
        }
    }

    private static func sourceCuts(
        _ state: TimelineState, range: ClosedRange<Double>, limitations: inout [String], token: ExportCancellationToken
    ) async throws -> [AIInspection.Finding] {
        let clips = visiblePictures(state, from: range.lowerBound, to: range.upperBound).filter(AISourceCutCheck.checkable)
        await AISourceCutCheck.prepare(clips, seconds: sourceSeconds, anyLength: true) { token.isCancelled }
        if token.isCancelled { throw CancellationError() }
        var result: [AIInspection.Finding] = []
        var unscanned: [String] = []
        for clip in clips {
            guard let crossings = AISourceCutCheck.crossings(of: clip), let scanned = AIShotScan.cached(clip.sourceURL) else {
                unscanned.append(clip.name)
                continue
            }
            let step = scanned.signals.frameDuration
            // Short fragments and longer retained joins have separate report kinds.
            for crossing in crossings {
                let cut = clip.timelineTime(atSource: crossing.time)
                if crossing.kind == .twoShots {
                    if range.contains(cut) {
                        result.append(.init(kind: "source_cut_crossing", from: cut, to: cut,
                            reason: "\(clip.name) crosses a cut inside its source at frame \(crossing.frame); review whether keeping both shots is intentional.",
                            items: [clip.id], details: sourceCutDetails(crossing)))
                    }
                    continue
                }
                let (from, to): (Double, Double)
                switch crossing.kind {
                case .head: (from, to) = (clip.timelineStart, cut)
                case .tail: (from, to) = (cut, clip.timelineEnd)
                default: (from, to) = (cut, clip.timelineTime(atSource: crossing.time + Double(crossing.after) * step))
                }
                guard from < range.upperBound, to > range.lowerBound else { continue }
                result.append(.init(kind: "source_cut", from: from, to: to, reason: sourceCutReason(crossing, clip: clip),
                                    items: [clip.id], details: sourceCutDetails(crossing)))
            }
        }
        if !unscanned.isEmpty {
            limitations.append("Cuts inside these source files are not checked yet (still scanning): \(unscanned.sorted().joined(separator: ", ")).")
        }
        return result
    }

    private static func sourceCutReason(_ crossing: AISourceCuts.Crossing, clip: EditClip) -> String {
        let frames = crossing.shortFrames
        let at = String(format: "%.3f", crossing.time)
        switch crossing.kind {
        case .head:
            return "\(clip.name) starts with \(frames) frame(s) of the shot before a cut inside its file (frame \(crossing.frame), \(at) s). "
                + "Set source_in to \(at) to leave them out if they are not wanted."
        case .tail:
            return "\(clip.name) ends with \(frames) frame(s) of another shot: its file cuts at frame \(crossing.frame) (\(at) s). "
                + "Set source_out to \(at) to leave them out if they are not wanted."
        default:
            return "\(clip.name) shows a different picture for only \(frames) frame(s) from frame \(crossing.frame) of its file (\(at) s): "
                + "a flash or a glitch in the file."
        }
    }

    private static func sourceCutDetails(_ crossing: AISourceCuts.Crossing) -> [String: JSONValue] {
        var details: [String: JSONValue] = ["source_frame": .number(Double(crossing.frame)), "source_cut": AIFormat.seconds(crossing.time)]
        if let suggestion = crossing.suggestion { details[suggestion.key] = AIFormat.seconds(suggestion.value) }
        return details
    }
}
