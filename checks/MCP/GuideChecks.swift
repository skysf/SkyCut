import Foundation
import SrtFlowMCPKit

// 说明书 skycut_guide（长期合同 docs/architecture/mcp-guide.md；方案 docs/plans/2026-11-09-mcp-guide.md 2.3、4.1、4.2）：
// - 工具本身：清单里第一个、只读不删不联网、不收 project、只有它带 anthropic/alwaysLoad、名片 ≤ 450；
// - 每个工具都有同名主题，目录里有每个工具名（整词）；目录 ≤ 5,000、每个主题第一次回的和每一节 ≤ 6,000（整份结果的 JSON 文字）；
// - 方案的 PR 1：主题的概要就是工具现在的说明原文（一个字不丢），fields 一节列出它真收的每个参数；
// - 长主题先回概要 + 有哪些节、按 section 取；写错的 topic 回目录 + 猜的；写错的 section 回那个主题 + unknown_section；
// - 手写的文字（名片、目录开头、提示）里提到的名字都存在；回的每一样都只用英文；
// - App 那一头（AIGuideTools）照答，参数名核对收 topic / section、挡别的名字。
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
    checkEqual(MCPGuideTopics.all.map(\.name), MCPToolName.allCases.map(\.rawValue), "one guide topic per tool, in catalog order")
    var largest = (name: "", size: 0)
    for tool in MCPToolName.allCases {
        check(indexText.range(of: "\\b\(tool.rawValue)\\b", options: .regularExpression) != nil, "the guide index names \(tool.rawValue)")
        guard let topic = MCPGuideTopics.topic(named: tool.rawValue) else {
            check(false, "\(tool.rawValue) has a guide topic")
            continue
        }
        checkEqual(topic.sections.first?.name, MCPGuideSection.overview, "\(tool.rawValue): the topic starts with its overview")
        if MCPGuideTopics.written(for: tool) == nil {
            checkEqual(topic.sections.first?.text, tool.definition.description, "\(tool.rawValue): the overview keeps the current description word for word")
        } else {
            // 手写了主题的工具（方案 5.1，第一个是 add_voiceover）：概要不再是名片原文，手写的几节在 GuideWrittenChecks 里查；fields 照旧现算、接在最后。
            checkEqual(topic.sections.last?.name, "fields", "\(tool.rawValue): a hand-written topic ends with the computed fields")
        }
        let fields = topic.sections.first { $0.name == "fields" }?.text ?? ""
        for name in (tool.definition.inputSchema["properties"]?.objectValue ?? [:]).keys {
            check(fields.contains("- \(name) ("), "\(tool.rawValue): the fields section lists \(name)")
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
    let long = MCPGuideTopic(name: "long_topic", headline: "A long topic", sections: [
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

    let short = MCPGuideTopic(name: "short_topic", headline: "A short topic", sections: [
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
    for spelling in ["edit_clip", "Edit-Clip", "  EDIT_CLIP ", "edit clip"] {
        checkEqual(MCPGuide.answer(topic: spelling, section: nil)["topic"]?.stringValue, "edit_clip", "topic \"\(spelling)\" finds edit_clip")
    }
    let typo = MCPGuide.answer(topic: "edit_clp", section: nil)
    checkEqual(typo["unknown_topic"]?.stringValue, "edit_clp", "an unknown topic is named back")
    check((typo["did_you_mean"]?.arrayValue ?? []).contains("edit_clip"), "an unknown topic suggests the nearest names")
    check((typo["text"]?.stringValue ?? "").contains("- seek: "), "an unknown topic answers with the index")
    let nothing = MCPGuide.answer(topic: "qqqqqqqqqq", section: nil)
    check(nothing["did_you_mean"] == nil && nothing["unknown_topic"] != nil, "no suggestion when nothing is close")
    checkEqual(MCPGuideTopics.suggestions(for: "clip").first, "add_clips", "a fragment suggests the names that contain it")
    for blank in [nil, "", "   "] as [String?] {
        check(MCPGuide.answer(topic: blank, section: nil)["unknown_topic"] == nil, "a blank topic is the index, not an unknown topic")
    }
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
    let long = MCPGuideTopic(name: "long_topic", headline: "A long topic", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: String(repeating: "o", count: 4_000)),
        MCPGuideSection(name: "more", text: String(repeating: "m", count: 4_000))
    ])
    let handWritten = [
        ("the card", MCPToolName.skycutGuide.definition.description),
        ("the index header", MCPGuide.answer(topic: nil, section: nil)["text"]?.stringValue?.components(separatedBy: "\n").first ?? ""),
        ("the long-topic next step", MCPGuide.answer(long, section: nil)["next_step"]?.stringValue ?? "")
    ]
    let known = catalogKnownNames()
    for (what, text) in handWritten {
        check(!text.isEmpty, "\(what) is written")
        let unknown = catalogIdentifiers(in: text).filter { !known.contains($0) }
        check(unknown.isEmpty, "\(what) names only real tools and parameters (unknown: \(unknown.sorted().joined(separator: ", ")))")
    }
    var answers = [MCPGuide.answer(topic: nil, section: nil), MCPGuide.answer(topic: "edit_clp", section: nil)]
    for topic in MCPGuideTopics.all {
        answers.append(MCPGuide.answer(topic: topic.name, section: nil))
        answers += topic.sections.map { MCPGuide.answer(topic: topic.name, section: $0.name) }
    }
    check(!answers.contains { containsChinese($0.encodedString()) }, "every guide answer is English only")
}
