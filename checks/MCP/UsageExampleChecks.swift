import Foundation
import SrtFlowMCPKit

// 检查给模型的最小示例是否仍符合真实 schema；不模拟客户端选工具或 App 编辑结果。
// 反射当前 schema，避免另一份手抄字段表；真实自然语言调用另走独立工程冒烟。
func runUsageExampleChecks() {
    // 2026-11-07 用户定：与 ProtocolChecks 一样守 110,000。
    let catalog = JSONValue.object(["tools": MCPToolName.listJSON]).encodedString()
    check(catalog.utf16.count <= 110_000, "the complete tools/list JSON, including its envelope, fits the catalog budget")
    let opening = String(MCPInstructions.text.prefix(512))
    for name in ["edit_clips", "set_texts", "set_shapes", "sync_voiceover", "inspect_video", "preset=quick_review"] {
        check(opening.contains(name), "the short task map routes \(name) before the 512-character boundary")
    }
    for tool: MCPToolName in [.editClips, .setTexts, .setShapes, .syncVoiceover, .inspectVideo, .exportVideo] {
        let prefix = "Example: "
        guard let line = tool.definition.description.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
              let value = try? JSONValue.decode(Data(line.dropFirst(prefix.count).utf8)) else {
            check(false, "\(tool.rawValue) supplies a parseable minimal JSON example")
            continue
        }
        check(MCPArgumentCheck.problem(tool: tool, arguments: value) == nil,
              "\(tool.rawValue)'s example uses documented parameter names")
        checkUsageValue(value, schema: MCPBatchTools.validationSchema(for: tool) ?? tool.definition.inputSchema,
                        path: tool.rawValue)
    }
    check(MCPArgumentCheck.problem(tool: .editClip, arguments: ["clip_id": "c1", "source_out": 2, "fade_out": 0.1]) == nil,
          "the audio overhang advice names accepted edit_clip parameters")
    check(MCPArgumentCheck.problem(tool: .editClip, arguments: ["clip_id": "c1", "end": 2]) != nil,
          "the former end advice would be rejected by the actual parameter checker")
}

private func checkUsageValue(_ value: JSONValue, schema: JSONValue, path: String) {
    if let options = schema["enum"]?.arrayValue {
        check(options.contains(value), "\(path) example uses a current enum value")
    }
    switch schema["type"]?.stringValue {
    case "object":
        guard let object = value.objectValue else { check(false, "\(path) example needs an object"); return }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            check(object[key] != nil, "\(path).\(key) is required in the example")
        }
        for (key, field) in object {
            if let child = schema["properties"]?[key] { checkUsageValue(field, schema: child, path: path + "." + key) }
        }
    case "array":
        guard let list = value.arrayValue else { check(false, "\(path) example needs an array"); return }
        if let minimum = schema["minItems"]?.intValue { check(list.count >= minimum, "\(path) has enough example entries") }
        if let maximum = schema["maxItems"]?.intValue { check(list.count <= maximum, "\(path) has bounded example entries") }
        if let child = schema["items"] { for field in list { checkUsageValue(field, schema: child, path: path + "[]") } }
    case "string": check(value.stringValue != nil, "\(path) example is a string")
    case "boolean": check(value.boolValue != nil, "\(path) example is a boolean")
    case "number", "integer":
        guard let number = value.doubleValue else { check(false, "\(path) example needs a number"); return }
        if schema["type"]?.stringValue == "integer" { check(number.rounded() == number, "\(path) example is an integer") }
        if let minimum = schema["minimum"]?.doubleValue { check(number >= minimum, "\(path) example meets the minimum") }
        if let maximum = schema["maximum"]?.doubleValue { check(number <= maximum, "\(path) example meets the maximum") }
    default: break
    }
}
