import Foundation

// MARK: - Voice band: lowering only 300 Hz–3 kHz of a clip's own sound — the setting's rule (pure)
//
// Owns (MCP-30, 2026-11-18): `EditClip.voiceBandDB` — its range (−30…0 dB, 0 = off), how a stored or requested value is cleaned
// (non-finite → 0, clamped into the range), and the middle band's linear gain the engine multiplies with (1 = off).
// Not here: the filter (AudioEngine/VoiceBandFilter.swift), where it runs (AudioTrackRenderer), the AI's parameter
// (AIClipDetails). Rules: docs/architecture/sound-scenes.md section 5.

enum VoiceBand {
    static let range: ClosedRange<Double> = -30...0

    static func sanitized(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(max(decibels, range.lowerBound), range.upperBound)
    }

    /// The middle band's gain for the engine (linear amplitude): 1 = off.
    static func bandGain(_ decibels: Double) -> Float {
        Float(pow(10, sanitized(decibels) / 20))
    }
}
