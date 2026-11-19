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
    runDeliveredLengthChecks(music: music)
}

/// Sky Studio's own asked and delivered lengths (2026-11-19, Sky Studio "Lengths: asked and delivered", MCP-9): `requested_duration`
/// is preferred to the submitted params, `duration_source` passes through, and a refresh clears a stale source.
private func runDeliveredLengthChecks(music: SkyStudioGeneration) {
    func delivered(_ fields: [String: JSONValue]) -> SkyStudioJobResult {
        var json: [String: JSONValue] = ["url": "https://example.invalid/synthetic.mp3"]
        json.merge(fields) { _, new in new }
        return SkyStudioJobResult(json: .object(json))!
    }
    let exact = SkyStudioGeneration.make(.music, prompt: "x", ask: .init(duration: 12), canvas: 1)
    let padded = SkyStudioGenerationDuration.fields(for: exact, result: delivered(["duration": 12.04, "requested_duration": 12, "duration_source": "file"]))
    checkEqual(padded["duration"], 12.04, "an exact-length MP3 reads its encoder padding")
    checkEqual(padded["duration_source"], "file", "where the delivered length came from")
    checkEqual(padded["duration_warning"], .null, "MP3 padding is not a difference")
    let set = SkyStudioGenerationDuration.fields(for: music, result: delivered(["duration": 73.4, "requested_duration": 76, "duration_source": "file"]))
    check(set["duration_warning"]?.stringValue?.contains("76.000 s") == true, "an approximate set length more than 1 s off warns")
    let serverRounded = SkyStudioGenerationDuration.fields(for: exact, result: delivered(["duration": 12.3, "requested_duration": 12.3]))
    checkEqual(serverRounded["requested_duration"], 12.3, "Sky Studio's own asked length is preferred to the submitted params")
    let automatic = SkyStudioGenerationDuration.fields(for: SkyStudioGeneration.make(.music, prompt: "x", ask: .init(), canvas: 1),
        result: delivered(["duration": 158, "requested_duration": .null, "duration_source": "file"]))
    checkEqual(automatic["requested_duration"], .null, "an automatic length has nothing asked")
    checkEqual(automatic["duration_warning"], .null, "and nothing to compare")
    let unknown = SkyStudioGenerationDuration.fields(for: exact, result: delivered(["duration": .null, "requested_duration": 12, "duration_source": "file"]))
    checkEqual(unknown["duration"], .null, "an unread file stays unknown, never the request")
    checkEqual(unknown["duration_source"], .null, "an unknown length has no source")
    check(unknown["duration_note"]?.stringValue?.contains("add_clips places the file at its own measured length") == true,
          "the unknown note says how the real length is found")
    let older = SkyStudioGenerationDuration.fields(for: exact, result: delivered(["duration": 12.04]))
    checkEqual(older["requested_duration"], 12, "a result from before 2026-11-19 falls back to the submitted length")
    checkEqual(older["duration_source"], .null, "and says nothing of its source")
    let refreshed = padded.merging(older) { _, current in current }
    checkEqual(refreshed["duration_source"], .null, "a refresh without a source clears the old one")
}
