import Foundation

// MARK: - 说明书的主题表
//
// 管什么：说明书里有哪些主题、每个主题有哪几节、按名字怎么找（大小写、连字符、空格不计较）、写错了猜哪个。
// **每个工具一个同名主题**（checks/MCP/GuideChecks.swift 钉着）。
// 不管什么：怎么答、一次回多少（MCPGuide），参数定义怎么写成文字（MCPGuideFields）。
//
// 方案的 PR 1（docs/plans/2026-11-09-mcp-guide.md 7.1）：主题先放**现有说明原文**，名片不动 —— 概要就是这个工具现在的说明
// （一个字不改，从定义里现取，不另抄一份：抄的会漂），字段从它的参数定义现算（Codex 把超过 5,000 字节的参数定义的说明全删掉，
// 在这里读得到）。之后的 PR 先把说明原样搬进手写的主题、再写短名片；手写的节按工具组分文件（每个 ≤ 400 行，`written` 挑），守卫查里面提到的
// 名字和例子。第一个手写的是 add_voiceover（声音 PR 3，MCPGuideVoiceTopics）。只写英文（方案第八节第 7 条）。

/// 说明书的一节。
public struct MCPGuideSection: Sendable, Equatable {
    /// 每个主题的第一节：整份回时不加标题，主题太长时只回它。
    public static let overview = "overview"

    public let name: String
    public let text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// 说明书的一个主题。
public struct MCPGuideTopic: Sendable, Equatable {
    public let name: String
    /// 目录里跟在名字后面的一句话。
    public let headline: String
    /// 第一节是 overview。
    public let sections: [MCPGuideSection]
    /// 最小的 JSON 例子（身份是写明的占位）；守卫按真实参数定义逐个校验。
    public let examples: [JSONValue]
    public let related: [String]

    public init(name: String, headline: String, sections: [MCPGuideSection], examples: [JSONValue] = [], related: [String] = []) {
        self.name = name
        self.headline = headline
        self.sections = sections
        self.examples = examples
        self.related = related
    }
}

public enum MCPGuideTopics {
    /// 全部主题，按清单顺序。
    public static var all: [MCPGuideTopic] { MCPToolName.allCases.map(topic(for:)) }

    /// 按名字找；不认识回 nil（MCPGuide 回目录 + 猜的）。
    public static func topic(named raw: String) -> MCPGuideTopic? {
        MCPToolName(rawValue: normalized(raw)).map(topic(for:))
    }

    /// 一个工具的主题。手写了的（`written`）：手写的几节 + 例子 + 相关主题，fields 接在最后；还没写的（方案 PR 1 的样子）：
    /// 概要 = 它现在的说明原文。两种的字段都从参数定义现算。
    public static func topic(for tool: MCPToolName) -> MCPGuideTopic {
        let definition = tool.definition
        let fields = MCPGuideSection(name: "fields", text: MCPGuideFields.text(for: definition.inputSchema))
        if let written = written(for: tool) {
            return MCPGuideTopic(name: tool.rawValue, headline: definition.title, sections: written.sections + [fields],
                                 examples: written.examples, related: written.related)
        }
        return MCPGuideTopic(name: tool.rawValue, headline: definition.title, sections: [
            MCPGuideSection(name: MCPGuideSection.overview, text: definition.description), fields
        ])
    }

    /// 已经手写了主题的工具（名片缩短之前，原来说明里的话先搬进这里：方案 5.1）。手写的按工具组分文件，每个 ≤ 400 行；
    /// 第一节叫 overview，不写 fields（上面现算）。守卫：checks/MCP/GuideChecks.swift（名字都存在、只用英文、每一节 ≤ 6,000）。
    public static func written(for tool: MCPToolName) -> MCPGuideTopic? {
        switch tool {
        case .addVoiceover: return MCPGuideVoiceTopics.addVoiceover
        default: return nil
        }
    }

    /// 名字的写法不计较：前后空白、大小写、连字符和空格当下划线（Edit-Clip → edit_clip）。
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
    }

    /// 写错的名字猜哪几个：包含关系（「clip」→ 带 clip 的）优先，再按编辑距离 ≤ 2，最多 3 个。
    public static func suggestions(for raw: String) -> [String] {
        let wanted = normalized(raw)
        guard !wanted.isEmpty else { return [] }
        let names = all.map(\.name)
        let scored = names.compactMap { name -> (name: String, score: Int)? in
            if name.contains(wanted) || wanted.contains(name) { return (name, 0) }
            let distance = editDistance(wanted, name)
            return distance <= 2 ? (name, distance) : nil
        }
        return scored.sorted { ($0.score, $0.name) < ($1.score, $1.name) }.prefix(3).map(\.name)
    }

    /// 两个名字的编辑距离（增、删、改一个字各算 1）。
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
