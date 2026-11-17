import Foundation
import SrtFlowMCPKit

// MARK: - listen voice=…: the result for the AI (pure value)
//
// What: each measured line → where it is spoken (timeline seconds), its clip, its ESTOI against the whole mix, the verdict
// (VoiceClarity) and who covers it most: the two layers whose removal helps most, each with what it is (from where it came:
// music, effects, a clip's own sound, another voice, other) and how much removing it / lowering it 6 dB would raise the ESTOI;
// then the 20–150 Hz level of everything else next to the voice's own level (ESTOI can't see below ~134 Hz: numbers only, no
// verdict). A summary counts the verdicts. **Report only, never block.**
// Not here: measuring (AIListenVoiceMeasure), the lines (VoiceClarity's are in docs/architecture/listening-engine.md section 7).

enum AIListenVoiceReport {
    /// Maskers listed per line.
    static let maskersPerLine = 2

    /// `shortIDs`: each voice clip's short id (AIShortIDs, made on the main actor when the plan was).
    static func json(_ lines: [AIListenVoiceMeasure.Line], plan: AIListenVoicePlan, shortIDs: [UUID: String]) -> [String: JSONValue] {
        var counts: [VoiceClarity.Verdict: Int] = [:]
        let listed: [JSONValue] = lines.map { line in
            let entry = Self.line(line, plan: plan, shortIDs: shortIDs)
            counts[entry.verdict, default: 0] += 1
            return .object(entry.object)
        }
        var summary: [String: JSONValue] = ["lines": .number(Double(lines.count))]
        for verdict in VoiceClarity.Verdict.allCases where verdict != .clear {
            if let count = counts[verdict] { summary[verdict.rawValue] = .number(Double(count)) }
        }
        var object: [String: JSONValue] = [
            "voice": .array(plan.layers.filter(\.isVoice).map { .string($0.stem.name) }),
            "summary": .object(summary),
            "lines": .array(listed),
            "note": .string(
                "Report only, never blocks. estoi (0–1) is each line against the whole mix: below 0.31 probably unintelligible, "
                    + "0.31–0.41 may be hard (listen to it); when music covers it most, only below 0.20. maskers: what removing a "
                    + "layer, or lowering it 6 dB, would add. ESTOI can't hear below ~134 Hz: compare low_150_db with voice_db. "
                    + "A voice inside a clip's own sound (on-camera speech) can't be measured."
            )
        ]
        if plan.moreClips > 0 { object["more_clips"] = .number(Double(plan.moreClips)) }
        return object
    }

    private static func line(
        _ line: AIListenVoiceMeasure.Line, plan: AIListenVoicePlan, shortIDs: [UUID: String]
    ) -> (object: [String: JSONValue], verdict: VoiceClarity.Verdict) {
        var object: [String: JSONValue] = [
            "clip": .string(shortIDs[line.clip.id] ?? String(line.clip.id.uuidString.prefix(8)).lowercased()), "name": .string(String(line.clip.name.prefix(40))),
            "from": AIFormat.seconds(line.from), "to": AIFormat.seconds(line.to)
        ]
        guard let result = line.result else {
            object["verdict"] = .string(VoiceClarity.Verdict.tooShort.rawValue)
            return (object, .tooShort)
        }
        let layer = { (id: String) in plan.layers.first { $0.stem.name == id } }
        let maskers = result.gains.prefix(maskersPerLine).map { gain -> JSONValue in
            .object([
                "layer": .string(gain.id),
                "kind": .string((layer(gain.id)?.kind(from: line.from, to: line.to) ?? .other).rawValue),
                "removed": hundredths(gain.whenRemoved), "lowered": hundredths(gain.whenLowered), "level_db": tenths(gain.levelDBFS)
            ])
        }
        let main = result.gains.first.flatMap { layer($0.id)?.kind(from: line.from, to: line.to) }
        let anotherVoice = result.gains.contains { gain in
            layer(gain.id)?.isVoice == true && gain.levelDBFS >= VoiceClarity.speakingDBFS
        }
        let verdict = VoiceClarity.verdict(estoi: result.estoi.score, musicIsMainMasker: main == .music,
                                           anotherVoiceSpeaking: anotherVoice)
        object["estoi"] = hundredths(result.estoi.score)
        object["verdict"] = .string(verdict.rawValue)
        if !maskers.isEmpty { object["maskers"] = .array(maskers) }
        object["low_150_db"] = tenths(result.othersLowBandDBFS)
        object["voice_db"] = tenths(result.voiceDBFS)
        return (object, verdict)
    }

    private static func tenths(_ value: Double) -> JSONValue { .number(value.isFinite ? (value * 10).rounded() / 10 : -99) }
    private static func hundredths(_ value: Double) -> JSONValue { .number((value * 100).rounded() / 100) }
}
