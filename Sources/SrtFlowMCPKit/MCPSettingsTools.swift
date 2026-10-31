import Foundation

// MARK: - 工具清单：查询 / 修改全 App 设置
// 参数是明确的白名单；不提供任意 UserDefaults、密钥或客户端配置文件写入。
// 设置值与执行仍在 App 的 AISettingsTools，与原生设置窗口共用 Store。

enum MCPSettingsTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getSettings:
            return MCPToolDefinition(
                .getSettings, title: "Read SkyCut settings",
                description: """
                Read SkyCut's app-wide settings, matching the toolbar gear, SkyCut menu > Settings and Command-comma. \
                Sections: general (interface language), ai (client connections and remembered read permissions), editing \
                (editing styles and local voices), cache (optimized media), sky_studio (account, plan, credits and daily AI \
                limit). Omit section for all. Returns current values, writable fields and tools for related actions. \
                Never returns API keys or client configuration contents. Does not open windows, switch projects or start \
                an editing round. Use set_settings to change supported preferences; use recipes/save_recipe for styles \
                and add_voiceover download_voices=true for local voices. Sensitive account and AI connection actions \
                stay in Settings. These tools follow SkyCut's existing MCP plan entitlement.
                """,
                input: MCPSchema.object([
                    "section": MCPSchema.string("Default all.", oneOf: ["all", "general", "ai", "editing", "cache", "sky_studio"])
                ]), readOnly: true
            )
        case .setSettings:
            return MCPToolDefinition(
                .setSettings, title: "Change SkyCut settings",
                description: """
                Change app-wide preferences using the same stores as Settings. Only change what the user requests. \
                Omitted or null fields stay unchanged; pass at least one change. All values are validated before anything \
                is applied: an invalid value changes nothing. language updates the app immediately; native menus and \
                system dialogs follow after a restart. Cache sizes are decimal GB; lowering the limit evicts old optimized \
                media. Clearing removes regenerable preview media only, never source files, and may finish asynchronously: \
                query get_settings section=cache until clearing=false. daily_ai_credit_limit is the automatic AI spending \
                allowance, not a hard spending cap: 0 asks for every paid task; raising it permits more spending without \
                confirmation. Returns the updated settings. No project switch, timeline undo step or editing round. \
                API keys, client connections and new read permissions cannot be changed here.
                """,
                input: MCPSchema.object([
                    "language": MCPSchema.string("Interface language.", oneOf: ["system", "en", "zh-Hans", "es"]),
                    "optimized_media_cache_gb": [
                        "type": "integer", "enum": [2, 5, 10, 20, 50],
                        "description": "Cache limit in decimal GB, matching the Settings picker."
                    ],
                    "clear_optimized_media_cache": MCPSchema.boolean("true clears regenerable preview media; false does nothing."),
                    "daily_ai_credit_limit": MCPSchema.integer("Automatic daily AI spending allowance in credits; 0 asks every time.", minimum: 0, maximum: 1_000_000)
                ])
            )
        default:
            preconditionFailure("\(name) is not a settings tool")
        }
    }
}
