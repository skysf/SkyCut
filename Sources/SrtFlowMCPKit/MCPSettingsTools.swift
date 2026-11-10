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
                Read-only. App preferences without opening windows: general (language, theme), ai (clients, permission mode), editing \
                (styles, voices), cache and sky_studio (account, credits, daily limit). Returns values, writable fields and the \
                localized mode names; never keys. Change them with set_settings.
                """,
                input: MCPSchema.object([
                    "section": MCPSchema.string("Default all.", oneOf: ["all", "general", "ai", "editing", "cache", "sky_studio"])
                ]), readOnly: true
            )
        case .setSettings:
            return MCPToolDefinition(
                .setSettings, title: "Change SkyCut settings",
                description: """
                Change preferences only when the user asks: theme, language, daily_ai_credit_limit, ai_access_mode, the optimized-media cache. \
                Omitted fields stay; all are checked before any change. Changing ai_access_mode or raising the credit limit always returns \
                needs_confirmation, even in full_access: ask, repeat with confirm_token. Never edits a project; keys stay in Settings.
                """,
                input: MCPSchema.object([
                    "language": MCPSchema.string("Interface language.", oneOf: ["system", "en", "zh-Hans", "es"]),
                    "theme": MCPSchema.string("UI palette; forest is default. No project edit.", oneOf: ["forest", "classic"]),
                    "optimized_media_cache_gb": [
                        "type": "integer", "enum": [2, 5, 10, 20, 50],
                        "description": "Cache limit in decimal GB, matching the Settings picker."
                    ],
                    "clear_optimized_media_cache": MCPSchema.boolean("true clears regenerable preview media; false does nothing."),
                    "daily_ai_credit_limit": MCPSchema.integer("Hard daily AI budget in credits; 0 blocks paid tasks; raising it asks first.", minimum: 0, maximum: 1_000_000),
                    "ai_access_mode": MCPSchema.string("App-wide permission mode; every change needs the user's yes and confirm_token.", oneOf: ["ask_for_approval", "full_access"]),
                    "confirm_token": MCPSchema.confirmToken
                ])
            )
        default:
            preconditionFailure("\(name) is not a settings tool")
        }
    }
}
