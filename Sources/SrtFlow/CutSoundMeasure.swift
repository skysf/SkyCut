import Foundation
import SrtFlowMCPKit

// MARK: - 声音怎么过一刀：量电平、找拍子（App 这一层，要 await）
//
// 管什么：
// - 电平：一段声音的文件在测量窗（CutSoundWindows，按这段的「源 ↔ 时间线」换算）里的均方，换成 dB —— 读的是画波形那一份
//   （`WaveformStore`，一个文件只解一次、时间线上画波形已经在读；不另起一个读采样的循环，docs/architecture/blocking-media-reads.md）。
//   波形还没读到那里就等（最多 20 秒），等不到回 media_loading 让 AI 稍后同样再调；文件读不出声音当它是静的。
// - 拍子：on_beat 那段音乐的每一拍（`AIBeats`，listen 的 beats 和 cut_to_beat 同一份分析），换到时间线、只留这段放着的那几拍；
//   拍子不清楚（可信度低于 `AudioBeatTracker.clearConfidence`）就不踩，同 cut_to_beat。
// 不管什么：拿电平 / 拍子怎么改（CutSoundPlanner、CutSoundLevelPlan，纯值）。

@MainActor
enum CutSoundMeasure {
    /// 等波形最多多久。
    static let wait: TimeInterval = 20

    /// 一刀两边（和底）的素材电平。
    static func material(_ cut: CutSoundCut, layer: EditClip?, in state: TimelineState) async throws -> CutSoundPlanner.Material {
        let deadline = Date().addingTimeInterval(wait)
        var material = CutSoundPlanner.Material()
        if let voice = CutSoundCut.voice(of: cut.outgoing, in: state), let clip = state.clip(with: voice.id) {
            material.outgoing = try await level(clip, CutSoundWindows.outgoing(cut.time), until: deadline)
        }
        if let voice = CutSoundCut.voice(of: cut.incoming, in: state), let clip = state.clip(with: voice.id) {
            material.incoming = try await level(clip, CutSoundWindows.incoming(cut.time), until: deadline)
        }
        if let layer {
            material.layer = try await level(layer, CutSoundWindows.layer(cut.time), until: deadline)
        }
        return material
    }

    /// 文件在这段时间线窗里（按这段的换算）的均方 dB。静的 / 读不出声音是 nil。
    static func level(_ clip: EditClip, _ window: (from: Double, to: Double), until deadline: Date) async throws -> Double? {
        let from = max(0, clip.sourceTime(atTimeline: window.from))
        let to = min(clip.assetDuration, clip.sourceTime(atTimeline: window.to))
        guard to > from else { return nil }
        let reading = await waveform(clip.sourceURL, through: to, until: deadline)
        guard reading.finished || reading.peaks.map({ $0.duration >= to }) == true else {
            throw AIToolError(
                "SkyCut is still reading the sound of \(clip.name). Call set_transition again with the same arguments in a moment.",
                details: ["status": "media_loading", "retryable": true, "retry_after_ms": 2000]
            )
        }
        guard let peaks = reading.peaks, peaks.sampleRate > 0 else { return nil }
        let first = Int(from * peaks.sampleRate)
        let last = min(Int(to * peaks.sampleRate), peaks.framesAvailable)
        guard let meanSquare = peaks.meanSquare(channel: nil, from: first, to: last), meanSquare > 1e-10 else { return nil }
        return 10 * log10(meanSquare)
    }

    /// 等画波形那一份读到 `seconds` 那里（或读完）。`finished`：读完了（读不出声音的文件也算读完了、没有快照）。
    private static func waveform(_ url: URL, through seconds: Double, until deadline: Date) async -> (peaks: WaveformPeaks?, finished: Bool) {
        let reader = Task { () -> (WaveformPeaks?, Bool) in
            var latest: WaveformPeaks?
            for await snapshot in await WaveformStore.shared.peaks(for: url) {
                latest = snapshot
                if snapshot.isComplete { return (snapshot, true) }
                if snapshot.duration >= seconds { return (snapshot, false) }
            }
            return (latest, !Task.isCancelled)
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            reader.cancel()
        }
        let result = await reader.value
        timer.cancel()
        return result
    }

    /// on_beat：这段音乐在时间线上的每一拍（只留它放着的那几拍）。
    static func beats(of music: EditClip) async throws -> [Double] {
        let analysis = try await AIBeats.analysis(
            of: music.sourceURL, from: music.sourceStart, to: music.sourceStart + music.sourceDuration
        )
        guard let analysis, analysis.confidence >= AudioBeatTracker.clearConfidence else {
            throw AIToolError(
                "\(music.name) has no clear, steady beat, so a sound switch on it would not feel on time. Use another join, or pass "
                    + "layer_id for music with a clear beat (listen beats=true shows it). Nothing was changed."
            )
        }
        return analysis.beats.map { music.timelineTime(atSource: $0) }
            .filter { $0 >= music.timelineStart - 0.001 && $0 <= music.timelineEnd + 0.001 }
    }
}
