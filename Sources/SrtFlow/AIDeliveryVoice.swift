import Foundation
import SrtFlowMCPKit

// MARK: - The voice check of listen voice=… inside the delivery report (MCP-39; report only)
//
// Owns: which voice the report checks (AIDeliverySoundRoles.voiceTracks: audio tracks where every clip is voice — our
// voice-overs, or tracks / clips the AI named voice in `sounds`), the plan over the checked range (AIListenVoicePlan, the same
// one listen voice=… makes) and turning each measured line into report entries through AIListenVoiceReport, so the verdict,
// the maskers and the grey hint are listen's own (VoiceClarity's tiers, listening-engine.md section 7):
// - `probably_unintelligible` / `may_be_hard` → `audio_voice_masked`; `two_voices` → `audio_two_voices`;
// - a clear line with the grey hint ("clear, but A2 may be loud") → `audio_voice_loud`, which the report lists apart from the
//   suspects in `hints` (FL-61: not a warning, not counted with them; intentional marks still apply).
// A voice clip that shares its track with other sounds, or sits on a video track, can't be measured (no clean voice): the report
// says so in limitations. Measuring is AIListenVoiceMeasure (blocking, the export's configuration before the limiter).
// Not here: the tiers (VoiceClarity), the measurement (AIListenVoiceMeasure), the music swell (AIDeliveryMusicSwell).

enum AIDeliveryVoice {
    struct Outcome: Sendable {
        let plan: AIListenVoicePlan
        let lines: [AIListenVoiceMeasure.Line]
        /// AIListenVoiceReport's entry per line, in the order of `lines`.
        let entries: [JSONValue]
    }

    /// Report kinds that are grey hints, listed apart from the suspects.
    static let hintKinds: Set<String> = ["audio_voice_loud"]

    /// The voice plan over the checked range, or why there is none (nil, nil: no voice to check).
    @MainActor
    static func plan(_ roles: AIDeliverySoundRoles, state: TimelineState, layout: AudioEngineConfig,
                     scope: AIInspection.Scope) -> (plan: AIListenVoicePlan?, limitation: String?) {
        guard !roles.voiceTracks.isEmpty else { return (nil, nil) }
        let range = scope.ranges.first.map { ($0.lowerBound, $0.upperBound) } ?? (0, scope.duration)
        // The maskers are named by the same roles the rest of the report uses (the AI's `sounds` included).
        let base = AIListenVoiceCheck.provenance()
        let known = roles.roles.mapValues { role -> AIListenVoicePlan.Kind in
            switch role {
            case .voice: return .voice
            case .music: return .music
            case .effects: return .effects
            case .camera: return .clipSound
            case .ambience, .object, .other: return .other
            }
        }
        do {
            let plan = try AIListenVoicePlan.make(roles.voiceTracks.joined(separator: "+"), state: state, config: layout,
                                                  from: range.0, to: range.1,
                                                  provenance: .init(library: base.library, folders: base.folders, known: known))
            let more = plan.moreClips > 0 ? "Voice clarity checked the first \(AIListenVoicePlan.maxClips) voice clips only; "
                + "inspect a narrower from/to for the other \(plan.moreClips)." : nil
            return (plan, more)
        } catch let error as AIToolError where error.message.hasPrefix("No voice clip plays") {
            return (nil, nil)
        } catch {
            return (nil, "Voice clarity was not checked: \((error as? AIToolError)?.message ?? error.localizedDescription)")
        }
    }

    @MainActor
    static func outcome(_ plan: AIListenVoicePlan, lines: [AIListenVoiceMeasure.Line], state: TimelineState) -> Outcome {
        let ids = AIShortIDs(state: state)
        let short = Dictionary(plan.clips.map { ($0.id, ids.short($0.id)) }) { first, _ in first }
        let report = AIListenVoiceReport.json(lines, plan: plan, shortIDs: short)
        return Outcome(plan: plan, lines: lines, entries: report["lines"]?.arrayValue ?? [])
    }

    // MARK: Report entries

    static func findings(_ outcome: Outcome?, scope: AIInspection.Scope) -> [AIInspection.Finding] {
        guard let outcome else { return [] }
        return zip(outcome.lines, outcome.entries).compactMap { line, entry in
            guard scope.intersects(line.from, line.to), let verdict = entry["verdict"]?.stringValue else { return nil }
            let masker = entry["maskers"]?.arrayValue?.first
            let who = masker.map { m in
                String(format: " Mostly covered by %@ (%@): removing it adds %+.2f.", m["layer"]?.stringValue ?? "?",
                       m["kind"]?.stringValue ?? "other", m["removed"]?.doubleValue ?? 0)
            } ?? ""
            let estoi = entry["estoi"]?.doubleValue ?? 0
            var details: [String: JSONValue] = ["verdict": .string(verdict), "estoi": .number(estoi)]
            for key in ["maskers", "low_150_db", "voice_db"] { if let value = entry[key] { details[key] = value } }
            let kind: String, reason: String
            switch verdict {
            case VoiceClarity.Verdict.probablyUnintelligible.rawValue, VoiceClarity.Verdict.mayBeHard.rawValue:
                kind = "audio_voice_masked"
                reason = String(format: "This line may be hard to make out in the mix (ESTOI %.2f, %@).", estoi, verdict.replacingOccurrences(of: "_", with: " "))
                    + who + " Listen to it; lower that layer, or mark it intentional."
            case VoiceClarity.Verdict.twoVoices.rawValue:
                kind = "audio_two_voices"
                reason = String(format: "Another voice speaks over this line (ESTOI %.2f).", estoi) + who + " Listen to it, or mark it intentional."
            default:
                guard let hint = entry["hint"]?.stringValue else { return nil }
                kind = "audio_voice_loud"
                details["hint"] = .string(hint)
                reason = String(format: "Grey hint, not a suspect: the line is clear (ESTOI %.2f), but %@.", estoi, hint.replacingOccurrences(of: "clear, but ", with: ""))
            }
            return AIInspection.Finding(kind: kind, from: line.from, to: line.to, reason: reason, items: [line.clip.id], details: details)
        }
    }
}

// MARK: - Music swelling under a line (MCP-39 suggestion 3; a reminder, report only)
//
// The music (the music role group) in the voice band (300–3000 Hz), as a running 1 s median over a line, rising at least
// `riseDB` above where it was when the line began — "the second half is easier to cover" (the second draft's last line: music
// +9 dB, +12 dB in the voice band, the one the user could not hear; the fourth draft's "I'm going to walk": +10 dB). Only lines
// with music heard (above `heardDB`) for at least `heardShare` of the line. Lines are the voice check's lines.
// Same reading as preview board v1.2's music_swell (thresholds unchanged); not validated beyond those drafts.

enum AIDeliveryMusicSwell {
    static let riseDB = 6.0
    static let window = 1.0
    static let heardDB = -60.0
    static let heardShare = 0.3

    static func findings(_ voice: AIDeliveryVoice.Outcome?, levels: AIDeliverySoundLevels, sounds: [AIDeliveryCutJumps.Sound],
                         scope: AIInspection.Scope) -> [AIInspection.Finding] {
        guard let voice, levels.frames[.music] != nil else { return [] }
        return voice.lines.compactMap { line in
            guard scope.intersects(line.from, line.to),
                  let rise = rise(levels: levels, from: line.from, to: line.to), rise.db >= riseDB else { return nil }
            let music = sounds.filter { $0.role == .music && $0.start < line.to && $0.end > line.from }.map(\.id)
            return AIInspection.Finding(
                kind: "audio_music_swell", from: line.from, to: line.to,
                reason: String(format: "Music rises %.0f dB in the voice band (300–3000 Hz, 1 s median) during this line, peaking at %.2f s: "
                    + "the rest of the line is easier to cover. Keep the music level under the words, or mark it intentional.", rise.db, rise.at),
                items: [line.clip.id] + music,
                details: ["rise_db": .number((rise.db * 10).rounded() / 10), "peak_at": .number((rise.at * 1000).rounded() / 1000)])
        }
    }

    /// How far the running median of the music's voice band climbs above its value at the line's start, and where it peaks.
    static func rise(levels: AIDeliverySoundLevels, from: Double, to: Double) -> (db: Double, at: Double)? {
        let first = levels.grid.frame(containing: from), last = levels.grid.frame(endingAt: to)
        guard last > first else { return nil }
        let music = (first ..< last).map { levels.db(.music, frame: $0, band: .voice) }
        guard Double(music.filter { $0 > heardDB }.count) / Double(music.count) >= heardShare else { return nil }
        let clamped = music.map { max($0, heardDB) }
        let half = max(1, Int((window * Double(levels.grid.fps) / 2).rounded()))
        let rolling = clamped.indices.map { index -> Double in
            let part = clamped[max(0, index - half) ..< min(clamped.count, index + half)].sorted()
            return part.count % 2 == 1 ? part[part.count / 2] : (part[part.count / 2 - 1] + part[part.count / 2]) / 2
        }
        guard let peak = rolling.indices.max(by: { rolling[$0] < rolling[$1] }) else { return nil }
        return (rolling[peak] - rolling[0], levels.grid.seconds(ofFrame: first + peak))
    }
}
