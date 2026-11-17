import Foundation
import SrtFlowMCPKit

// Exercises the production generation-result notice without network requests or media changes.
// The wiring guard separately requires this projection in both finish and original-job refresh.
func runGenerationDurationChecks() {
    func generation(_ kind: SkyStudioGeneration.Kind = .music, _ duration: Double? = 76) -> SkyStudioGeneration {
        SkyStudioGeneration.make(kind, prompt: "synthetic duration check", ask: .init(duration: duration), canvas: 16.0 / 9)
    }
    func result(_ duration: Double?) -> SkyStudioJobResult {
        var value = SkyStudioJobResult(json: ["url": "https://example.invalid/synthetic.wav"])!
        value.duration = duration
        return value
    }
    func fields(_ requested: Double?, _ actual: Double?) -> [String: JSONValue] {
        SkyStudioGenerationDuration.fields(for: generation(.soundEffect, requested), result: result(actual))
    }

    let music = generation()
    let shortResult = result(73.4)
    let short = SkyStudioGenerationDuration.fields(for: music, result: shortResult)
    checkEqual(short["requested_duration"], 76, "the requested music length is reported beside the result")
    checkEqual(short["duration"], 73.4, "a shorter reported result is not replaced by the requested length")
    check(short["duration_warning"]?.stringValue?.contains("76.000 s") == true
        && short["duration_warning"]?.stringValue?.contains("73.400 s") == true,
        "a difference above one second names both lengths")
    checkEqual(music.params["duration"], 76, "the duration notice leaves the generation request unchanged")
    checkEqual(shortResult.duration, 73.4, "the duration notice leaves the result unchanged")

    for (requested, actual) in [(20.0, 123.6), (6.0, 9.0), (76.0, 73.4)] {
        check(fields(requested, actual)["duration_warning"]?.stringValue != nil,
            "both longer and shorter deliveries warn above one second: \(requested), \(actual)")
    }
    for actual in [5.0, 5.0001, 6.0, 6.9999, 7.0] {
        let value = fields(6, actual)
        checkEqual(value["duration_warning"], .null, "differences of at most one second do not warn: \(actual)")
        checkEqual(value["duration"], .number(actual), "the unrounded actual duration is preserved: \(actual)")
    }
    check(fields(6, 7.0001)["duration_warning"]?.stringValue != nil, "the warning threshold is strictly greater than one second")
    check(fields(6, 4.9999)["duration_warning"]?.stringValue != nil, "the strict threshold also applies to short deliveries")

    let automatic = SkyStudioGenerationDuration.fields(for: generation(.music, nil), result: result(123.6))
    checkEqual(automatic["requested_duration"], .null, "automatic music does not invent a requested length")
    checkEqual(automatic["duration"], 123.6, "automatic music still reports its actual result length")
    checkEqual(automatic["duration_warning"], .null, "automatic music has no numeric target to compare")
    for actual in [nil, 0.0, -1.0, Double.nan, Double.infinity] as [Double?] {
        let value = fields(6, actual)
        checkEqual(value["requested_duration"], 6, "an unknown result preserves the requested length")
        checkEqual(value["duration"], .null, "missing or invalid result duration remains unknown")
        checkEqual(value["duration_warning"], .null, "an unknown result cannot claim a measured mismatch")
        check(value["duration_note"]?.stringValue?.contains("unknown") == true, "unknown result duration is explained")
    }
    let noResult = SkyStudioGenerationDuration.fields(for: music, result: nil)
    checkEqual(noResult["duration"], .null, "no result is not reported as the requested duration")
    checkEqual(noResult["requested_duration"], 76, "failed delivery retains the requested specification")
    for requested in [0.0, -1.0, .nan, .infinity] {
        var invalid = music
        invalid.params["duration"] = .number(requested)
        let value = SkyStudioGenerationDuration.fields(for: invalid, result: result(6))
        checkEqual(value["requested_duration"], .null, "invalid requested duration does not enter the response")
        checkEqual(value["duration_warning"], .null, "invalid requested duration does not cause a warning")
    }

    let refreshed = short.merging(SkyStudioGenerationDuration.fields(for: music, result: result(76))) { _, current in current }
    checkEqual(refreshed["duration"], 76, "original-job refresh replaces the old result length")
    checkEqual(refreshed["duration_warning"], .null, "a corrected original result clears the earlier mismatch warning")
    checkEqual(refreshed["duration_note"], .null, "a known original result clears an unknown-duration note")
    let unknown = refreshed.merging(noResult) { _, current in current }
    checkEqual(unknown["duration"], .null, "a refresh without a valid result cannot retain a stale known duration")
    checkEqual(SkyStudioGenerationDuration.fields(for: generation(.image, nil), result: result(4)), [:],
        "images have no duration report even when unexpected duration metadata is present")
}
