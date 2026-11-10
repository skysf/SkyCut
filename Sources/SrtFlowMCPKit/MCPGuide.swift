import Foundation

// MARK: - 说明书 skycut_guide 怎么答（纯值）
//
// 管什么：AI 调 skycut_guide 时回什么 —— 不带 topic 回地图（MCPGuideMap）；带 topic 回那个主题（短的整份回，长的先回概要 + 有哪些节，
// 再按 section 取）；写错的 topic 回地图 + 「是不是想要 …」，写错的 section 回那个主题 + 有哪些节。结果是 JSON
// （`{topic, sections, contents, section, text, examples, related, next_step}`，空的不写），同别的工具结果，App 原样写成一段文字交给客户端。
// 不管什么：主题的内容（MCPGuideTopics、MCPGuideSharedTopics）、地图的内容（MCPGuideMap），参数定义怎么写成文字（MCPGuideFields），
// 谁来答（App 的 AIGuideTools）。
//
// 一次回多少（方案 4.1，checks/MCP/GuideChecks.swift 钉着）：地图 ≤ 5,000、每个主题第一次回的 / 每一节 ≤ 6,000（UTF-16，量整份结果的
// JSON 文字 —— 客户端交给模型的就是它）。Claude Code 工具结果过 1 万 token 就警告、Codex 一次输出约 1 万 token 就截：方案定的硬限是 8,000，
// 守卫按 6,000 查，一节写到超过 6,000 就拆成两节。
// 方案：docs/plans/2026-11-09-mcp-guide.md 2.3；长期合同：docs/architecture/mcp-guide.md。

public enum MCPGuide {
    /// 地图的上限。
    public static let indexLimit = 5_000
    /// 一个主题第一次回的、每一节的上限。
    public static let answerLimit = 6_000

    /// 回答一次调用。`topic` / `section` 空白等于没给。只给 section 不给 topic：回目录，并说清楚 section 要和 topic 一起给。
    public static func answer(topic: String?, section: String?) -> JSONValue {
        guard let topic = given(topic) else { return index(sectionWithoutTopic: given(section)) }
        guard let found = MCPGuideTopics.topic(named: topic) else { return index(unknownTopic: topic) }
        return answer(found, section: section)
    }

    /// 一个主题怎么回：没给 section 回第一次的样子；给了回那一节，写错了回第一次的样子 + `unknown_section`。
    /// 公开给自检：拿手造的长主题测分节（现有的主题都放得下，整份回）。
    public static func answer(_ topic: MCPGuideTopic, section: String?) -> JSONValue {
        guard let section = given(section) else { return first(topic) }
        guard let chosen = topic.sections.first(where: { $0.name == MCPGuideTopics.normalized(section) }) else {
            return first(topic, unknownSection: section)
        }
        return one(topic, chosen)
    }

    // MARK: 地图

    /// 不带 topic：按任务分组的地图（MCPGuideMap，手写；守卫查每个工具都在地图里列着）。
    static func index(unknownTopic: String? = nil, sectionWithoutTopic: String? = nil) -> JSONValue {
        var payload: [String: JSONValue] = ["text": .string(MCPGuideMap.text)]
        if let unknownTopic {
            payload["unknown_topic"] = .string(unknownTopic)
            let guesses = MCPGuideTopics.suggestions(for: unknownTopic)
            if !guesses.isEmpty { payload["did_you_mean"] = .array(guesses.map { .string($0) }) }
        }
        if let sectionWithoutTopic {
            payload["section_without_topic"] = .string(sectionWithoutTopic)
            payload["next_step"] = .string("section reads one part of a topic: call skycut_guide again with topic=<name> and section.")
        }
        return .object(payload)
    }

    // MARK: 主题

    /// 第一次回一个主题：放得下就整份回；放不下回概要（第一节）和有哪些节，叫 AI 按 section 取。
    static func first(_ topic: MCPGuideTopic, unknownSection: String? = nil) -> JSONValue {
        var whole = base(topic)
        whole["text"] = .string(topic.sections.map(render).joined(separator: "\n\n"))
        var payload = whole
        if JSONValue.object(whole).encodedString().utf16.count > answerLimit, let overview = topic.sections.first {
            payload = base(topic)
            payload["section"] = .string(overview.name)
            payload["text"] = .string(overview.text)
            // 每一节讲什么列出来、叫 AI 只读要用的（2026-11-10 试点实测：只列节名、说「再按 section 取」时，它把六节全读了，输入 +41%）。
            payload["contents"] = .array(topic.sections.dropFirst().map { .string($0.about.isEmpty ? $0.name : "\($0.name): \($0.about)") })
            payload["next_step"] = .string("This topic is long, so only its \(overview.name) came back. Read only the sections you need: "
                + "call skycut_guide again with this topic and section=<name>; contents says what each one covers."
                + (topic.readingTip.map { " " + $0 } ?? ""))
        }
        if let unknownSection {
            payload["unknown_section"] = .string(unknownSection)
        }
        return .object(payload)
    }

    /// 按 section 取的那一节。
    static func one(_ topic: MCPGuideTopic, _ section: MCPGuideSection) -> JSONValue {
        var payload = base(topic)
        payload["section"] = .string(section.name)
        payload["text"] = .string(section.text)
        return .object(payload)
    }

    /// 每次都带的：主题名、有哪些节；例子和相关主题有才写。
    private static func base(_ topic: MCPGuideTopic) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "topic": .string(topic.name),
            "sections": .array(topic.sections.map { .string($0.name) })
        ]
        if !topic.examples.isEmpty { payload["examples"] = .array(topic.examples) }
        if !topic.related.isEmpty { payload["related"] = .array(topic.related.map { .string($0) }) }
        return payload
    }

    /// 整份回时每一节的样子：第一节（概要）不加标题，其余加「## 名字」。
    private static func render(_ section: MCPGuideSection) -> String {
        section.name == MCPGuideSection.overview ? section.text : "## \(section.name)\n\(section.text)"
    }

    private static func given(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
