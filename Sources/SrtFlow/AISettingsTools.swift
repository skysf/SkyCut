import Foundation
import SrtFlowMCPKit

// MARK: - MCP 与设置窗口共用的数据入口
//
// 管什么：五类设置的无密钥快照、白名单偏好写入；所有字段先验完再同步落到既有 Store。
// 不管什么：任意 defaults、客户端配置或钥匙串的写入；工程与撤销；客户端连接和账号操作仍由设置窗口提供。

@MainActor
enum AISettingsTools {
    static func read(_ args: AIToolArguments) async throws -> AIToolResult {
        let section = try args.choice("section", from: ["all"] + SettingsCategory.allCases.map(\.rawValue)) ?? "all"
        return .ok(await snapshot(section: section))
    }

    static func update(_ args: AIToolArguments) async throws -> AIToolResult {
        // 在第一处写入之前读完、验完：不出现语言已改、后面的额度却报错的半次更新。
        let language = try args.choice("language", from: AppLanguage.allCases.map(\.rawValue)).flatMap(AppLanguage.init(rawValue:))
        let capacityGB = try args.int("optimized_media_cache_gb")
        if let capacityGB, !OptimizedMediaStore.capacityPresets.contains(Int64(capacityGB) * 1_000_000_000) {
            throw AIToolError("optimized_media_cache_gb must match a Settings preset: 2, 5, 10, 20 or 50.")
        }
        let limit = try args.double("daily_ai_credit_limit")
        if let limit, SkyStudioSpendStore.clamped(limit) != limit {
            throw AIToolError("daily_ai_credit_limit must be a whole number from 0 to 1000000.")
        }
        let clear = try args.bool("clear_optimized_media_cache") ?? false
        guard language != nil || capacityGB != nil || limit != nil || clear else {
            throw AIToolError("Pass at least one setting to change, or clear_optimized_media_cache=true. Use get_settings to read settings.")
        }

        if let language { AppLanguageStore.shared.language = language }
        if let capacityGB { OptimizedMediaCacheSettings.shared.setCapacity(Int64(capacityGB) * 1_000_000_000) }
        if let limit { SkyStudioSpendStore.shared.setDailyLimit(limit) }
        if clear { OptimizedMediaCacheSettings.shared.clear() }
        return .ok(await snapshot(section: "all"))
    }

    private static func snapshot(section: String) async -> JSONValue {
        var sections: [String: JSONValue] = [:]
        for category in SettingsCategory.allCases where section == "all" || section == category.rawValue {
            switch category {
            case .general:
                let language = AppLanguageStore.shared
                sections[category.rawValue] = [
                    "language": .string(language.language.rawValue),
                    "effective_language": .string(language.language.resolvedCode),
                    "available_languages": .array(AppLanguage.allCases.map { ["id": .string($0.rawValue), "name": .string($0.nativeName)] }),
                    "menus_need_restart": .bool(language.needsRestartForMenus),
                    "writable_fields": ["language"]
                ]
            case .ai:
                let setup = AIClientSetup.shared
                setup.refresh()
                sections[category.rawValue] = [
                    "clients": .array(AIClientSetup.Client.allCases.map { client in
                        ["id": .string(client.rawValue), "name": .string(client.title), "status": .string(clientStatus(setup.statuses[client]))]
                    }),
                    "remembered_read_permissions": .array(AIReadGrants.shared.paths.map(JSONValue.string)),
                    "actions": "Connect or disconnect clients and revoke remembered read permissions in Settings > Connect AI. New permissions require the existing reading confirmation flow."
                ]
            case .editing:
                let pack = KokoroVoicePack.shared
                var voice: [String: JSONValue] = ["status": .string(voiceStatus(pack.state))]
                if let progress = pack.fraction { voice["progress"] = .number(progress) }
                sections[category.rawValue] = [
                    "local_voices": .object(voice),
                    "styles": "Use recipes to list or read editing styles; save_recipe saves a user style. Settings > Editing & Voices shows user styles in Finder and can move them to the Trash.",
                    "voice_actions": "Use add_voiceover download_voices=true to install local voices and get_job to follow progress. Settings > Editing & Voices also has download, stop and remove controls."
                ]
            case .cache:
                let cache = OptimizedMediaCacheSettings.shared
                await cache.refresh()
                sections[category.rawValue] = [
                    "optimized_media_cache_gb": .number(Double(cache.capacityBytes) / 1_000_000_000),
                    "available_cache_gb": .array(OptimizedMediaStore.capacityPresets.map { .number(Double($0) / 1_000_000_000) }),
                    "used_bytes": cache.usedBytes.map { .number(Double($0)) } ?? .null,
                    "clearing": .bool(cache.isClearing),
                    "writable_fields": ["optimized_media_cache_gb", "clear_optimized_media_cache"],
                    "note": "Usage counts indexed preview media. Clearing or lowering the cap never deletes source files; previews regenerate as needed."
                ]
            case .skyStudio:
                let account = SkyStudioAccount.shared
                let spending = SkyStudioSpendStore.shared
                var studio: [String: JSONValue] = [
                    "api_key_configured": .bool(account.hasKey),
                    "plan": SkyCutGates.statusJSON(license: account.license, problem: account.problem, now: Date()),
                    "daily_ai_credit_limit": .number(spending.dailyLimit),
                    "spent_today": .number(spending.spentToday()),
                    "writable_fields": ["daily_ai_credit_limit"],
                    "account_actions": "Manage the API key and check the account in Settings > Sky Studio. Keys are never returned or accepted by these tools."
                ]
                if let me = account.stored?.me {
                    studio["email"] = me.account.email.map(JSONValue.string) ?? .null
                    studio["credit_balance_at_last_check"] = .number(me.credits.balance)
                }
                sections[category.rawValue] = .object(studio)
            }
        }
        return [
            "scope": "app", "sections": .object(sections),
            "settings_window": "Toolbar gear, SkyCut > Settings and Command-comma open the same window and stores.",
            "workbench": "Library, Record Screen and Subtitles are icon buttons at the left; project menu in the middle; AI activity, Export, Settings and More at the right. More contains Compress Video, Burn In Subtitles, Batch Convert and AI Projects. AI status details can be closed without hiding a running round."
        ]
    }

    private static func clientStatus(_ status: AIClientSetup.Status?) -> String {
        switch status {
        case .notInstalled?: return "not_installed"
        case .notConnected?: return "not_connected"
        case .connected?: return "connected"
        case .connectedAsking?: return "connected_needs_approval"
        case .connectedElsewhere?: return "connected_to_another_copy"
        case nil: return "unknown"
        }
    }

    private static func voiceStatus(_ state: KokoroVoicePack.State) -> String {
        switch state {
        case .installed: return "downloaded"
        case .notInstalled: return "not_downloaded"
        case .downloading: return "downloading"
        case .failed: return "failed"
        }
    }
}
