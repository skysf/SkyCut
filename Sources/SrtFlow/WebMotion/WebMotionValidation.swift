import Foundation
import SrtFlowCore
import SrtFlowMCPKit
import SrtFlowWebMotionKit

// Renderer caps and parameter-form validation before either AI or UI starts work. No page execution or project mutation.
enum WebMotionValidation {
    static func validate(_ record: WebMotionClipRecord) throws {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(record.parametersJSON.utf8)),
              let values = decoded.objectValue else { throw AIToolError("parameters must be a JSON object.") }
        let request = WebMotionRequest(html: record.page, parametersJSON: record.parametersJSON,
                                      duration: record.duration, width: record.width, height: record.height,
                                      fps: record.fps, outputPath: "/tmp/motion-validation.mov")
        let problems = request.problems()
        guard problems.isEmpty else { throw AIToolError(problems.joined(separator: " ")) }
        let renderedDuration = FrameGrid(fps: record.fps).time(ofFrame: request.frameCount)
        guard record.hitTime.isFinite, record.hitTime >= 0, record.hitTime < min(record.duration, renderedDuration) else {
            throw AIToolError("hit must be inside the motion: 0 <= hit < duration (\(record.duration) s).")
        }
        guard record.parameterFields.count <= 64, Set(record.parameterFields.map(\.key)).count == record.parameterFields.count else {
            throw AIToolError("fields must have at most 64 entries, with unique keys.")
        }
        for field in record.parameterFields { try validate(field, value: values[field.key]) }
    }

    private static func validate(_ field: WebMotionParameterField, value: JSONValue?) throws {
        guard !field.key.isEmpty, !field.label.isEmpty, let value else {
            throw AIToolError("Every field needs a key, a label, and a matching parameter value.")
        }
        if let low = field.minimum, !low.isFinite { throw AIToolError("Field minimum must be finite.") }
        if let high = field.maximum, !high.isFinite { throw AIToolError("Field maximum must be finite.") }
        if let low = field.minimum, let high = field.maximum, low > high { throw AIToolError("Field minimum exceeds maximum.") }
        switch field.kind {
        case .number:
            guard let number = value.doubleValue, number.isFinite,
                  field.minimum.map({ number >= $0 }) ?? true,
                  field.maximum.map({ number <= $0 }) ?? true else {
                throw AIToolError("Parameter \(field.key) must be a number within its field's bounds.")
            }
        case .text, .font, .color:
            guard let text = value.stringValue else { throw AIToolError("Parameter \(field.key) must be a string.") }
            if field.kind == .color {
                let digits = text.dropFirst()
                guard text.hasPrefix("#"), [6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else {
                    throw AIToolError("Parameter \(field.key) must be #RRGGBB or #RRGGBBAA.")
                }
            }
        }
    }
}
