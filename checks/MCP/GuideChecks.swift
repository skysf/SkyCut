import Foundation
import SrtFlowMCPKit

// 说明书 skycut_guide（长期合同 docs/architecture/mcp-guide.md；方案 docs/plans/2026-11-09-mcp-guide.md 2.3、4.1、4.2）：
// - 工具本身：清单里第一个、只读不删不联网、不收 project、只有它带 anthropic/alwaysLoad、名片 ≤ 450；
// - 每个工具都有同名主题，目录里有每个工具名（整词）；目录 ≤ 5,000、每个主题第一次回的和每一节 ≤ 6,000（整份结果的 JSON 文字）；
// - 方案的 PR 1：主题的概要就是工具现在的说明原文（一个字不丢），fields 一节列出它真收的每个参数；
// - 长主题先回概要 + 有哪些节、按 section 取；写错的 topic 回目录 + 猜的；写错的 section 回那个主题 + unknown_section；
// - 手写的文字（名片、目录开头、提示）里提到的名字都存在（拿写错名字的样本证明它真会红）；回的每一样都只用英文；
// - App 那一头（AIGuideTools）照答，参数名核对收 topic / section、挡别的名字。
// 参数定义的每一样事实都写进 fields、例子对得上参数定义、related 是真主题、不含凭据和账号：GuideContentChecks.swift。
// 2026-11-10 审查（review-344）补强：目录按行首「- 名字:」认、fields 按路径认那一行，免得别处顺带提到就算过。
// 路由的 Policy 和 recipes 同一行在 checks/MCP/router-wiring.sh；没开通也照答在 checks/SkyStudio/GateChecks.swift。

/// 名片的上限（方案 4.1：目标 350、硬限 450）。说明书是照新规矩生的第一个工具，现在就守；其余工具迁移完（方案 PR 6）才一起守。
let guideCardLimit = 450

func runGuideChecks() {
    runGuideToolChecks()
    runGuideTopicChecks()
    runGuideSplitChecks()
    runGuideLookupChecks()
    runGuideAppChecks()
    runGuideWordingChecks()
    runGuideFieldFactChecks()
    runGuideContentChecks()
}

private func size(_ value: JSONValue) -> Int { value.encodedString().utf16.count }

/// 工具本身：位置、客户端提示、不碰工程、名片长度。
private func runGuideToolChecks() {
    let definition = MCPToolName.skycutGuide.definition
    checkEqual(MCPToolName.allCases.first, .skycutGuide, "skycut_guide is the first tool in the catalog (clients that show the list in order see it first)")
    check(definition.readOnly && !definition.destructive && !definition.openWorld, "skycut_guide is read-only, deletes nothing and stays on this Mac")
    check(!MCPToolName.skycutGuide.takesProject, "skycut_guide never touches a project, so it takes no project parameter")
    checkEqual((definition.inputSchema["properties"]?.objectValue ?? [:]).keys.sorted(), ["section", "topic"], "skycut_guide takes topic and section")
    check(definition.inputSchema["required"] == nil, "both of skycut_guide's parameters are optional (no topic = the index)")
    let json = definition.json
    checkEqual(json["_meta"]?["anthropic/alwaysLoad"], .bool(true), "skycut_guide asks Claude Code to load it upfront (_meta anthropic/alwaysLoad)")
    let upfront = MCPToolName.allCases.filter { $0.definition.json["_meta"]?["anthropic/alwaysLoad"] == .bool(true) }
    checkEqual(upfront, [.skycutGuide], "only skycut_guide loads upfront (each upfront tool costs context on every turn)")
    let card = definition.description.utf16.count
    check(card <= guideCardLimit, "skycut_guide's card fits \(guideCardLimit) characters (it is \(card))")
}

/// 每个工具一个同名主题；目录列全；大小守上限；PR 1 的概要就是现在的说明。
private func runGuideTopicChecks() {
    let index = MCPGuide.answer(topic: nil, section: nil)
    let indexText = index["text"]?.stringValue ?? ""
    check(size(index) <= MCPGuide.indexLimit, "the guide index fits \(MCPGuide.indexLimit) characters (it is \(size(index)))")
    let shared = ["rules", "conventions", "paid", "workflows", "errors"]
    checkEqual(MCPGuideTopics.all.map(\.name), MCPToolName.allCases.map(\.rawValue) + shared,
               "one guide topic per tool in catalog order, then the five shared topics")
    check(Set(shared).isDisjoint(with: MCPToolName.allCases.map(\.rawValue)), "no shared topic shares a name with a tool")
    // 地图第一行列出五个通用主题。
    let header = indexText.components(separatedBy: "\n").first ?? ""
    for name in shared { check(header.range(of: "\\b\(name)\\b", options: .regularExpression) != nil, "the map's first line names the \(name) topic") }
    var largest = (name: "", size: 0)
    let listed = guideMapEntries(indexText)
    for tool in MCPToolName.allCases {
        // 认它作为一项列在地图上（括号里顺带提到的不算：add_clips 的括号里写着 sound_effect，批量工具的括号里提到单项工具）。
        check(listed.contains(tool.rawValue), "the guide map lists \(tool.rawValue) as an entry")
        guard let topic = MCPGuideTopics.topic(named: tool.rawValue) else {
            check(false, "\(tool.rawValue) has a guide topic")
            continue
        }
        checkEqual(topic.sections.first?.name, MCPGuideSection.overview, "\(tool.rawValue): the topic starts with its overview")
        checkEqual(topic.sections.first?.text, tool.definition.description, "\(tool.rawValue): the overview keeps the current description word for word")
        // 第一层的每个参数有自己那一行（不缩进），里层同名的不算。
        let entries = MCPGuideFields.entries(for: tool.definition.inputSchema)
        for name in (tool.definition.inputSchema["properties"]?.objectValue ?? [:]).keys {
            let line = entries.first { $0.path == name }?.line ?? ""
            check(line.hasPrefix("- \(name) ("), "\(tool.rawValue): the fields section has a top-level line for \(name)")
        }
        let first = MCPGuide.answer(topic: tool.rawValue, section: nil)
        check(size(first) <= MCPGuide.answerLimit, "\(tool.rawValue): the first answer fits \(MCPGuide.answerLimit) characters (it is \(size(first)))")
        if size(first) > largest.size { largest = (tool.rawValue, size(first)) }
        for section in topic.sections {
            let answer = MCPGuide.answer(topic: tool.rawValue, section: section.name)
            check(size(answer) <= MCPGuide.answerLimit, "\(tool.rawValue).\(section.name) fits \(MCPGuide.answerLimit) characters (it is \(size(answer)))")
            check(!section.text.isEmpty, "\(tool.rawValue).\(section.name) is not empty")
        }
    }
    // 五个通用主题：都在、每一节不空、大小守上限。
    for name in shared {
        guard let topic = MCPGuideTopics.topic(named: name) else {
            check(false, "the \(name) topic exists")
            continue
        }
        check(topic.sections.allSatisfy { !$0.text.isEmpty }, "the \(name) topic has text")
        let first = MCPGuide.answer(topic: name, section: nil)
        check(size(first) <= MCPGuide.answerLimit, "\(name): the first answer fits \(MCPGuide.answerLimit) characters (it is \(size(first)))")
        if size(first) > largest.size { largest = (name, size(first)) }
    }
    // 范围写成数字（Codex 不显示 minimum / maximum），里层对象往里缩进。
    let editFields = MCPGuide.answer(topic: "edit_clip", section: "fields")["text"]?.stringValue ?? ""
    check(editFields.contains("- animation_intensity (number, 0 to 1)"), "fields spell a range out in numbers")
    check(editFields.contains("\n  - bottom (number, 0 to 0.45)"), "fields indent an object's own fields")
    check(editFields.contains("- clip_id (string, required)"), "fields mark required parameters")
    check(editFields.contains("one of: none | fade | rise | pop | zoom | wipe"), "fields list an enum's choices")
    check(MCPGuide.answer(topic: "get_settings", section: "fields")["text"]?.stringValue?.isEmpty == false, "a tool with one parameter still has a fields section")
    print("MCP guide: index \(size(index))/\(MCPGuide.indexLimit); largest first answer \(largest.size)/\(MCPGuide.answerLimit) (\(largest.name)).")
}

/// 长主题先回概要 + 有哪些节；按 section 取；写错的 section 回第一次的样子。现有的主题都放得下，拿手造的测。
private func runGuideSplitChecks() {
    let long = MCPGuideTopic(name: "long_topic", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: String(repeating: "o", count: 2_500)),
        MCPGuideSection(name: "framing", text: String(repeating: "f", count: 2_500)),
        MCPGuideSection(name: "sound", text: String(repeating: "s", count: 2_500))
    ])
    let first = MCPGuide.answer(long, section: nil)
    checkEqual(first["section"]?.stringValue, MCPGuideSection.overview, "a topic over the limit answers with its overview first")
    checkEqual(first["text"]?.stringValue, String(repeating: "o", count: 2_500), "only the overview text comes back")
    checkEqual(first["sections"], ["overview", "framing", "sound"], "the first answer lists every section")
    let nextStep = first["next_step"]?.stringValue ?? ""
    check(nextStep.contains("framing, sound") && nextStep.contains("section"), "the next step says which sections to ask for")
    checkEqual(MCPGuide.answer(long, section: "Sound")["text"]?.stringValue, String(repeating: "s", count: 2_500), "section reads one section (any case)")
    let wrong = MCPGuide.answer(long, section: "volume")
    checkEqual(wrong["unknown_section"]?.stringValue, "volume", "an unknown section is named back")
    checkEqual(wrong["section"]?.stringValue, MCPGuideSection.overview, "an unknown section falls back to the first answer")

    let short = MCPGuideTopic(name: "short_topic", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: "Overview."),
        MCPGuideSection(name: "fields", text: "- a (string)")
    ], examples: [["a": "x"]], related: ["look"])
    let whole = MCPGuide.answer(short, section: nil)
    checkEqual(whole["text"]?.stringValue, "Overview.\n\n## fields\n- a (string)", "a short topic comes back whole, later sections under headings")
    check(whole["next_step"] == nil && whole["section"] == nil, "a whole answer needs no next step")
    checkEqual(whole["examples"], [["a": "x"]], "examples come back with the topic")
    checkEqual(whole["related"], ["look"], "related topics come back with the topic")
    check(MCPGuide.answer(topic: "look", section: nil)["examples"] == nil, "no examples key when a topic has none")
}

/// 名字的写法不计较；写错的回目录 + 猜的。
private func runGuideLookupChecks() {
    checkEqual(MCPGuide.answer(topic: "Paid", section: nil)["topic"]?.stringValue, "paid", "a shared topic is found by name (any case)")
    check((MCPGuide.answer(topic: "rule", section: nil)["did_you_mean"]?.arrayValue ?? []).contains("rules"), "a near miss suggests a shared topic")
    for spelling in ["edit_clip", "Edit-Clip", "  EDIT_CLIP ", "edit clip"] {
        checkEqual(MCPGuide.answer(topic: spelling, section: nil)["topic"]?.stringValue, "edit_clip", "topic \"\(spelling)\" finds edit_clip")
    }
    let typo = MCPGuide.answer(topic: "edit_clp", section: nil)
    checkEqual(typo["unknown_topic"]?.stringValue, "edit_clp", "an unknown topic is named back")
    check((typo["did_you_mean"]?.arrayValue ?? []).contains("edit_clip"), "an unknown topic suggests the nearest names")
    checkEqual(typo["text"]?.stringValue, guideMapText(), "an unknown topic answers with the map")
    let nothing = MCPGuide.answer(topic: "qqqqqqqqqq", section: nil)
    check(nothing["did_you_mean"] == nil && nothing["unknown_topic"] != nil, "no suggestion when nothing is close")
    checkEqual(MCPGuideTopics.suggestions(for: "clip").first, "add_clips", "a fragment suggests the names that contain it")
    for blank in [nil, "", "   "] as [String?] {
        check(MCPGuide.answer(topic: blank, section: nil)["unknown_topic"] == nil, "a blank topic is the index, not an unknown topic")
    }
    // 只给 section 不给 topic：说清楚错在哪，不悄悄回目录（review-344 第 6 条）。
    let lonely = MCPGuide.answer(topic: nil, section: "fields")
    checkEqual(lonely["section_without_topic"]?.stringValue, "fields", "a section without a topic is named back")
    check((lonely["next_step"]?.stringValue ?? "").contains("topic="), "a section without a topic says to pass topic too")
    check(MCPGuide.answer(topic: nil, section: nil)["section_without_topic"] == nil, "no topic and no section is just the index")
}

/// App 那一头：照 MCPGuide 答；参数名核对只收 topic / section（和到处都收的 project）。
private func runGuideAppChecks() {
    do {
        checkEqual(try AIGuideTools.guide(args(["topic": "look"])).payload["topic"]?.stringValue, "look", "the App answers a topic")
        checkEqual(try AIGuideTools.guide(args([:])).payload, MCPGuide.answer(topic: nil, section: nil), "the App answers the index")
        checkEqual(try AIGuideTools.guide(args(["topic": "edit_clip", "section": "fields"])).payload["section"]?.stringValue, "fields",
                   "the App reads one section")
        check(try AIGuideTools.guide(args(["topic": "look"])).changedProject == false, "the guide never changes a project")
    } catch {
        check(false, "AIGuideTools answers without throwing: \(error)")
    }
    check(MCPArgumentCheck.problem(tool: .skycutGuide, arguments: ["topic": "look", "section": "fields"]) == nil, "topic and section are accepted")
    check(MCPArgumentCheck.problem(tool: .skycutGuide, arguments: ["project": "p1"]) == nil, "project is accepted everywhere")
    check(MCPArgumentCheck.problem(tool: .skycutGuide, arguments: ["tool": "look"]) != nil, "an unknown parameter is refused, not ignored")
}

/// 手写的文字只提真有的名字；回的每一样都只用英文。
private func runGuideWordingChecks() {
    let long = MCPGuideTopic(name: "long_topic", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: String(repeating: "o", count: 4_000)),
        MCPGuideSection(name: "more", text: String(repeating: "m", count: 4_000))
    ])
    var handWritten = [
        ("the card", MCPToolName.skycutGuide.definition.description),
        ("the index header", MCPGuide.answer(topic: nil, section: nil)["text"]?.stringValue?.components(separatedBy: "\n").first ?? ""),
        ("the long-topic next step", MCPGuide.answer(long, section: nil)["next_step"]?.stringValue ?? ""),
        ("the section-without-topic next step", MCPGuide.answer(topic: nil, section: "fields")["next_step"]?.stringValue ?? "")
    ]
    handWritten.append(("the map", guideMapText()))
    for topic in MCPGuideTopics.all where MCPToolName(rawValue: topic.name) == nil {
        handWritten += topic.sections.map { ("the \(topic.name) topic", $0.text) }
    }
    for (what, text) in handWritten {
        check(!text.isEmpty, "\(what) is written")
        let unknown = guideUnknownNames(text)
        check(unknown.isEmpty, "\(what) names only real tools and parameters (unknown: \(unknown.joined(separator: ", ")))")
    }
    // 这条检查真会红：写错的工具名、不存在的参数名都要挑出来（review-344 第 3 条：以前从名片里一个名字都抽不出来，等于没查）。
    checkEqual(guideUnknownNames("Call skycut_guide topic=edit_clp, then edit_clip with clip_end_ms."), ["clip_end_ms", "edit_clp"],
               "the name check catches a misspelt tool and an unknown parameter")
    check(guideUnknownNames("Read skycut_guide topic=edit_clip before edit_clips.").isEmpty, "real names pass the name check")
    var answers = [MCPGuide.answer(topic: nil, section: nil), MCPGuide.answer(topic: "edit_clp", section: nil)]
    for topic in MCPGuideTopics.all {
        answers.append(MCPGuide.answer(topic: topic.name, section: nil))
        answers += topic.sections.map { MCPGuide.answer(topic: topic.name, section: $0.name) }
    }
    check(!answers.contains { containsChinese($0.encodedString()) }, "every guide answer is English only")
}

/// 手写的文字里看起来像名字（snake_case / camelCase）、却不是工具名、参数名、选项值、结果字段名的词，按字母排。
func guideUnknownNames(_ text: String) -> [String] {
    let known = catalogKnownNames()
    return catalogIdentifiers(in: text).filter { !known.contains($0) }.sorted()
}

/// 说明书的地图（不带 topic 回的那一页；2026-11-10 起按任务分组的工具目录在这里，不在总说明里）。
func guideMapText() -> String {
    MCPGuide.answer(topic: nil, section: nil)["text"]?.stringValue ?? ""
}

/// 地图上作为一项列着的名字：跳过第一行（标题），每行去掉「组名:」和括号里的说明，按逗号、分号、斜杠切开，取每一项最后一个「标签:」后面的词。
func guideMapEntries(_ map: String) -> Set<String> {
    var entries = Set<String>()
    for line in map.components(separatedBy: "\n").dropFirst() {
        let bare = line.replacingOccurrences(of: #"\([^()]*\)"#, with: "", options: .regularExpression)
        guard let colon = bare.range(of: ": ") else { continue }
        for item in bare[colon.upperBound...].components(separatedBy: CharacterSet(charactersIn: ",;/")) {
            let word = item.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
            if !word.isEmpty { entries.insert(word) }
        }
    }
    return entries
}
