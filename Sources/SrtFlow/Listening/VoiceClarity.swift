import Foundation

/// How hard a line of narration is to make out in the mix, in the tiers the user approved (2026-11-16「按建议」,
/// docs/architecture/listening-engine.md section 7): **report only, never block**.
///
/// What: a line's ESTOI against the full mix (`MaskerAttribution`), what is covering it most and whether another voice is
/// speaking at the same time → one verdict:
/// - another voice speaking in the line → `two_voices`, its own item (blind test: a second voice needs 0.48–0.65 where other
///   sounds need 0.30–0.38; no one line covers both);
/// - otherwise below 0.31 `probably_unintelligible`, 0.31–0.41 `may_be_hard` ("listen to it");
/// - when music is the main masker, only below 0.20 (`may_be_hard`): the blind test answered "clear" for music down to 0.22;
/// - too little speech for ESTOI (under ~0.4 s once silence is dropped) → `too_short`.
/// The low band (20–150 Hz, which ESTOI cannot see) is never judged here: the caller reports its numbers next to the voice's.
/// Where the lines come from: one listener, a few dozen items (ear-samples E09–E39, the 25-item blind test). They say where to
/// listen, they are not a measurement of intelligibility; recalibrate with the marks users leave (FL-59).
/// Not here: measuring (MaskerAttribution), which layer is music (the caller knows each layer's provenance), the report.
enum VoiceClarity {
    enum Verdict: String, Sendable, CaseIterable {
        case clear
        case mayBeHard = "may_be_hard"
        case probablyUnintelligible = "probably_unintelligible"
        case twoVoices = "two_voices"
        case tooShort = "too_short"
    }

    /// Below this: probably unintelligible.
    static let unintelligibleBelow = 0.31
    /// Below this (from `unintelligibleBelow` up): may be hard, listen to it.
    static let hardBelow = 0.41
    /// With music as the main masker, reported only below this.
    static let musicBelow = 0.20
    /// A grey suggestion below the warning tiers, based only on ear marks E34 and E35 (FL-61, 2026-11-17).
    static let hintBelow = 0.50
    static let hintRemovalGain = 0.25
    /// Another voice counts as speaking in a line when its level there reaches this (dBFS, the window's RMS): listen's
    /// silence threshold.
    static let speakingDBFS = -45.0

    static func verdict(estoi: Double?, musicIsMainMasker: Bool, anotherVoiceSpeaking: Bool) -> Verdict {
        if anotherVoiceSpeaking { return .twoVoices }
        guard let estoi else { return .tooShort }
        if musicIsMainMasker { return estoi < musicBelow ? .mayBeHard : .clear }
        if estoi < unintelligibleBelow { return .probablyUnintelligible }
        return estoi < hardBelow ? .mayBeHard : .clear
    }

    /// Only a clear line with one added main masker can get the optional "may be loud" suggestion. The caller excludes
    /// voices, a clip's own sound (including detached audio) and the joined rest layer. This never changes the verdict.
    static func hint(estoi: Double?, verdict: Verdict, mainMaskerIsAddedLayer: Bool, removalGain: Double?) -> Bool {
        guard verdict == .clear, let estoi, let removalGain else { return false }
        return estoi < hintBelow && mainMaskerIsAddedLayer && removalGain >= hintRemovalGain
    }
}
