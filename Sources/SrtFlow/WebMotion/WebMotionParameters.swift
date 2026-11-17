import Foundation
import SrtFlowMCPKit

// Parameter values, editable fields and renderer limits shared by the AI call and the inspector. No project mutation or I/O.
enum WebMotionParameters {
    static func object(_ json: String) -> [String: JSONValue] {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))?.objectValue ?? [:]
    }

    static func readObject(_ json: String) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), let object = value.objectValue else {
            throw AIToolError("parameters must be a valid JSON object.")
        }
        return object
    }

    static func canonical(_ values: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.object(values)), as: UTF8.self)
    }

    static func inferredFields(_ parameters: [String: JSONValue]) -> [WebMotionParameterField] {
        parameters.keys.sorted().filter { !["duration", "hit"].contains($0) }.compactMap { key in
            switch parameters[key] {
            case .number?: return .init(key: key, label: key, kind: .number)
            case .string(let text)?:
                let kind: WebMotionParameterField.Kind = key.lowercased().contains("font") ? .font
                    : (text.hasPrefix("#") && [7, 9].contains(text.count) ? .color : .text)
                return .init(key: key, label: key, kind: kind)
            default: return nil
            }
        }
    }

    /// Reserved values let every page read the same duration and local impact time as the placement/inspector controls.
    static func normalized(_ original: WebMotionClipRecord) throws -> WebMotionClipRecord {
        var record = original
        var values = try readObject(record.parametersJSON)
        values["duration"] = .number(record.duration)
        values["hit"] = .number(record.hitTime)
        record.parametersJSON = try canonical(values)
        return record
    }

}
