import Foundation
import SrtFlowMCPKit

// 给 AI 的文字（总说明 + 工具清单）按客户端怎么读来守（docs/architecture/ai-control-mcp.md 第一节第 6 条）：
// - Claude Code 只保留总说明和**每个工具说明**的前 2,048 个字符（JavaScript 的字符串长度 = UTF-16 单位），多出来的静默截掉；
//   2026-09-30 之前总说明 4,433 字、edit_clip 的说明 2,074 字，后半截它从来没读到过
//   （docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md）；
// - Codex 要求总说明的前 512 个字符自成一体；
// - 总说明是入口 + 主动规矩 + 怎么读说明书，≤ 1,200 字（2026-11-09 用户定，方案第八节第 1、2 条）：Codex 每打印一个工具条目就带一份整份总说明；
//   按任务分组的工具目录搬进了说明书的地图（每个工具都列在地图上，GuideChecks 查），这里不再要求每个工具名都在总说明里；
// - 只用英文（2026-09-30 用户定）。
// 总说明量「没配提供方」和「每个提供方都配好」两种样子（配了 fal 多一行），工具说明量全份清单。

/// Claude Code 截断的上限：它的 MCP 客户端里写死的 2048，超过就截、末尾加「… [truncated]」。2.1.296 起总说明和预先加载的工具 4,096、
/// 按需加载的工具 16,384（官方文档）；工具说明仍按 2,048 守，迁移完（方案 PR 6）换成名片 ≤ 450。
let claudeCodeTextLimit = 2_048
/// 总说明的上限（方案 4.1）：样稿约 1,000 字。
let instructionsLimit = 1_200

func runCatalogTextChecks() {
    for providers in [Set<MCPProvider>(), Set(MCPProvider.allCases)] {
        let label = providers.isEmpty ? "no provider" : "all providers"
        let text = MCPInstructions.text(providers: providers)
        check(text.utf16.count <= instructionsLimit,
              "\(label): the instructions fit \(instructionsLimit) characters (they are \(text.utf16.count))")
        let opening = String(decoding: Array(text.utf16.prefix(512)), as: UTF16.self)
        for core in ["open_folder", "get_timeline", "look", "export_video", "skycut_guide"] {
            check(mentions(opening, core), "\(label): the first 512 characters name \(core) (Codex wants them to stand on their own)")
        }
        check(!containsChinese(text), "\(label): the instructions are English only")
    }
    for tool in MCPToolName.allCases {
        let description = tool.definition.description
        check(description.utf16.count <= claudeCodeTextLimit,
              "\(tool.rawValue): the description fits in Claude Code's \(claudeCodeTextLimit) characters (it is \(description.utf16.count))")
    }
    // 偏好工具属于 App，不依赖 / 抢占某个工程；读写提示会影响客户端授权行为。
    check(MCPToolName.getSettings.definition.readOnly, "get_settings is read-only")
    check(!MCPToolName.setSettings.definition.readOnly, "set_settings declares its writes")
    for tool in [MCPToolName.getSettings, .setSettings] {
        check(!tool.takesProject, "\(tool.rawValue) has app scope")
        check(MCPArgumentCheck.problem(tool: tool, arguments: ["api_key": "do-not-accept"]) != nil,
              "\(tool.rawValue) rejects credentials rather than silently ignoring them")
    }
    check(!containsChinese(MCPToolName.listJSON.encodedString()), "the tool list (names, descriptions, parameters, choices) is English only")
    for tool: MCPToolName in [.listCharacters, .getCharacter, .manageCharacters] {
        check(tool.definition.description.utf16.count <= 512, "\(tool.rawValue)'s complete minimum workflow fits its first 512 characters")
        check(!tool.takesProject, "\(tool.rawValue) is an account library operation, not a timeline edit")
    }
    check(MCPToolName.listCharacters.definition.readOnly && MCPToolName.getCharacter.definition.readOnly, "character discovery is free and read-only")
    check(!MCPToolName.manageCharacters.definition.readOnly && MCPToolName.manageCharacters.definition.destructive, "Character writes declare library mutations/deletion")
    check(MCPToolName.listCharacters.definition.inputSchema["properties"]?["capabilities"] != nil, "Character capabilities have a read-only entry")
    check(MCPToolName.listCharacters.definition.description.contains("compact summaries") && MCPToolName.listCharacters.definition.description.contains("1 KiB"), "list explains bounded summaries before requesting full character details")
    check(MCPArgumentCheck.problem(tool: .manageCharacters, arguments: ["action": "create", "aspect_ratio": "21:9"]) != nil, "native Character shapes cannot be caller parameters")
    let total = JSONValue.object(["tools": MCPToolName.listJSON]).encodedString().utf16.count
    print("MCP catalog including tools envelope: \(total)/110000 UTF-16 units; instructions: \(MCPInstructions.text.utf16.count)/\(instructionsLimit).")
}

/// 名字作为一个整词出现：`look` 不算 `looks` 里的那个，`undo` 不算 `undoes`（下划线算词的一部分）。
private func mentions(_ text: String, _ name: String) -> Bool {
    text.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
}

/// 汉字、中日文标点和全角符号（给 AI 的文字只用英文；GuideChecks 也用它查说明书）。
func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
