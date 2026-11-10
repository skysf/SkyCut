import Foundation
import SrtFlowMCPKit

// 检查给模型的最小示例是否仍符合真实 schema；不模拟客户端选工具或 App 编辑结果。
// 反射当前 schema，避免另一份手抄字段表；真实自然语言调用另走独立工程冒烟。
func runUsageExampleChecks() {
    // 上限和量法只有 CatalogBudget 一份（迁移完收到 100,000）。
    check(catalogSize(MCPToolName.listJSON) <= catalogBudget, "the complete tools/list JSON, including its envelope, fits the catalog budget")
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
        let problems = usageValueProblems(value, schema: MCPBatchTools.validationSchema(for: tool) ?? tool.definition.inputSchema,
                                          path: tool.rawValue)
        check(problems.isEmpty, "\(tool.rawValue)'s example fits the schema: \(problems.joined(separator: "; "))")
    }
    check(MCPArgumentCheck.problem(tool: .editClip, arguments: ["clip_id": "c1", "source_out": 2, "fade_out": 0.1]) == nil,
          "the audio overhang advice names accepted edit_clip parameters")
    check(MCPArgumentCheck.problem(tool: .editClip, arguments: ["clip_id": "c1", "end": 2]) != nil,
          "the former end advice would be rejected by the actual parameter checker")
}

/// 一个例子的值对不对得上参数定义：必填、类型、可选的值、范围、条数。回出问题的地方（空 = 对得上）。
/// UsageExampleChecks（名片里那一行例子）和 GuideChecks（说明书里的例子）共用。
func usageValueProblems(_ value: JSONValue, schema: JSONValue, path: String) -> [String] {
    var problems: [String] = []
    if let options = schema["enum"]?.arrayValue, !options.contains(value) { problems.append("\(path) is not one of the enum values") }
    switch schema["type"]?.stringValue {
    case "object":
        guard let object = value.objectValue else { return problems + ["\(path) needs an object"] }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            problems.append("\(path).\(key) is required")
        }
        for (key, field) in object {
            if let child = schema["properties"]?[key] { problems += usageValueProblems(field, schema: child, path: path + "." + key) }
        }
    case "array":
        guard let list = value.arrayValue else { return problems + ["\(path) needs an array"] }
        if let minimum = schema["minItems"]?.intValue, list.count < minimum { problems.append("\(path) has too few entries") }
        if let maximum = schema["maxItems"]?.intValue, list.count > maximum { problems.append("\(path) has too many entries") }
        if let child = schema["items"] { for field in list { problems += usageValueProblems(field, schema: child, path: path + "[]") } }
    case "string": if value.stringValue == nil { problems.append("\(path) needs a string") }
    case "boolean": if value.boolValue == nil { problems.append("\(path) needs a boolean") }
    case "number", "integer":
        guard let number = value.doubleValue else { return problems + ["\(path) needs a number"] }
        if schema["type"]?.stringValue == "integer", number.rounded() != number { problems.append("\(path) needs an integer") }
        if let minimum = schema["minimum"]?.doubleValue, number < minimum { problems.append("\(path) is below the minimum") }
        if let maximum = schema["maximum"]?.doubleValue, number > maximum { problems.append("\(path) is above the maximum") }
    default: break
    }
    return problems
}
