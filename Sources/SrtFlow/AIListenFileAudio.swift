import Foundation
import SrtFlowMCPKit

// 管什么：文件 listen 的生产入口：显式区间只读该窗，整文件沿用共享波形；统一电平/静音结果与完成说明。
// 不管什么：路径权限（AIListenTool）、原生解码（AIListenAudioWindow）、波形 UI、听觉理解或试听。

@MainActor
enum AIListenFileAudio {
    static func listen(
        _ url: URL, args: AIToolArguments, display: String, silenceDB: Double, minSilence: Double,
        beats: Bool, until deadline: Date
    ) async throws -> [String: JSONValue] {
        let sourceIn = try args.double("source_in")
        let sourceOut = try args.double("source_out")
        let windows: [AIAudioLevels.Window]
        let from: Double
        let to: Double
        let fileDuration: Double?
        var note: String?
        if sourceIn != nil || sourceOut != nil {
            let reading = try await AIListenAudioWindow.read(url, from: sourceIn, to: sourceOut, until: deadline)
            windows = reading.windows
            from = reading.from
            to = reading.to
            fileDuration = reading.fileDuration
        } else {
            guard let peaks = await waveform(of: url, until: deadline) else {
                throw AIToolError("\(url.lastPathComponent) has no sound SkyCut can read.")
            }
            from = 0
            to = peaks.duration
            windows = AIAudioLevels.windows(peaks, from: from, to: to)
            fileDuration = beats ? try await AIListenAudioWindow.duration(of: url) : nil
            if !peaks.isComplete {
                note = "SkyCut has read the first \(String(format: "%.1f", peaks.duration)) s so far; this is a partial report, not the file duration. Call listen again for the rest."
            }
        }
        let report = AIAudioLevels.report(windows, silenceDB: silenceDB, minSilence: minSilence)
        var object: [String: JSONValue] = [
            "listened_to": .string(display), "from": AIFormat.seconds(from), "to": AIFormat.seconds(to)
        ]
        for (key, value) in AIAudioLevels.json(report, curve: AIAudioLevels.curve(windows), detailed: true) {
            object[key] = value
        }
        if let note { object["note"] = .string(note) }
        if beats {
            // 节拍沿用短音乐的整首共享分析合同；长文件不给它暗中扩展成整段音轨解码。
            if let fileDuration, fileDuration > AIBeats.maxSeconds {
                object["beats"] = "not analyzed: this file exceeds the 15-minute music analysis limit; use beats=false for bounded source-range levels and silences"
                object["beat_note"] = "No beat decoding was started. Source-range levels and silences above are independent of beat analysis."
            } else {
                let end = sourceOut ?? fileDuration ?? .infinity
                let analysis = try await AIBeats.analysis(of: url, from: from, to: end)
                for (key, value) in AIBeats.json(analysis, sourceFrom: from, sourceTo: end, speed: 1, timeline: { $0 }) {
                    object[key] = value
                }
                let scope = "Beat analysis uses a shared whole-song window (up to 15 minutes), not only source_in/source_out."
                object["beat_note"] = .string([scope, object["beat_note"]?.stringValue].compactMap { $0 }.joined(separator: " "))
            }
        }
        return object
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
