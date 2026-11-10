import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio 声音库的接口（`/voices`、`/voices/consent-grant`）
//
// 管什么：列出 / 取一个 / 用录音新建 / 加一种语言的录音 / 改名 / 删除用户自己的声音，和长期授权的读、记、撤（Sky Studio 声音方案 3.3）。
// 全部免费；只看得见自己的声音，别人的 id 一律 404 `not_found`。认证、版本号、机器号、错误怎么分照旧只在 SkyStudioAPI 的
// `request` / `send` 里（checks/sky-studio-wiring.sh 钉着）；这里只拼路径、读回答。
// 路径里的声音 id 只认 `voice_` + 32 位十六进制（SkyStudioVoicePath），别的样子不许拼进地址。
// 不管什么：建 MiniMax 版、设计、变声（那三种是 `/quote` + `/jobs` 的任务：SkyStudioVoiceRequests + SkyStudioJobRun）；
// 问不问用户、全部权限下怎么做（声音 PR 6 / 7）；删除回 503 时再发一次（调用方的事：声音保持「删除中」，再发一次 DELETE 接着删）。

enum SkyStudioVoicePath {
    static let library = "voices"
    static let consentGrant = "voices/consent-grant"

    static func voice(_ id: String) throws -> String {
        guard SkyStudioVoice.isVoiceID(id) else { throw SkyStudioVoiceRequestProblem(message: "Use a voice id from the user's voice library (voice_…).") }
        return library + "/" + id
    }

    static func references(_ id: String) throws -> String { try voice(id) + "/references" }
}

extension SkyStudioAPI {
    /// `GET /voices`：自己的声音（每个账号最多 50 个，一页回完）。
    func voices(limit: Int = 50, cursor: String? = nil, key: String) async throws -> SkyStudioVoicePage {
        guard (1...100).contains(limit), cursor.map({ !$0.isEmpty && $0.count <= 512 }) ?? true else {
            throw SkyStudioVoiceRequestProblem(message: "Voice pages take limit 1–100 and a cursor Sky Studio returned.")
        }
        var call = request(SkyStudioVoicePath.library, key: key)
        var components = URLComponents(url: call.url!, resolvingAgainstBaseURL: false)!
        // 游标是服务器给的、不透明：`queryItems` 不转义 & = +，自己转义好再放进去，免得拼出别的参数。
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+;#"))
            guard let encoded = cursor.addingPercentEncoding(withAllowedCharacters: allowed) else { throw SkyStudioFailure.badAnswer(status: 200) }
            items.append(URLQueryItem(name: "cursor", value: encoded))
        }
        components.percentEncodedQueryItems = items
        call.url = components.url
        let json = try Self.voiceJSON(try await send(call))
        guard let list = json["voices"]?.arrayValue, list.count <= limit else { throw SkyStudioFailure.badAnswer(status: 200) }
        let next = json["next_cursor"]
        guard next == nil || next?.isNull == true || next?.stringValue?.isEmpty == false else { throw SkyStudioFailure.badAnswer(status: 200) }
        return SkyStudioVoicePage(voices: try list.map(SkyStudioVoice.init(json:)), nextCursor: next?.stringValue)
    }

    /// `GET /voices/{id}`：一个声音（试听链接每次都是新的 1 小时临时链接）。
    func voice(_ id: String, key: String) async throws -> SkyStudioVoice {
        try Self.voice(in: try await send(request(try SkyStudioVoicePath.voice(id), key: key)), id: id)
    }

    /// `POST /voices`：用一段录音新建声音（免费）。同一个 `idempotency_key` 重发回同一个声音。
    func createVoice(_ creation: SkyStudioVoiceCreation, key: String) async throws -> SkyStudioVoice {
        let body = try creation.body.encodedData()
        let voice = try Self.voice(in: try await send(request(SkyStudioVoicePath.library, key: key, method: "POST", body: body)), id: nil)
        guard voice.language(creation.language) != nil else { throw SkyStudioFailure.badAnswer(status: 200) }
        return voice
    }

    /// `POST /voices/{id}/references`：给已有的声音加一种语言的录音（这种语言已经有了回 409 `reference_exists`）。
    func addVoiceReference(_ reference: SkyStudioVoiceReference, to id: String, key: String) async throws -> SkyStudioVoice {
        let body = try reference.body.encodedData()
        let voice = try Self.voice(in: try await send(request(try SkyStudioVoicePath.references(id), key: key, method: "POST", body: body)), id: id)
        guard voice.language(reference.language) != nil else { throw SkyStudioFailure.badAnswer(status: 200) }
        return voice
    }

    /// `PATCH /voices/{id}`：改名。
    func renameVoice(_ id: String, to name: String, key: String) async throws -> SkyStudioVoice {
        let name = try SkyStudioVoiceNaming.checked(name)
        let body = try JSONValue.object(["name": .string(name)]).encodedData()
        let voice = try Self.voice(in: try await send(request(try SkyStudioVoicePath.voice(id), key: key, method: "PATCH", body: body)), id: id)
        guard voice.name == name else { throw SkyStudioFailure.badAnswer(status: 200) }
        return voice
    }

    /// `DELETE /voices/{id}`：**立刻全删、不可恢复**（录音、样音、MiniMax 版都删）。存储暂时不可用回 503（声音已经看不见、用不了）。
    func deleteVoice(_ id: String, key: String) async throws {
        let json = try Self.voiceJSON(try await send(request(try SkyStudioVoicePath.voice(id), key: key, method: "DELETE")))
        guard json["deleted"]?.boolValue == true else { throw SkyStudioFailure.badAnswer(status: 200) }
    }

    /// `GET /voices/consent-grant`：这个账号记没记过长期授权、是哪一版、还有效没有（文案过期算无效）。
    func voiceConsentGrant(key: String) async throws -> SkyStudioVoiceConsentState {
        try SkyStudioVoiceConsentState(json: try Self.voiceJSON(try await send(request(SkyStudioVoicePath.consentGrant, key: key))))
    }

    /// `POST /voices/consent-grant`：用户打开全部权限、同意那句话时记一条长期授权（同一版重复记回原来那条）。
    func recordVoiceConsentGrant(statementVersion: String, key: String) async throws -> SkyStudioVoiceConsentState {
        guard !statementVersion.isEmpty else { throw SkyStudioVoiceRequestProblem(message: "The standing consent needs the statement version.") }
        let body = try JSONValue.object(["statement_version": .string(statementVersion)]).encodedData()
        let state = try SkyStudioVoiceConsentState(json: try Self.voiceJSON(
            try await send(request(SkyStudioVoicePath.consentGrant, key: key, method: "POST", body: body))
        ))
        guard let grant = state.grant, grant.active, grant.statementVersion == statementVersion else { throw SkyStudioFailure.badAnswer(status: 200) }
        return state
    }

    /// `DELETE /voices/consent-grant`：用户关掉全部权限时撤销（记录保留，再打开就再记一条）。
    func revokeVoiceConsentGrant(key: String) async throws {
        let json = try Self.voiceJSON(try await send(request(SkyStudioVoicePath.consentGrant, key: key, method: "DELETE")))
        if json["grant"] != nil, (try? SkyStudioVoiceConsentState(json: json))?.hasActiveGrant != false {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
    }

    // MARK: 读回答

    private static func voiceJSON(_ data: Data) throws -> JSONValue {
        guard let json = try? JSONValue.decode(data), json.objectValue != nil else { throw SkyStudioFailure.badAnswer(status: 200) }
        return json
    }

    /// `{"voice": {...}}`；问的是哪一个，回的就得是哪一个。
    private static func voice(in data: Data, id: String?) throws -> SkyStudioVoice {
        let voice = try SkyStudioVoice(json: try voiceJSON(data)["voice"] ?? .null)
        if let id, voice.id != id { throw SkyStudioFailure.badAnswer(status: 200) }
        return voice
    }
}
