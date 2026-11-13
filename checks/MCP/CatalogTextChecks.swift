import Foundation
import SrtFlowMCPKit

// 给 AI 的文字（总说明 + 工具清单）按客户端怎么读来守（docs/architecture/ai-control-mcp.md 第一节第 6 条）：
// - Claude Code 2.1.296 之前只保留总说明和**每个工具说明**的前 2,048 个字符（JavaScript 的字符串长度 = UTF-16 单位），多出来的静默截掉
//   （之后总说明和预先加载的 4,096、按需加载的 16,384，下面的上限都比它严）；2026-09-30 之前总说明 4,433 字、edit_clip 的说明 2,074 字，后半截它从来没读到过
//   （docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md）；
// - Codex 要求总说明的前 512 个字符自成一体；
// - 总说明是入口 + 主动规矩 + 怎么读说明书，≤ 1,200 字（2026-11-09 用户定，方案第八节第 1、2 条）：Codex 每打印一个工具条目就带一份整份总说明；
//   按任务分组的工具目录搬进了说明书的地图（每个工具都列在地图上，GuideChecks 查），这里不再要求每个工具名都在总说明里；
// - 名片 ≤ 450、参数说明 ≤ 120 且写范围、参数定义 ≤ 4,500 字节（例外 edit_clip、generate_media）：2026-11-10 迁移完起对全部工具（方案 4.1、PR 6）；
// - 只用英文（2026-09-30 用户定）。
// 总说明量「没配提供方」和「每个提供方都配好」两种样子（2026-10-30 起两样一字不差，ProviderChecks 查；配了 fal 多一行是之前的事），
// 工具说明量全份清单。

/// 总说明的上限（方案 4.1）：样稿约 1,000 字。
let instructionsLimit = 1_200
/// 每个工具的说明（名片）的上限（方案 4.1，目标 350）：2026-11-10 迁移完（方案 PR 6）起对全部工具生效，替掉原来按 Claude Code 截断
/// 定的 2,048（2.1.296 起它按需加载的工具留 16,384，总说明和预先加载的 4,096）。名片之外的话进说明书（skycut_guide）。
let cardLimit = 450
/// 每条参数说明的上限（目标 80）；带 minimum / maximum 的要把范围写成数字（Codex 把参数定义转成 TypeScript 时不显示范围）。
let parameterLimit = 120
/// 单个工具参数定义的上限（UTF-8 字节）：Codex 默认超过 5,000 字节就删光参数说明，留 500 余量。
let schemaByteLimit = 4_500
/// 参数定义超过 4,500 字节的例外（方案 4.1：先列例外，名单不许变长）；它们的名片要带上会影响对错的语义。
let schemaExceptions: Set<MCPToolName> = [.editClip, .generateMedia]

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
        let definition = tool.definition
        check(definition.description.utf16.count <= cardLimit,
              "\(tool.rawValue): the card fits \(cardLimit) characters (it is \(definition.description.utf16.count))")
        let bytes = definition.inputSchema.encodedString().utf8.count
        if !schemaExceptions.contains(tool) {
            check(bytes <= schemaByteLimit, "\(tool.rawValue): the parameters fit \(schemaByteLimit) bytes (they are \(bytes))")
        }
        walkParameters(definition.inputSchema, path: tool.rawValue)
    }
    checkEqual(schemaExceptions, [.editClip, .generateMedia], "the over-4,500-byte exceptions stay edit_clip and generate_media only")
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
    print("MCP catalog including tools envelope: \(catalogSize(MCPToolName.listJSON))/\(catalogBudget) UTF-16 units; instructions: \(MCPInstructions.text.utf16.count)/\(instructionsLimit).")
}

/// 每条参数说明 ≤ 120；带范围的写着数字。
private func walkParameters(_ schema: JSONValue, path: String) {
    for (name, field) in schema["properties"]?.objectValue ?? [:] {
        let here = "\(path).\(name)"
        let description = field["description"]?.stringValue ?? ""
        check(description.utf16.count <= parameterLimit, "\(here): the description fits \(parameterLimit) characters (it is \(description.utf16.count))")
        if field["minimum"] != nil || field["maximum"] != nil {
            check(description.range(of: #"\d"#, options: .regularExpression) != nil, "\(here): the description spells out its range in numbers")
        }
        walkParameters(field, path: here)
        if let items = field["items"] { walkParameters(items, path: here + "[]") }
    }
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
