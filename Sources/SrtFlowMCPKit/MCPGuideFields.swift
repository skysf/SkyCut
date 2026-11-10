import Foundation

// MARK: - 说明书的「fields」一节：参数定义写成文字
//
// 管什么：把一个工具的参数定义（inputSchema）写成一行一个参数的文字 —— 名字、类型（含 ["string","null"] 这种并集和 anyOf 的每一种写法）、
// 必填、可选的值（任何类型：字符串、数字……）、范围、条数和长度的上下限、能不能带别的字段、说明；里层对象、数组里的对象、anyOf 里对象的字段往里缩进。
// 从定义现算，所以永远和工具真收的参数一致（不另抄一份）。名片写着说明书给「每个字段的类型、可选的值和范围」：**参数定义里有的这些事实一样都不许漏**
// （2026-11-10 漏过：数字的可选值、类型并集、anyOf、maxItems 都没写，docs/bugfixes/2026-11-10-guide-fields-drop-schema-facts.md）。
// 为什么要它：Codex 把超过 5,000 字节的参数定义的说明全部删掉（edit_clip、generate_media 在 Codex 里只剩名字和类型），
// 也不显示 minimum / maximum；说明书里的这一节两样都有（docs/plans/2026-11-09-mcp-guide.md 1.3、2.5）。
// 不管什么：说明书怎么答（MCPGuide）、有哪些主题（MCPGuideTopics）。守卫：checks/MCP/GuideChecks.swift 自己走一遍真实清单，
// 每个参数的每一样事实都要出现在它自己那一行（按 `entries` 的路径找那一行）。

public enum MCPGuideFields {
    /// 一个参数那一行：`path` 是它在参数定义里的位置（`camera_angle.rotate`、`clips[].file`），`line` 是写出来的那一行（含缩进）。
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let line: String
    }

    /// 一节 fields 最多多少字（UTF-16，只算文字）：回答的 JSON 还要加转义和别的键，留出余量后整份仍在 6,000 以内。
    public static let sectionBudget = 4_500

    /// 参数定义写成的几节：放得下就一节 `fields`；放不下按**整个第一层参数**切成 `fields`、`fields_2`、`fields_3`……（2026-11-10 审查
    /// review-344 第 5 条：自动导出的一节没法手工拆，哪个参数定义一变长，一节就会超过 6,000 —— 所以由这里自动拆，守卫查每一节）。
    /// 一个第一层参数连同它的里层不拆开；它自己就超过上限时单独成一节。
    public static func sections(for schema: JSONValue) -> [MCPGuideSection] {
        let entries = entries(for: schema)
        guard !entries.isEmpty else { return [MCPGuideSection(name: "fields", text: "This tool takes no parameters.")] }
        var groups: [[String]] = []
        for entry in entries {
            if entry.path.contains(".") || entry.path.contains("[]"), !groups.isEmpty {
                groups[groups.count - 1].append(entry.line)
            } else {
                groups.append([entry.line])
            }
        }
        var chunks: [[String]] = []
        for group in groups {
            if let last = chunks.last, !last.isEmpty,
               (last + group).joined(separator: "\n").utf16.count > sectionBudget {
                chunks.append(group)
            } else if chunks.isEmpty {
                chunks.append(group)
            } else {
                chunks[chunks.count - 1] += group
            }
        }
        return chunks.enumerated().map { index, lines in
            MCPGuideSection(name: index == 0 ? "fields" : "fields_\(index + 1)", text: lines.joined(separator: "\n"))
        }
    }

    /// 每个参数一条，顺序同 `text`。
    public static func entries(for schema: JSONValue) -> [Entry] {
        fieldEntries(schema, depth: 0, parent: nil)
    }

    private static func fieldEntries(_ schema: JSONValue, depth: Int, parent: String?) -> [Entry] {
        guard let properties = schema["properties"]?.objectValue, !properties.isEmpty else { return [] }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let ordered = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        return ordered.flatMap { name -> [Entry] in
            guard let field = properties[name] else { return [] }
            let path = parent.map { "\($0).\(name)" } ?? name
            let entry = Entry(path: path, line: line(name, field, required: required.contains(name), depth: depth))
            return [entry] + children(of: field, depth: depth + 1, path: path)
        }
    }

    /// 一个参数一行：`- name (type, required, one of: a | b, 0 to 30, at most 100 items): 说明`。
    private static func line(_ name: String, _ field: JSONValue, required: Bool, depth: Int) -> String {
        var facts = [kind(of: field)]
        if required { facts.append("required") }
        facts += details(of: field)
        let description = field["description"]?.stringValue.map { ": " + $0 } ?? ""
        return String(repeating: "  ", count: depth) + "- \(name) (\(facts.joined(separator: ", ")))" + description
    }

    /// 类型以外的事实：可选的值、范围、条数、长度、能不能带别的字段。anyOf 的每一种写法在 `kind` 里写。
    private static func details(of field: JSONValue) -> [String] {
        var facts: [String] = []
        if let choices = choices(field["enum"]) { facts.append("one of: " + choices) }
        if let choices = choices(field["items"]?["enum"]) { facts.append("each one of: " + choices) }
        if let range = range(field, low: "minimum", high: "maximum", unit: nil) { facts.append(range) }
        if let low = field["exclusiveMinimum"]?.doubleValue { facts.append("above \(number(low))") }
        if let high = field["exclusiveMaximum"]?.doubleValue { facts.append("below \(number(high))") }
        if let items = range(field, low: "minItems", high: "maxItems", unit: "items") { facts.append(items) }
        if let length = range(field, low: "minLength", high: "maxLength", unit: "characters") { facts.append(length) }
        switch field["additionalProperties"] {
        case .bool(true)?: facts.append("other fields allowed")
        case .bool(false)?: facts.append("no other fields")
        default: break
        }
        return facts
    }

    /// 里层：对象的字段、数组里对象的字段、anyOf / oneOf 里对象的字段。
    private static func children(of field: JSONValue, depth: Int, path: String) -> [Entry] {
        var result = fieldEntries(field, depth: depth, parent: path)
        if let items = field["items"] { result += fieldEntries(items, depth: depth, parent: path + "[]") }
        for branch in branches(field) { result += fieldEntries(branch, depth: depth, parent: path) }
        return result
    }

    /// 类型：一个名字（`string`）、并集（`string or null`）、数组（`array of objects`），或者 anyOf 的每一种写法（`number or string (one of: auto) or null`）。
    private static func kind(of field: JSONValue) -> String {
        let forms = branches(field)
        if !forms.isEmpty {
            return forms.map { branch -> String in
                let extra = details(of: branch)
                return extra.isEmpty ? kind(of: branch) : "\(kind(of: branch)) (\(extra.joined(separator: ", ")))"
            }.joined(separator: " or ")
        }
        switch field["type"] {
        case .string(let type)?:
            guard type == "array" else { return type }
            let item = field["items"]?["type"]?.stringValue
            return item.map { "array of \($0 == "object" ? "objects" : $0 + "s")" } ?? "array"
        case .array(let types)?:
            return types.compactMap(\.stringValue).joined(separator: " or ")
        default:
            return "any"
        }
    }

    private static func branches(_ field: JSONValue) -> [JSONValue] {
        (field["anyOf"]?.arrayValue ?? []) + (field["oneOf"]?.arrayValue ?? [])
    }

    /// 可选的值，任何类型都写（字符串照原样，数字、布尔、null 照 JSON 的写法）。
    private static func choices(_ values: JSONValue?) -> String? {
        guard let values = values?.arrayValue, !values.isEmpty else { return nil }
        return values.map { $0.stringValue ?? $0.encodedString() }.joined(separator: " | ")
    }

    /// 上下限写成数字（Codex 不显示 minimum / maximum）：`0 to 30`、`1 to 100 items`、`at least 1 item`……
    private static func range(_ field: JSONValue, low: String, high: String, unit: String?) -> String? {
        func suffix(_ bound: Double?) -> String {
            guard let unit else { return "" }
            return " " + (bound == 1 ? String(unit.dropLast()) : unit)
        }
        switch (field[low]?.doubleValue, field[high]?.doubleValue) {
        case let (min?, max?): return "\(number(min)) to \(number(max))\(suffix(nil))"
        case let (min?, nil): return "at least \(number(min))\(suffix(min))"
        case let (nil, max?): return "at most \(number(max))\(suffix(max))"
        case (nil, nil): return nil
        }
    }

    /// 整数不带「.0」。
    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
