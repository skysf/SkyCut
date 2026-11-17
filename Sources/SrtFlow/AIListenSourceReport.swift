import Foundation
import SrtFlowMCPKit

// MARK: - listen describe=true: what a clip's own sound is, per 3 s window, for the AI (pure value)
//
// What: per 3 s window (seconds on the timeline for a clip, in the file for a file): SkyCut's traits and the nine numbers
// behind them (SourceSoundDescription), the classifier's strongest labels with each one's own score (SoundLabelScores; at most
// `labelsPerWindow`, none under `labelFloor`), and how many words the speech recogniser found there; then a summary (how many
// windows carry each trait, the labels by average score, words in all). **Words, never "music / not music".**
// Not here: reading or measuring (AIListenSourceSound and the measures), the lines behind the traits
// (docs/architecture/listening-engine.md section 5).

enum AIListenSourceReport {
    static let labelsPerWindow = 5
    /// Labels scored under this are left out (the classifier gives every one of its ~300 labels a score).
    static let labelFloor = 0.05

    /// How the read's seconds land on the timeline: a clip (`seconds = start + (source − sourceStart) / speed`), or a file
    /// (`seconds = source`).
    struct Place: Sendable {
        var start: Double = 0
        var sourceStart: Double = 0
        var speed: Double = 1

        func seconds(atSource source: Double) -> Double { start + (source - sourceStart) / max(speed, 1e-9) }
    }

    /// A word the speech recogniser found: its start (source seconds) and text.
    struct Word: Sendable, Equatable {
        let start: Double
        let text: String
    }

    /// What the speech recogniser found, or why it was not asked.
    enum Words: Sendable {
        case found([Word])
        case notChecked(String)
    }

    /// The words heard, as text, at most this many characters (enough to tell on-camera speech from noise).
    static let heardCharacters = 120

    /// `readStart`: the source second of the first sample; windows' starts are seconds from it.
    static func json(
        traits: [SourceSoundDescription.Window], labels: [SoundLabelScores.Window], words: Words,
        readStart: Double, readEnd: Double, place: Place
    ) -> [String: JSONValue] {
        let window = SourceSoundDescription.windowSeconds
        let count = Int(((readEnd - readStart) / window + 1e-9).rounded(.down))
        var traitCounts: [String: Int] = [:]
        var labelSums: [String: Double] = [:]
        var listed: [JSONValue] = []
        for index in 0 ..< count {
            let start = Double(index) * window
            var object: [String: JSONValue] = [
                "from": AIFormat.seconds(place.seconds(atSource: readStart + start)),
                "to": AIFormat.seconds(place.seconds(atSource: readStart + start + window))
            ]
            if let measured = traits.first(where: { abs($0.start - start) < 1e-6 }) {
                object["traits"] = .array(measured.traits.map { .string($0.rawValue) })
                object["measures"] = measures(measured.features)
                for trait in measured.traits { traitCounts[trait.rawValue, default: 0] += 1 }
            } else {
                object["traits"] = "quiet: nothing to describe"
            }
            if let classified = labels.first(where: { abs($0.start - start) < 0.01 }) {
                let strong = classified.labels.filter { $0.score >= labelFloor }.prefix(labelsPerWindow)
                object["labels"] = .array(strong.map { ["label": .string($0.name), "score": hundredths($0.score)] })
                for label in classified.labels { labelSums[label.name, default: 0] += label.score }
            }
            if case .found(let found) = words {
                object["words"] = .number(Double(found.filter { $0.start >= readStart + start && $0.start < readStart + start + window }.count))
            }
            listed.append(.object(object))
        }
        var summary: [String: JSONValue] = [
            "windows": .number(Double(count)),
            "traits": .object(traitCounts.mapValues { .number(Double($0)) })
        ]
        let average = labelSums.map { (name: $0.key, score: $0.value / Double(max(1, count))) }
            .filter { $0.score >= labelFloor }.sorted { $0.score > $1.score }.prefix(labelsPerWindow)
        summary["labels"] = .array(average.map { ["label": .string($0.name), "score": hundredths($0.score)] })
        switch words {
        case .found(let found):
            summary["words"] = .number(Double(found.count))
            if !found.isEmpty {
                summary["heard"] = .string(String(found.map(\.text).joined(separator: " ").prefix(heardCharacters)))
            }
        case .notChecked(let reason):
            summary["words"] = .string("not checked: \(reason)")
        }
        return [
            "windows": .array(listed),
            "summary": .object(summary),
            "note": .string(
                "Words, not a verdict. traits: SkyCut's measures (low_drone, broadband_noise, pitched, rhythmic, speech_like; "
                    + "thresholds from one film). labels: macOS's sound classifier, each label's own score (it calls a low drone "
                    + "music). words: what the on-device speech recogniser found."
            )
        ]
    }

    private static func measures(_ f: SourceSoundFeatures) -> JSONValue {
        var object: [String: JSONValue] = [
            "centroid_hz": .number(f.centroidHz.rounded()), "flatness": thousandths(f.flatness), "low_share": hundredths(f.lowShare),
            "chroma_top3": hundredths(f.chromaTop3), "level_spread_db": tenths(f.levelSpreadDB), "syllabic": hundredths(f.syllabicShare)
        ]
        if let value = f.chromaStability { object["chroma_stability"] = hundredths(value) }
        if let value = f.pitchStrength { object["pitch_strength"] = hundredths(value) }
        if let value = f.pulseClarity { object["pulse"] = hundredths(value) }
        return .object(object)
    }

    private static func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
    private static func hundredths(_ value: Double) -> JSONValue { .number((value * 100).rounded() / 100) }
    private static func thousandths(_ value: Double) -> JSONValue { .number((value * 1000).rounded() / 1000) }
}
