import Foundation

// MARK: - 工具清单：说明书 skycut_guide 的名片
//
// 管什么：skycut_guide 这个工具在清单里长什么样 —— 名片（description）、两个参数、客户端提示（只读、不删、不联网，
// `_meta` 里的 `anthropic/alwaysLoad`：Claude Code 把它预先加载，省掉一次工具搜索）。
// 不管什么：说明书的内容和怎么答（MCPGuide、MCPGuideTopics、MCPGuideFields）；谁来答（App 里的 AIGuideTools，
// 路由的 Policy 和 recipes 同一行）；没开通时也照答（SkyCutGates.alwaysAnswered）。
// 方案：docs/plans/2026-11-09-mcp-guide.md 2.3；长期合同：docs/architecture/mcp-guide.md。
//
// 名片 ≤450 字（UTF-16；方案 4.1，checks/MCP/GuideChecks.swift 钉着）。只写已经有的主题：通用主题（rules、paid……）和按任务分组的
// 地图是方案的 PR 2，到时候名片跟着改。

enum MCPGuideTool {
    static var definition: MCPToolDefinition {
        MCPToolDefinition(
            .skycutGuide, title: "Read the SkyCut guide",
            description: """
            START HERE. SkyCut's manual: free, read-only, instant, no project. No topic: an index of every SkyCut tool with its \
            topic name. topic=<tool name>: that tool's guide (what it does, then every field with its type, choices and range). \
            Long topics list their sections; pass section to read one. Read a tool's topic before its first use when its \
            description asks, and after a failed call.
            """,
            input: MCPSchema.object([
                "topic": MCPSchema.string("A tool name, e.g. edit_clip. Leave out for the index of every tool."),
                "section": MCPSchema.string("One section of a long topic, named in that topic's sections.")
            ]),
            readOnly: true,
            meta: ["anthropic/alwaysLoad": true]
        )
    }
}
