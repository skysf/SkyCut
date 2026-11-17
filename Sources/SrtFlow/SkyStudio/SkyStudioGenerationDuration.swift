import Foundation
import SrtFlowMCPKit

// Reports the submitted duration beside Sky Studio's result duration, including refreshes.
// This notice never measures, trims, pads, regenerates, or changes media or the timeline.
enum SkyStudioGenerationDuration {
    static func fields(for generation: SkyStudioGeneration, result: SkyStudioJobResult?) -> [String: JSONValue] {
        guard generation.kind != .image else { return [:] }
        let requested = positive(generation.params["duration"]?.doubleValue)
        let actual = positive(result?.duration)
        var fields: [String: JSONValue] = [
            "requested_duration": requested.map(JSONValue.number) ?? .null,
            "duration": actual.map(JSONValue.number) ?? .null,
            "duration_warning": .null,
            "duration_note": actual == nil ? "Sky Studio did not report a valid result duration; the delivered length is unknown." : .null
        ]
        if let requested, let actual, abs(actual - requested) > 1 {
            fields["duration_warning"] = .string(String(format:
                "Requested %.3f s; Sky Studio reports %.3f s, a difference of more than 1 s. Check the delivered length before placing it; the file was not changed.",
                requested, actual))
        }
        return fields
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
