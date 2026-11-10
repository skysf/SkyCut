import Foundation
import SrtFlowMCPKit

// 全清单的上限和量法只有这一份（MCP 按需说明方案 4.1、4.2）。
// 2026-11-10 迁移完（方案 PR 6）收到 100,000：以后加工具只能先把说明挪进说明书，「为说明文字抬上限」不再做。
// 以前 ProtocolChecks（逐个工具相加、按 Character 数）、UsageExampleChecks 和 ProductionSchemaChecks（带外壳、按 UTF-16）
// 各写一个 110,000，口径还不一样（2026-11-03 的案例里两个数对不上）；现在三处都调这里，和 CatalogTextChecks 打印的那一行同一个数。
//
// 上限的来历（都是用户定的）：72,000 → 80,000（2026-10-02，upscale_clip）→ 90,000（2026-10-14，审美盲测的六样功能）
// → 100,000（2026-10-17，碰工程的工具多一个 project）→ 110,000（2026-11-07，角色 A/B 的三个工具）→ 100,000（2026-11-09 方案第八节第 2 条，迁移完生效）。

/// 全清单（每个提供方都配好时的整份 tools/list）的上限，UTF-16 单位。
let catalogBudget = 100_000

/// 带外壳的 tools/list JSON（`{"tools":[…]}`）按 UTF-16 数：客户端收到的就是这一段。
func catalogSize(_ tools: JSONValue) -> Int {
    JSONValue.object(["tools": tools]).encodedString().utf16.count
}
