import Foundation
import SrtFlowMCPKit

// Tier-one mix rules over measured project frames. Thresholds are review heuristics, never gates;
// measuring and rendering remain in MixMeasurement and AIInspectionMeasurement.
enum AIDeliveryMix {
    struct Frame: Sendable {
        var from: Double
        var to: Double
        var power: Double
        var peak: Float
        var outputPeak: Float
        var minGain: Float
        var layers: [(name: String, power: Double)]
        var db: Double { 10 * log10(max(power, 1e-12)) }
        var active: Int { layers.filter { $0.power > 1e-6 }.count }
    }
    static let thinDB = -30.0
    static let thinSeconds = 0.75
    static let holeDropDB = 12.0
    static let holeSeconds = 0.5

    static func findings(_ frames: [Frame], scope: AIInspection.Scope, silenceDB: Double, minSilence: Double,
                         file: Bool) -> [AIInspection.Finding] {
        var result = runs(frames, scope: scope, minimum: minSilence, kind: "audio_silence",
                          reason: "Mixed output stays below \(silenceDB) dBFS; review whether this silence is intentional.") { $0.db < silenceDB }
        result += runs(frames, scope: scope, minimum: thinSeconds, kind: "audio_thin",
                       reason: "Mix below \(thinDB) dBFS with at most one audible layer for at least \(thinSeconds) s; may be intentionally sparse.") {
            $0.db >= silenceDB && $0.db < thinDB && $0.active <= 1
        }
        result += runs(frames, scope: scope, minimum: 0, kind: file ? "audio_true_peak" : "audio_overload",
                       reason: file ? "The export's decoded true peak exceeds the export limiter's ceiling; review the delivered file."
                        : "The timeline bus exceeds the export limiter's ceiling before limiting; this does not mean the delivered file clips.") {
            $0.peak > ExportPeakLimiter.defaultCeiling
        }
        if !file {
            result += runs(frames, scope: scope, minimum: 0, kind: "audio_limiter",
                           reason: "The export limiter reduces the timeline mix here; review the reduction and loudest layers.") { $0.minGain < 0.999 }
        }
        var i = 0
        while i < frames.count {
            let current = frames[i]
            var first = i
            while first > 0, frames[first - 1].to > current.from - holeSeconds { first -= 1 }
            let before = frames[first..<i]
            let span = before.reduce(0) { $0 + $1.to - $1.from }
            let baseline = before.reduce(0) { $0 + $1.power * ($1.to - $1.from) } / max(span, 1e-9)
            let db = 10 * log10(max(baseline, 1e-12))
            guard span >= holeSeconds - 1e-6, db > thinDB, db - current.db >= holeDropDB else { i += 1; continue }
            var end = i + 1
            while end < frames.count, db - frames[end].db >= holeDropDB { end += 1 }
            if frames[end - 1].to - current.from >= holeSeconds - 1e-6 {
                let slice = Array(frames[i..<end])
                if scope.intersects(current.from, slice.last!.to) {
                    result.append(finding("audio_hole", slice,
                        "The whole mix drops at least \(holeDropDB) dB below its preceding \(holeSeconds) s for at least \(holeSeconds) s; listen for an intended pause or a missing bed."))
                }
            }
            i = end
        }
        return result
    }

    private static func runs(_ frames: [Frame], scope: AIInspection.Scope, minimum: Double, kind: String, reason: String,
                             matches: (Frame) -> Bool) -> [AIInspection.Finding] {
        var result: [AIInspection.Finding] = []
        for range in scope.ranges {
            var run: [Frame] = []
            func close() {
                if let first = run.first, let last = run.last, last.to - first.from >= minimum - 1e-6 {
                    result.append(finding(kind, run, reason))
                }
                run = []
            }
            for var frame in frames where frame.to > range.lowerBound && frame.from < range.upperBound {
                frame.from = max(frame.from, range.lowerBound)
                frame.to = min(frame.to, range.upperBound)
                if matches(frame) { run.append(frame) } else { close() }
            }
            close()
        }
        return result
    }

    private static func finding(_ kind: String, _ frames: [Frame], _ reason: String) -> AIInspection.Finding {
        let peak = frames.map(\.peak).max() ?? 0
        let output = frames.map(\.outputPeak).max() ?? 0
        let reduction = -20 * log10(Double(max(frames.map(\.minGain).min() ?? 1, 1e-9)))
        return .init(kind: kind, from: frames.first!.from, to: frames.last!.to, reason: reason, details: [
            "peak_dbtp": .number(TruePeak.decibels(peak)), "output_peak_dbtp": .number(TruePeak.decibels(output)),
            "max_reduction_db": .number(reduction), "active_layers_min": .number(Double(frames.map(\.active).min() ?? 0)),
            "active_layers_max": .number(Double(frames.map(\.active).max() ?? 0))
        ])
    }

    static func loudest(_ finding: AIInspection.Finding, frames: [Frame]) -> JSONValue {
        let selected = frames.filter { $0.from <= finding.time && $0.to > finding.time }
        let layers = selected.first?.layers ?? []
        return .array(layers.filter { $0.power > 1e-12 }.sorted { $0.power > $1.power }.prefix(3).map {
            ["layer": .string($0.name), "level_dbfs": .number(10 * log10(max($0.power, 1e-12)))]
        })
    }
}
