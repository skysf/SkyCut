import Foundation

// MARK: - 迁移过的工具：手写的说明书主题
//
// 管什么：哪些工具已经迁移（名片写短了，长话搬进说明书），以及它们手写的主题从哪个文件来。每个迁移过的工具的主题：
// 第一节 overview 以**迁移前的说明原文**开头（一个字不丢，方案 5.1、7.3），后面几节写全用法、限制、坑（出处写在每个文件的注释里），
// 再加最小的例子（守卫按真实参数定义核对）和相关主题；参数定义写成的 fields 几节由 MCPGuideTopics 自动接在最后。
// 唯一的例外是没有可搬的原文的工具（previousCard 为 nil）：行为和迁移同一个 PR 改了、旧说明照抄进来等于叫 AI 用已经没有的东西
// （add_voiceover，声音方案 4.10、4.2–4.4），名单写死在守卫里（docs/architecture/mcp-guide.md 第 14 条）。
// 不管什么：没迁移的工具（主题 = 现在的说明原文 + fields）、怎么答（MCPGuide）。
// 方案：docs/plans/2026-11-09-mcp-guide.md 5.1–5.3（试点 5 个：edit_clip、generate_media、set_text、add_clips、look）；
// add_voiceover 随声音 PR 3 迁移（docs/plans/2026-11-09-voice-features.md 4.10）。
// 守卫：checks/MCP/GuidePilotChecks.swift（名片 ≤ 450 和该写的固定说法、参数说明 ≤ 120 且范围写成数字、迁移前的原文还在、单个工具的参数定义 ≤ 4,500 字节）。

public enum MCPGuideWrittenTopics {
    /// 一个迁移过的工具手写的那部分主题。
    public struct Written: Sendable {
        /// 迁移前的说明原文（名片写短之前），overview 以它开头。nil = 没有可搬的原文（行为和迁移一起改了，旧说明已经不对；
        /// 名单写死在 GuidePilotChecks，旧说明每一句去了哪写在那个 PR 的说明里）。
        public let previousCard: String?
        public let sections: [MCPGuideSection]
        public let examples: [JSONValue]
        public let related: [String]
    }

    /// 已经迁移的工具（方案 5.3 的试点，2026-11-10；add_voiceover 随声音 PR 3）。之后的两批加在这里。
    public static let migrated: [MCPToolName] = [.editClip, .generateMedia, .setText, .addClips, .look, .addVoiceover]

    public static func topic(for tool: MCPToolName) -> Written? {
        switch tool {
        case .editClip: return MCPGuideEditClipTopic.written
        case .setText: return MCPGuideTimelineTopics.setText
        case .addClips: return MCPGuideTimelineTopics.addClips
        case .generateMedia: return MCPGuideMediaTopics.generateMedia
        case .look: return MCPGuideMediaTopics.look
        case .addVoiceover: return MCPGuideVoiceTopics.addVoiceover
        default: return nil
        }
    }

    /// overview：迁移前的原文 + 这一节自己的话。
    static func overview(_ previousCard: String, _ more: String) -> MCPGuideSection {
        MCPGuideSection(name: MCPGuideSection.overview, text: previousCard + "\n\n" + more)
    }
}
