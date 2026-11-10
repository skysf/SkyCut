import Foundation

// MARK: - 说明书的「fields」一节：参数定义写成文字
//
// 管什么：把一个工具的参数定义（inputSchema）写成一行一个参数的文字 —— 名字、类型、必填、可选的值、范围、条数下限、说明；
// 里层对象和数组里的对象往里缩进。从定义现算，所以永远和工具真收的参数一致（不另抄一份）。
// 为什么要它：Codex 把超过 5,000 字节的参数定义的说明全部删掉（edit_clip、generate_media 在 Codex 里只剩名字和类型），
// 也不显示 minimum / maximum；说明书里的这一节两样都有（docs/plans/2026-11-09-mcp-guide.md 1.3、2.5）。
// 不管什么：说明书怎么答（MCPGuide）、有哪些主题（MCPGuideTopics）。

enum MCPGuideFields {
    /// 整个参数定义的文字。必填的先写（按定义里的顺序），其余按名字排。
    static func text(for schema: JSONValue) -> String {
        let lines = fieldLines(schema, depth: 0)
        return lines.isEmpty ? "This tool takes no parameters." : lines.joined(separator: "\n")
    }

    private static func fieldLines(_ schema: JSONValue, depth: Int) -> [String] {
        guard let properties = schema["properties"]?.objectValue, !properties.isEmpty else { return [] }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let ordered = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        return ordered.flatMap { name -> [String] in
            guard let field = properties[name] else { return [] }
            return line(name, field, required: required.contains(name), depth: depth) + children(of: field, depth: depth + 1)
        }
    }

    /// 一个参数一行：`- name (type, required, one of: a | b, 0 to 30): 说明`。
    private static func line(_ name: String, _ field: JSONValue, required: Bool, depth: Int) -> [String] {
        var facts = [kind(of: field)]
        if required { facts.append("required") }
        if let choices = field["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
            facts.append("one of: " + choices.joined(separator: " | "))
        }
        if let choices = field["items"]?["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
            facts.append("each one of: " + choices.joined(separator: " | "))
        }
        if let range = range(of: field) { facts.append(range) }
        if let least = field["minItems"]?.intValue { facts.append("at least \(least) \(least == 1 ? "item" : "items")") }
        let description = field["description"]?.stringValue.map { ": " + $0 } ?? ""
        return [String(repeating: "  ", count: depth) + "- \(name) (\(facts.joined(separator: ", ")))" + description]
    }

    /// 里层：对象的字段、数组里对象的字段。
    private static func children(of field: JSONValue, depth: Int) -> [String] {
        if field["type"]?.stringValue == "array", let items = field["items"] { return fieldLines(items, depth: depth) }
        return fieldLines(field, depth: depth)
    }

    private static func kind(of field: JSONValue) -> String {
        guard let type = field["type"]?.stringValue else { return "any" }
        guard type == "array" else { return type }
        let item = field["items"]?["type"]?.stringValue
        return item.map { "array of \($0 == "object" ? "objects" : $0 + "s")" } ?? "array"
    }

    /// 范围写成数字（Codex 不显示 minimum / maximum）。
    private static func range(of field: JSONValue) -> String? {
        let minimum = field["minimum"]?.doubleValue
        let maximum = field["maximum"]?.doubleValue
        switch (minimum, maximum) {
        case let (low?, high?): return "\(number(low)) to \(number(high))"
        case let (low?, nil): return "at least \(number(low))"
        case let (nil, high?): return "at most \(number(high))"
        case (nil, nil): return nil
        }
    }

    /// 整数不带「.0」。
    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
