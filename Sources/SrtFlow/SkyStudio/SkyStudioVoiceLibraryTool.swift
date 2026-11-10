import Foundation
import SrtFlowMCPKit

// MARK: - list_voices / manage_voices：AI 动用户的 Sky Studio 声音库
//
// 管什么（SkyCut 声音方案 4.6）：
// - list_voices（只读、免费）：预设名单（`/models`，按语言）+ 我的声音（`GET /voices`）。声音库用不了（503 `voice_library_unavailable`）
//   时照回预设，`mine` 写一句「暂时用不了」，不让整个调用失败。
// - manage_voices（写；服务器上的事，不登记时间线撤销）：create / add_reference 交给 SkyStudioVoiceRecordingTool（授权），
//   design 交给 SkyStudioVoiceDesignTool（一次性费用）；改名、删除在这里。删除：请求批准模式问一句、全部权限直接删
//   （SkyStudioJobGate.voiceDeletion）；存储一时不可用（503 `voice_library_unavailable` + `reason: storage_unavailable`）再发一次，
//   还不行就说「已经从声音库里看不见了，再调一次 delete 接着删」。正在删的声音 GET 不到（404），所以问句里写 id、照样 DELETE。
// Key 只静默读（SkyStudioVoiceServices，不弹钥匙串框）；`/voices` 的请求只经 SkyStudioAPI（SkyStudioVoiceAPI）。
// 不管什么：配旁白用声音库的声音（add_voiceover，SkyStudioVoiceoverStart）、列出来长什么样（SkyStudioVoiceListing）、错误怎么说
// （SkyStudioVoiceLibraryErrors）。

@MainActor
enum SkyStudioVoiceLibraryTool {
    static func list(_ args: AIToolArguments, services: SkyStudioVoiceServices? = nil) async throws -> AIToolResult {
        let services = services ?? SkyStudioVoiceServices()
        let include = try args.choice("include", from: MCPVocabulary.voiceListIncludes) ?? "all"
        let languages = try args.string("language").map { [try checkedLanguage($0)] } ?? ["zh", "en"]
        let key = try await services.key()
        var result: [String: JSONValue] = [:]
        if include != "mine" {
            let catalog: SkyStudioCatalog
            do { catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api) }
            catch is CancellationError { throw CancellationError() }
            catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
            guard let voices = catalog.voices else { throw AIToolError("Sky Studio does not list its voices yet.") }
            result["presets"] = .array(languages.map { SkyStudioVoiceListing.presets(voices, language: $0) })
        }
        if include != "presets" {
            do { result["mine"] = SkyStudioVoiceListing.mine(try await services.api.voices(key: key)) }
            catch is CancellationError { throw CancellationError() }
            catch where SkyStudioVoiceLibraryErrors.isUnavailable(error) {
                result["mine"] = ["unavailable": true, "note": .string(SkyStudioVoiceLibraryErrors.unavailable)]
            } catch {
                throw AIToolError(SkyStudioVoiceLibraryErrors.message(error))
            }
        }
        return .ok(.object(result))
    }

    static func manage(_ args: AIToolArguments, _ project: VideoEditProject, services: SkyStudioVoiceServices? = nil) async throws -> AIToolResult {
        let services = services ?? SkyStudioVoiceServices()
        guard let action = try args.choice("action", from: MCPVocabulary.voiceLibraryActions) else {
            throw AIToolError("action is required: \(MCPVocabulary.voiceLibraryActions.joined(separator: ", ")).")
        }
        switch action {
        case "create", "add_reference": return try await SkyStudioVoiceRecordingTool.run(action, args, project, services: services)
        case "design": return try await SkyStudioVoiceDesignTool.run(args, project, services: services)
        case "rename": return try await rename(args, services: services)
        case "delete": return try await delete(args, services: services)
        // 词表多了一样、这里没跟上：什么都不做（删除不许是落空的那一支）。
        default: throw AIToolError("manage_voices cannot do \(action) yet. Nothing was changed.")
        }
    }

    private static func rename(_ args: AIToolArguments, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let id = try voiceID(args)
        let name = try args.requiredString("name")
        let key = try await services.key()
        do {
            let voice = try await services.api.renameVoice(id, to: name, key: key)
            return .ok(["status": "renamed", "voice": voice.json])
        } catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
    }

    private static func delete(_ args: AIToolArguments, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let id = try voiceID(args)
        let key = try await services.key()
        // 名字只为问句：正在删的声音 GET 不到（404），照样问（写 id）、照样发 DELETE 把它删完。
        var name: String?
        do { name = try await services.api.voice(id, key: key).name }
        catch is CancellationError { throw CancellationError() }
        catch where SkyStudioVoiceLibraryErrors.isNotFound(error) { name = nil }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
        let action = SkyStudioVoiceApproval.deletionAction(voice: id, account: SkyStudioCharacterAccess.stamp(key))
        if let question = SkyStudioJobGate.voiceDeletion(action: action, question: SkyStudioVoiceApproval.deletionQuestion(name: name ?? id),
                                                        token: try args.string("confirm_token")) {
            return question
        }
        do {
            try await deleteOnce(id, key: key, services: services)
        } catch where SkyStudioVoiceLibraryErrors.isStorageRetry(error) {
            // 存储一时不可用：声音已经看不见了，再发一次接着删（Sky Studio 声音方案 3.3）。
            do { try await deleteOnce(id, key: key, services: services) }
            catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
        } catch {
            throw AIToolError(SkyStudioVoiceLibraryErrors.message(error))
        }
        return .ok(["status": "deleted", "voice": .string(id), "name": name.map(JSONValue.string) ?? .null,
                    "next_step": "Tell the user the voice was deleted for good; its recordings are gone too."])
    }

    private static func deleteOnce(_ id: String, key: String, services: SkyStudioVoiceServices) async throws {
        try await services.api.deleteVoice(id, key: key)
    }

    private static func voiceID(_ args: AIToolArguments) throws -> String {
        let id = try args.requiredString("voice").trimmingCharacters(in: .whitespacesAndNewlines)
        guard SkyStudioVoice.isVoiceID(id) else {
            throw AIToolError("voice must be a voice_… id from list_voices (the user's library); presets cannot be changed.")
        }
        return id
    }

    private static func checkedLanguage(_ language: String) throws -> String {
        do { return try SkyStudioVoiceNaming.checkedLanguage(language.lowercased()) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message) }
    }
}
