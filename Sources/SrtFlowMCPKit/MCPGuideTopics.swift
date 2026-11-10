import Foundation

// MARK: - 说明书的主题表
//
// 管什么：说明书里有哪些主题、每个主题有哪几节、按名字怎么找（大小写、连字符、空格不计较）、写错了猜哪个。
// **每个工具一个同名主题**，外加五个通用主题（rules、conventions、paid、workflows、errors，MCPGuideSharedTopics）；名字不许撞（checks/MCP/GuideChecks.swift 钉着）。
// 不管什么：怎么答、一次回多少（MCPGuide），地图（MCPGuideMap），参数定义怎么写成文字（MCPGuideFields）。
//
// 方案的 PR 1（docs/plans/2026-11-09-mcp-guide.md 7.1）：主题先放**现有说明原文**，名片不动 —— 概要就是这个工具现在的说明
// （一个字不改，从定义里现取，不另抄一份：抄的会漂），字段从它的参数定义现算（Codex 把超过 5,000 字节的参数定义的说明全删掉，
// 在这里读得到）。之后的 PR 先把说明原样搬进这里的常量、再写短名片；手写的节按工具组分文件（每个 ≤ 400 行），守卫查里面提到的
// 名字和例子。只写英文（方案第八节第 7 条）。

/// 说明书的一节。
public struct MCPGuideSection: Sendable, Equatable {
    /// 每个主题的第一节：整份回时不加标题，主题太长时只回它。
    public static let overview = "overview"

    public let name: String
    /// 这一节讲什么（一行）。主题长到要分节回时，第一次回答按它列出每一节（`contents`），AI 挑要读的（2026-11-10：试点实测里
    /// 只给节名、叫它「再按 section 取」，它把 generate_media 的六节全读了）。手写的节写在节旁边，fields 几节自动生成。
    public let about: String
    public let text: String

    public init(name: String, about: String = "", text: String) {
        self.name = name
        self.about = about
        self.text = text
    }
}

/// 说明书的一个主题。
public struct MCPGuideTopic: Sendable, Equatable {
    public let name: String
    /// 第一节是 overview。
    public let sections: [MCPGuideSection]
    /// 最小的 JSON 例子（身份是写明的占位）；守卫按真实参数定义逐个校验。
    public let examples: [JSONValue]
    public let related: [String]
    /// 分节回时写进第一次回答的 next_step：常见的活只要读哪一节（generate_media：报价再问只读 spending）。
    public let readingTip: String?

    public init(name: String, sections: [MCPGuideSection], examples: [JSONValue] = [], related: [String] = [], readingTip: String? = nil) {
        self.name = name
        self.sections = sections
        self.examples = examples
        self.related = related
        self.readingTip = readingTip
    }
}

public enum MCPGuideTopics {
    /// 全部主题：工具的按清单顺序，后面接五个通用主题。
    public static var all: [MCPGuideTopic] { MCPToolName.allCases.map(topic(for:)) + MCPGuideSharedTopics.all }

    /// 按名字找；不认识回 nil（MCPGuide 回地图 + 猜的）。
    public static func topic(named raw: String) -> MCPGuideTopic? {
        let name = normalized(raw)
        return MCPGuideSharedTopics.all.first { $0.name == name } ?? MCPToolName(rawValue: name).map(topic(for:))
    }

    /// 一个工具的主题。迁移过的（名片写短了的，MCPGuideWrittenTopics）：手写的几节 + 例子 + 相关主题；没迁移的：概要 = 它现在的说明原文。
    /// 两种都在最后接上参数定义写成的 fields 几节（MCPGuideFields.sections，太长自动按第一层参数拆）。
    public static func topic(for tool: MCPToolName) -> MCPGuideTopic {
        let definition = tool.definition
        let fields = MCPGuideFields.sections(for: definition.inputSchema)
        if let written = MCPGuideWrittenTopics.topic(for: tool) {
            return MCPGuideTopic(name: tool.rawValue, sections: written.sections + fields, examples: written.examples, related: written.related,
                                 readingTip: written.readingTip)
        }
        return MCPGuideTopic(name: tool.rawValue, sections: [MCPGuideSection(name: MCPGuideSection.overview, text: definition.description)] + fields)
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
