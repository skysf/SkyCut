import Foundation
import SrtFlowMCPKit

// MARK: - What get_job says about an export's sound (pure value)
//
// What: the mix levels of a finished export (ExportAudioMixdown.Levels) → the `audio_…` fields of the get_job result.
// - `audio_peak_dbtp`: the delivered peak — the true peak of the exported file's own sound (ExportDeliveredPeak), what a
//   player sees; left out when the file could not be measured.
// - The limiter's work, only when it worked, each field named for it: `audio_peak_before_limiter_dbtp` (the mix's true peak
//   before the −1 dBTP limiter), `audio_limited_seconds`, `audio_max_reduction_db`; a `note` when it pulled more than 3 dB.
// - `audio_loudness_lufs` as before (after the limiter, as delivered).
// Why: until 2026-11-17 the only peak was `audio_peak_dbfs`, the peak *before* the limiter (+5.6 on a mix whose file peaked
// at −0.5), which reads like a clipped file (docs/bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md).
// Not here: measuring (ExportAudioMixdown, ExportDeliveredPeak), the rest of the result (AIExportTools.finishedDetail).

enum ExportAudioReport {
    static func detail(_ levels: ExportAudioMixdown.Levels) -> [String: JSONValue] {
        var detail: [String: JSONValue] = [:]
        if let loudness = levels.loudnessLUFS { detail["audio_loudness_lufs"] = tenths(loudness) }
        if let delivered = levels.deliveredPeakDBTP { detail["audio_peak_dbtp"] = tenths(delivered) }
        guard levels.isLimited else { return detail }
        detail["audio_peak_before_limiter_dbtp"] = tenths(levels.peakDBTP)
        detail["audio_limited_seconds"] = .number((levels.limitedSeconds * 100).rounded() / 100)
        detail["audio_max_reduction_db"] = tenths(levels.maxReductionDB)
        if levels.needsAttention {
            detail["note"] = .string(String(
                format: "Before the limiter the mix peaked at %+.1f dBTP: it went over -1 dBTP for %.2f s and the limiter pulled it "
                    + "down by up to %.1f dB. Lower the master fader (set_track master volume_db) by about %.1f dB, or the loud "
                    + "clips, and export again for a cleaner mix.",
                levels.peakDBTP, levels.limitedSeconds, levels.maxReductionDB, levels.suggestedReductionDB
            ))
        }
        return detail
    }

    private static func tenths(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
}
