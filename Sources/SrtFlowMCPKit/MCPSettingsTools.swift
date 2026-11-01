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
                Read app-wide settings without opening windows or editing: general (language), ai (connections, permissions), \
                editing (styles/voices), cache, sky_studio (account/credits/hard budget). Omit section for all. Returns current values, \
                writable fields, localized mode names and action hints; never keys/config contents. Use set_settings for preferences, \
                recipes/save_recipe for styles, add_voiceover download_voices=true for local voices. MCP plan entitlement still applies.
                """,
                input: MCPSchema.object([
                    "section": MCPSchema.string("Default all.", oneOf: ["all", "general", "ai", "editing", "cache", "sky_studio"])
                ]), readOnly: true
            )
        case .setSettings:
            return MCPToolDefinition(
                .setSettings, title: "Change SkyCut settings",
                description: """
                Change only user-requested preferences; null/omitted fields stay unchanged. Validate everything before applying \
                anything. Any ai_access_mode change ALWAYS needs explicit agreement and confirm_token, even in full_access; so does \
                raising daily_ai_credit_limit. Ask in the conversation language, using localized names from get_settings section=ai. \
                Daily budgets are hard caps: 0 pauses paid work. Cache clearing removes previews only; query clearing=false to verify. \
                Language applies now; native menus after restart. No project edit. Keys/connections stay in Settings.
                """,
                input: MCPSchema.object([
                    "language": MCPSchema.string("Interface language.", oneOf: ["system", "en", "zh-Hans", "es"]),
                    "optimized_media_cache_gb": [
                        "type": "integer", "enum": [2, 5, 10, 20, 50],
                        "description": "Cache limit in decimal GB, matching the Settings picker."
                    ],
                    "clear_optimized_media_cache": MCPSchema.boolean("true clears regenerable preview media; false does nothing."),
                    "daily_ai_credit_limit": MCPSchema.integer("Hard daily AI budget in credits; 0 blocks paid tasks. Raising it requires confirmation.", minimum: 0, maximum: 1_000_000),
                    "ai_access_mode": MCPSchema.string("App-wide permission mode; any change ALWAYS needs user agreement and confirm_token.", oneOf: ["ask_for_approval", "full_access"]),
                    "confirm_token": MCPSchema.confirmToken
                ])
            )
        default:
            preconditionFailure("\(name) is not a settings tool")
        }
    }
}
