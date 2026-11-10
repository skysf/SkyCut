import Foundation
import SrtFlowMCPKit

// 手写了说明书主题的工具（MCP 按需说明方案 5.1：先把说明搬进主题、再写短名片；第一个是 add_voiceover，SkyCut 声音方案 4.10、9.1 第 10 项）：
// - 名片 ≤ 450；参数说明 ≤ 120、有范围（minimum / maximum / 条数）的说明里写着那几个数（Codex 不显示范围，方案 2.5）；参数定义 ≤ 4,500 字节；
//   fields 不手写（GuideChecks 查它接在最后）；有例子。名片和手写的几节里提到的名字都存在（GuideChecks 的 runGuideWordingChecks）、
//   例子过参数核对 / related 是真主题 / 不含凭据（GuideContentChecks）、只用英文（GuideChecks）：和别的手写文字同一套，不在这里另写一份；
// - add_voiceover 的名片带按性质必写的固定说法（方案 2.2 第 4 条）、去掉的 clone_from 不再出现；
// - 会回 needs_confirmation 的工具都收 confirm_token（docs/bugfixes/2026-11-10-voiceover-confirm-token-refused.md：
//   add_voiceover 读别处的恢复文件会问，却不收 confirm_token，点过头再调被参数核对挡掉）。

func runGuideWrittenChecks() {
    let written = MCPToolName.allCases.filter { MCPGuideTopics.written(for: $0) != nil }
    check(written.contains(.addVoiceover), "add_voiceover has a hand-written guide topic")
    for tool in written { writtenTopicChecks(tool) }
    voiceoverCardChecks()
    confirmTokenChecks()
}

private func writtenTopicChecks(_ tool: MCPToolName) {
    guard let written = MCPGuideTopics.written(for: tool) else { return }
    let definition = tool.definition
    let name = tool.rawValue
    checkEqual(written.name, name, "\(name): the hand-written topic is named after its tool")
    checkEqual(written.sections.first?.name, MCPGuideSection.overview, "\(name): the hand-written topic starts with its overview")
    check(!written.sections.contains { $0.name == "fields" }, "\(name): fields are computed from the schema, never written by hand")
    check(definition.description.utf16.count <= guideCardLimit, "\(name): the card fits \(guideCardLimit) (it is \(definition.description.utf16.count))")
    let bytes = definition.inputSchema.encodedString().utf8.count
    check(bytes <= 4_500, "\(name): the parameter definition fits 4,500 UTF-8 bytes (it is \(bytes)), so Codex keeps its descriptions")
    walkParameters(definition.inputSchema, path: nil) { path, field in
        let text = field["description"]?.stringValue ?? ""
        check(text.utf16.count <= 120, "\(name).\(path): the description fits 120 characters (it is \(text.utf16.count))")
        for key in ["minimum", "maximum", "minItems", "maxItems"] {
            guard let value = field[key]?.doubleValue else { continue }
            let number = value.rounded() == value ? String(Int(value)) : String(value)
            check(text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: number))\\b", options: .regularExpression) != nil,
                  "\(name).\(path): the description spells out its \(key) \(number) (Codex hides schema ranges)")
        }
    }
    check(!written.examples.isEmpty, "\(name): the topic has minimal examples")
}

/// 参数定义里的每个参数（里层对象、数组里的对象也走），路径同 MCPGuideFields 的写法。
private func walkParameters(_ schema: JSONValue, path: String?, _ visit: (String, JSONValue) -> Void) {
    for (key, field) in schema["properties"]?.objectValue ?? [:] {
        let here = path.map { "\($0).\(key)" } ?? key
        visit(here, field)
        walkParameters(field, path: here, visit)
        if let items = field["items"] { walkParameters(items, path: here + "[]", visit) }
    }
}

/// add_voiceover 的名片：不知道就会调错、花错钱的那几句（方案 2.2 第 4 条、2.6；声音方案 4.10）。
private func voiceoverCardChecks() {
    let card = MCPToolName.addVoiceover.definition.description
    for phrase in ["One undo step", "Paid (Sky Studio credits)", "Returns job_id; wait with get_job", "relay voice.note", "needs_confirmation",
                   "The daily credit limit always applies", "never resend lines", "default gemini:Charon", "model=auto",
                   "Read skycut_guide topic=add_voiceover before the first call."] {
        check(card.contains(phrase), "the add_voiceover card says \"\(phrase)\"")
    }
    check(!card.contains("Rachel") && !card.contains("clone_from"), "the card no longer offers old Eleven names or clone_from")
    let properties = MCPToolName.addVoiceover.definition.inputSchema["properties"]?.objectValue ?? [:]
    check(properties["clone_from"] == nil && properties["clone_start"] == nil && properties["clone_seconds"] == nil,
          "clone_from, clone_start and clone_seconds are gone (clones go through the voice library)")
    check(properties["model"] != nil, "add_voiceover takes model")
    check(guideMapText().contains("add_voiceover (Sky Studio voices; SkyCut and Mac voices are free)"),
          "the guide map's paid line names add_voiceover's Sky Studio voices")
    let sections = MCPGuideTopics.topic(for: .addVoiceover).sections.map(\.name)
    checkEqual(sections, ["overview", "voices", "models", "paid", "subtitles", "recovery", "local_voices", "fields"],
               "the add_voiceover guide has its sections, fields last")
}

/// 会回 needs_confirmation 的工具，点过头之后要能带着 confirm_token 再调（参数核对不认说明上没有的名字）。
private func confirmTokenChecks() {
    for tool in MCPToolName.allCases where tool.definition.description.contains("needs_confirmation") {
        check(tool.definition.inputSchema["properties"]?["confirm_token"] != nil,
              "\(tool.rawValue) says it may return needs_confirmation, so it takes confirm_token")
    }
    check(MCPToolName.addVoiceover.definition.inputSchema["properties"]?["confirm_token"] != nil,
          "add_voiceover asks before reading a recovery file outside the opened folder, so it takes confirm_token")
}
