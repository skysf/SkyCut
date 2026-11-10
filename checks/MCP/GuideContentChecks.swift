import Foundation
import SrtFlowMCPKit

// 说明书的内容对不对（GuideChecks 的另一半；2026-11-10 审查 review-344 第 1、4 条之后补的）：
// - **fields 一样不漏**：自己走一遍真实清单（不借被测的渲染代码），每个参数的可选值（任何类型）、范围、条数、长度、类型并集、anyOf 的每一种写法、
//   能不能带别的字段，都要出现在**它自己那一行**（按路径找那一行）。以前只抽查 edit_clip 的 4 行字符串，数字的可选值、并集、anyOf、maxItems
//   全漏了也是绿的（docs/bugfixes/2026-11-10-guide-fields-drop-schema-facts.md）。
// - **例子对得上参数定义**（参数名过 MCPArgumentCheck、值过 usageValueProblems），只许挂在工具主题上；**related 是真主题**；
//   **不含凭据、账号、链接**（`sk-` 的 Key、邮箱、http(s) 链接、Bearer）—— 说明书没开通也照答（docs/architecture/mcp-guide.md）。
//   现在三样都是空的，所以每条都拿手造的坏样本证明它真会红。

func runGuideFieldFactChecks() {
    var facts = 0
    for tool in MCPToolName.allCases {
        let entries = MCPGuideFields.entries(for: tool.definition.inputSchema)
        let lines = Dictionary(entries.map { ($0.path, $0.line) }, uniquingKeysWith: { first, _ in first })
        checkEqual(lines.count, entries.count, "\(tool.rawValue): every field has one line of its own (no two share a path)")
        walkGuideFields(tool.definition.inputSchema, parent: nil) { path, field in
            guard let line = lines[path] else {
                check(false, "\(tool.rawValue): \(path) has its own line in fields")
                return
            }
            for fact in expectedGuideFacts(field) {
                facts += 1
                check(line.contains(fact), "\(tool.rawValue).\(path): fields say \"\(fact)\" (the line: \(line))")
            }
        }
    }
    // 走空了等于没查：真实清单里至少有这么多条事实（2026-11-10 是 250 条；下限留了余量，正常删掉几个选项不会误报）。
    check(facts >= 200, "the field-fact walk found the catalog's facts (\(facts))")
    // 审查点名的那几处（以前漏的）。
    func line(_ tool: MCPToolName, _ path: String) -> String {
        MCPGuideFields.entries(for: tool.definition.inputSchema).first { $0.path == path }?.line ?? ""
    }
    check(line(.setSettings, "optimized_media_cache_gb").contains("one of: 2 | 5 | 10 | 20 | 50"), "numeric choices are written out")
    check(line(.generateMedia, "camera_angle.rotate").contains("one of: -180 | -135 | -90 | -45 | 0 | 45 | 90 | 135 | 180"), "camera angle steps are written out")
    check(line(.generateMedia, "duration").contains("number or string (one of: auto) or null"), "every anyOf form is written out")
    check(line(.saveProject, "production").contains("object or null"), "a type union is written out")
    check(line(.editClips, "clips").contains("1 to 100 items"), "the batch limit is written out")
}

/// 按参数定义的结构走（对象的字段、数组里对象的字段、anyOf / oneOf 里对象的字段），路径和 MCPGuideFields.Entry.path 同一种写法。
private func walkGuideFields(_ schema: JSONValue, parent: String?, _ visit: (String, JSONValue) -> Void) {
    for (name, field) in schema["properties"]?.objectValue ?? [:] {
        let path = parent.map { "\($0).\(name)" } ?? name
        visit(path, field)
        walkGuideFields(field, parent: path, visit)
        if let items = field["items"] { walkGuideFields(items, parent: path + "[]", visit) }
        for branch in (field["anyOf"]?.arrayValue ?? []) + (field["oneOf"]?.arrayValue ?? []) {
            walkGuideFields(branch, parent: path, visit)
        }
    }
}

/// 一个参数应该写出来的事实（照名片的承诺：类型、可选的值、范围；外加条数、长度、能不能带别的字段）。
private func expectedGuideFacts(_ field: JSONValue) -> [String] {
    func number(_ value: Double) -> String { value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value) }
    func choices(_ values: [JSONValue]) -> String { values.map { $0.stringValue ?? $0.encodedString() }.joined(separator: " | ") }
    func bounds(_ low: String, _ high: String, _ unit: String) -> String? {
        let plural = unit.isEmpty ? "" : " " + unit
        let single = unit.isEmpty ? "" : " " + String(unit.dropLast())
        switch (field[low]?.doubleValue, field[high]?.doubleValue) {
        case let (min?, max?): return "\(number(min)) to \(number(max))\(plural)"
        case let (min?, nil): return "at least \(number(min))\(min == 1 ? single : plural)"
        case let (nil, max?): return "at most \(number(max))\(max == 1 ? single : plural)"
        case (nil, nil): return nil
        }
    }
    var facts: [String] = []
    if let values = field["enum"]?.arrayValue { facts.append("one of: " + choices(values)) }
    if let values = field["items"]?["enum"]?.arrayValue { facts.append("each one of: " + choices(values)) }
    facts += [bounds("minimum", "maximum", ""), bounds("minItems", "maxItems", "items"), bounds("minLength", "maxLength", "characters")].compactMap { $0 }
    if case .array(let types)? = field["type"] { facts.append(types.compactMap(\.stringValue).joined(separator: " or ")) }
    for branch in (field["anyOf"]?.arrayValue ?? []) + (field["oneOf"]?.arrayValue ?? []) {
        if let type = branch["type"]?.stringValue { facts.append(type) }
        if let values = branch["enum"]?.arrayValue { facts.append("one of: " + choices(values)) }
    }
    switch field["additionalProperties"] {
    case .bool(true)?: facts.append("other fields allowed")
    case .bool(false)?: facts.append("no other fields")
    default: break
    }
    return facts
}

func runGuideContentChecks() {
    for topic in MCPGuideTopics.all {
        let problems = guideContentProblems(topic)
        check(problems.isEmpty, "\(topic.name): \(problems.joined(separator: "; "))")
    }
    // 每条都拿手造的坏样本证明真会红。
    let overview = MCPGuideSection(name: MCPGuideSection.overview, text: "Overview.")
    let badExample = MCPGuideTopic(name: "edit_clip", sections: [overview], examples: [["clip_id": "c1", "end": 2]])
    check(guideContentProblems(badExample).contains { $0.contains("end") }, "an example with a parameter the tool does not take is caught")
    let badValue = MCPGuideTopic(name: "set_settings", sections: [overview], examples: [["optimized_media_cache_gb": 15]])
    check(guideContentProblems(badValue).contains { $0.contains("enum") }, "an example with a value outside the choices is caught")
    let strayExample = MCPGuideTopic(name: "made_up_topic", sections: [overview], examples: [["topic": "look"]])
    check(guideContentProblems(strayExample).contains { $0.contains("tool topics") }, "an example on a topic that is not a tool is caught")
    let badRelated = MCPGuideTopic(name: "look", sections: [overview], related: ["no_such_topic"])
    check(guideContentProblems(badRelated).contains { $0.contains("no_such_topic") }, "a related name that is not a topic is caught")
    for secret in ["key sk-" + String(repeating: "A", count: 20), "write to support@example.com", "see https://example.com/x", "Authorization: Bearer abc"] {
        let leaky = MCPGuideTopic(name: "look", sections: [MCPGuideSection(name: MCPGuideSection.overview, text: secret)])
        check(!guideContentProblems(leaky).isEmpty, "a credential, address or link in the guide is caught: \(secret.prefix(12))…")
    }
}

/// 一个主题的内容问题（空 = 没问题）：例子、related、凭据。
func guideContentProblems(_ topic: MCPGuideTopic) -> [String] {
    var problems: [String] = []
    if !topic.examples.isEmpty {
        if let tool = MCPToolName(rawValue: topic.name) {
            let schema = MCPBatchTools.validationSchema(for: tool) ?? tool.definition.inputSchema
            for (index, example) in topic.examples.enumerated() {
                if let problem = MCPArgumentCheck.problem(tool: tool, arguments: example) { problems.append("example \(index): \(problem)") }
                problems += usageValueProblems(example, schema: schema, path: "example \(index)")
            }
        } else {
            problems.append("examples belong to tool topics (\(topic.name) is not a tool)")
        }
    }
    for name in topic.related where MCPGuideTopics.topic(named: name) == nil {
        problems.append("related \(name) is not a guide topic")
    }
    let texts = topic.sections.map(\.text) + topic.examples.map { $0.encodedString() }
    let leaks = [#"sk-[A-Za-z0-9]{8,}"#, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z.]{2,}"#, #"https?://"#, #"Bearer\s"#]
    for pattern in leaks where texts.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) {
        problems.append("the guide must not carry credentials, account addresses or links (\(pattern))")
    }
    return problems
}
