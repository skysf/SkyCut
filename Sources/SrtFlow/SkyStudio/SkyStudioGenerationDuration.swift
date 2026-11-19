import Foundation
import SrtFlowMCPKit

// Reports the asked duration beside Sky Studio's delivered result duration, including refreshes.
// This notice never measures, trims, pads, regenerates, or changes media or the timeline.
// Since 2026-11-19 (Sky Studio "Lengths: asked and delivered", MCP-9) the result carries its own honest fields: `duration` is the
// delivered length (never the request standing in; null when neither the file nor the provider gave one), `requested_duration` is
// what Sky Studio was asked (null for an automatic length; not sent for lip-sync, upscale or voice) and `duration_source` says where
// the delivered length came from (`file` / `provider`). The asked value prefers Sky Studio's; results from before that fall back to
// the submitted `generation.params`.
enum SkyStudioGenerationDuration {
    static func fields(for generation: SkyStudioGeneration, result: SkyStudioJobResult?) -> [String: JSONValue] {
        guard generation.kind != .image else { return [:] }
        let requested = positive(result?.metadata["requested_duration"]?.doubleValue) ?? positive(generation.params["duration"]?.doubleValue)
        let actual = positive(result?.duration)
        let source = actual == nil ? nil : result?.metadata["duration_source"]?.stringValue
        var fields: [String: JSONValue] = [
            "requested_duration": requested.map(JSONValue.number) ?? .null,
            "duration": actual.map(JSONValue.number) ?? .null,
            "duration_source": source.map(JSONValue.string) ?? .null,
            "duration_warning": .null,
            "duration_note": actual == nil ? .string(unknownNote) : .null
        ]
        if let requested, let actual, abs(actual - requested) > 1 {
            fields["duration_warning"] = .string(String(format:
                "Requested %.3f s; Sky Studio reports %.3f s, a difference of more than 1 s. Check the delivered length before placing it; the file was not changed.",
                requested, actual))
        }
        return fields
    }

    static let unknownNote = "Sky Studio did not report a valid result duration; the delivered length is unknown. "
        + "add_clips places the file at its own measured length: check it before cutting to it."

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
