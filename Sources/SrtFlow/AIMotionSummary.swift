import Foundation
import SrtFlowMCPKit

// Compact discovery and editable values in get_timeline, without repeating stored HTML in every timeline response.
enum AIMotionSummary {
    static func library(_ state: TimelineState) -> JSONValue {
        .array(MotionPresetLibrary.entries(in: state).map { entry in
            switch entry {
            case .native(let kind):
                return ["id": .string(entry.id), "kind": "native", "name": .string(kind.title), "tool": "set_text"]
            case .web(_, let record, _):
                return ["id": .string(entry.id), "kind": "web", "name": .string(record.name), "tool": "set_motion",
                        "duration": .number(record.duration), "hit": .number(record.hitTime),
                        "parameters": .object(WebMotionParameters.object(record.parametersJSON))]
            }
        })
    }

    static func clip(_ record: WebMotionClipRecord) -> JSONValue {
        var values: [String: JSONValue] = [
            "parameters": .object(WebMotionParameters.object(record.parametersJSON)),
            "duration": .number(record.duration), "hit": .number(record.hitTime),
            "fields": .array(record.parameterFields.map { field in
                var value: [String: JSONValue] = ["key": .string(field.key), "label": .string(field.label), "type": .string(field.kind.rawValue)]
                if let low = field.minimum { value["minimum"] = .number(low) }
                if let high = field.maximum { value["maximum"] = .number(high) }
                return .object(value)
            })
        ]
        if let template = record.templateID { values["template"] = .string(template) }
        if let previous = record.provenance {
            values["renderer"] = .number(Double(previous.renderer))
            values["macOS"] = .string(previous.macOS)
            values["fonts"] = .array(previous.fonts.map(JSONValue.string))
        }
        let warnings = WebMotionEnvironment.warnings(for: record)
        if !warnings.isEmpty { values["warnings"] = .array(warnings.map(JSONValue.string)) }
        return .object(values)
    }
}
