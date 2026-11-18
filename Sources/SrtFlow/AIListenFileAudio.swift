import Foundation
import SrtFlowMCPKit

// 管什么：文件 listen 的生产入口：读一遍这一窗的采样（AIListenAudioWindow），统一电平/静音结果与完成说明。
// Since 2026-11-17 every file listen reads its window once — the named range, or the whole file — because the true peak
// and the loudest frame need the samples (AIListenSampleFrames / AIListenPeaks); it no longer reports from the shared
// whole-file waveform (`waveform(of:until:)` stays for the tools that only need levels: cut_speech, cuts=true, inspect_video).
// 不管什么：路径权限（AIListenTool）、原生解码（AIListenAudioWindow）、波形 UI、听觉理解或试听。

@MainActor
enum AIListenFileAudio {
    static func listen(
        _ url: URL, args: AIToolArguments, display: String, silenceDB: Double, minSilence: Double,
        beats: Bool, frames grid: AIListenFrameGrid, until deadline: Date
    ) async throws -> [String: JSONValue] {
        let sourceIn = try args.double("source_in")
        let sourceOut = try args.double("source_out")
        let reading = try await AIListenAudioWindow.read(url, from: sourceIn, to: sourceOut, until: deadline,
                                                         frames: { from, to in grid.bounds(from: from, to: to) })
        let windows = reading.windows
        let (from, to, fileDuration) = (reading.from, reading.to, reading.fileDuration)
        let report = AIAudioLevels.report(windows, silenceDB: silenceDB, minSilence: minSilence)
        let peaks = Self.peaks(reading, grid: grid)
        var object: [String: JSONValue] = [
            "listened_to": .string(display), "from": AIFormat.seconds(from), "to": AIFormat.seconds(to)
        ]
        for (key, value) in AIAudioLevels.json(report, curve: AIAudioLevels.curve(windows), peaks: peaks, detailed: true) {
            object[key] = value
        }
        if beats {
            // 节拍沿用短音乐的整首共享分析合同；长文件不给它暗中扩展成整段音轨解码。
            if fileDuration > AIBeats.maxSeconds {
                object["beats"] = "not analyzed: this file exceeds the 15-minute music analysis limit; use beats=false for bounded source-range levels and silences"
                object["beat_note"] = "No beat decoding was started. Source-range levels and silences above are independent of beat analysis."
            } else {
                let end = sourceOut ?? fileDuration
                let analysis = try await AIBeats.music(of: url, from: from, to: end)
                for (key, value) in AIBeats.json(analysis, sourceFrom: from, sourceTo: end, speed: 1, timeline: { $0 }) {
                    object[key] = value
                }
                let scope = "Beat analysis uses a shared whole-song window (up to 15 minutes), not only source_in/source_out."
                object["beat_note"] = .string([scope, object["beat_note"]?.stringValue].compactMap { $0 }.joined(separator: " "))
            }
        }
        return object
    }

    /// A file's frames are counted from its start; nothing is applied to its sound.
    private static func peaks(_ reading: AIListenAudioWindow.Reading, grid: AIListenFrameGrid) -> AIListenPeaks {
        guard let frames = reading.frames else { return AIListenPeaks(truePeakDB: -60, peakAt: nil, loudestAt: nil) }
        let starts = Array(grid.bounds(from: reading.from, to: reading.to).dropLast())
        let rate = reading.peaks.sampleRate
        return AIListenPeaks.measure(frames, starts: starts, time: { reading.sourceStart + Double($0) / rate })
    }

    /// UI/时间线消费者共用的整文件波形。超时只结束等待，不取消其他消费者的共享任务。
    static func waveform(of url: URL, until deadline: Date) async -> WaveformPeaks? {
        let reader = Task { () -> WaveformPeaks? in
            var latest: WaveformPeaks?
            for await snapshot in await WaveformStore.shared.peaks(for: url) { latest = snapshot }
            return latest
        }
        let wait = max(0, deadline.timeIntervalSinceNow)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            reader.cancel()
        }
        let result = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
        timer.cancel()
        return result
    }
}
