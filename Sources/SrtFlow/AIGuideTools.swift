import Foundation
import SrtFlowMCPKit

// MARK: - 工具：说明书（skycut_guide）
//
// 管什么：AI 问说明书时，照 SrtFlowMCPKit 的 MCPGuide 答，原样回去。不碰工程、不排队、不摆窗口、不算这一轮
// （路由的 Policy 和 recipes 同一行）；没开通时也照答，和 get_status 一样（SkyCutGates.alwaysAnswered，方案第八节第 5 条）。
// 不管什么：说明书的内容、怎么挑、一次回多少（MCPGuide / MCPGuideTopics / MCPGuideFields，在库里：小程序和自检都编得到）。
// 由 App 答而不是小程序当场答：说明永远和正在跑的 App 一致（同 recipes，docs/plans/2026-11-09-mcp-guide.md 2.3）。

enum AIGuideTools {
    static func guide(_ args: AIToolArguments) throws -> AIToolResult {
        .ok(MCPGuide.answer(topic: try args.string("topic"), section: try args.string("section")))
    }
}
