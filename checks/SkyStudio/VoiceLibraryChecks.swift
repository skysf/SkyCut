import Foundation
import SrtFlowMCPKit

// 声音 PR 1：声音库的 DTO 和 `/voices`、`/voices/consent-grant` 的请求（假协议 SkyStudioStub，不碰真的网络）。
// 样例照 Sky Studio 声音方案 3.3、3.5（声音的 DTO、长期授权的回答）。钉住：id 只认 `voice_` + 32 位十六进制、拼路径之前就拦；
// 建声音带名字 / 语言 / 上传地址 / 幂等 key / 两种授权；改名、删除、加录音的路径和方法；长期授权的三种状态；服务器的错原样留着。

let sampleVoiceID = "voice_9b1deb4d3b7d4bad9bdd2b0d7b3dcb6d"
let sampleVoice: JSONValue = [
    "id": .string(sampleVoiceID), "name": "Sky", "source": "recording", "scope": "personal", "team_id": .null,
    "languages": [
        ["language": "zh", "kind": "recording", "seconds": 29.95, "minimax": true,
         "preview_url": "https://r2.example/voices/u/v/ref-zh.wav?sig=1", "preview_expires_at": "2026-11-20T11:00:00Z"],
        ["language": "en", "kind": "recording", "seconds": 174.27, "minimax": false,
         "preview_url": "https://r2.example/voices/u/v/ref-en.wav?sig=2", "preview_expires_at": "2026-11-20T11:00:00.250Z"]
    ],
    "design": .null, "created_at": "2026-11-20T10:00:00Z", "updated_at": "2026-11-20T10:00:00Z"
]

func voiceAnswer(_ voice: JSONValue = sampleVoice) -> String { JSONValue.object(["voice": voice]).encodedString() }

func runVoiceLibraryChecks() async {
    runVoiceDTOChecks()
    await runVoiceListChecks()
    await runVoiceWriteChecks()
    await runConsentGrantChecks()
}

private func runVoiceDTOChecks() {
    for id in [sampleVoiceID, "voice_" + String(repeating: "0", count: 32)] { check(SkyStudioVoice.isVoiceID(id), "\(id) is a voice id") }
    for id in ["voice_9B1DEB4D3B7D4BAD9BDD2B0D7B3DCB6D", "voice_9b1d", "voice_" + String(repeating: "g", count: 32), "gemini:Charon",
               "Voice_" + String(repeating: "a", count: 32), "voice_" + String(repeating: "ａ", count: 32), sampleVoiceID + "0", "../voices"] {
        check(!SkyStudioVoice.isVoiceID(id), "\(id) is not a voice id")
    }
    guard let voice = try? SkyStudioVoice(json: sampleVoice) else { check(false, "the plan's voice DTO reads"); return }
    checkEqual(voice.name, "Sky", "name")
    checkEqual(voice.languages.map(\.language), ["zh", "en"], "one reference per language, in order")
    checkEqual(voice.language("zh")?.minimax, true, "zh has a MiniMax version")
    checkEqual(voice.language("en")?.minimax, false, "en does not yet")
    checkEqual(voice.language("en")?.seconds, 174.27, "seconds")
    check(voice.language("zh")?.previewURL?.query == "sig=1", "the preview link is kept to listen")
    check(voice.language("en")?.previewExpiresAt != nil, "a preview expiry with milliseconds reads")
    check(voice.teamID == nil && voice.design == nil, "team_id and design null")
    check(!voice.json.encodedString().contains("preview"), "temporary links are not reported onward")
    let designed = try? SkyStudioVoice(json: ["id": .string(sampleVoiceID), "name": "纪录片男声", "source": "design",
        "design": ["prompt": "温暖、沉稳的中年男声", "model": "minimax-voice-design", "language": "zh"],
        "languages": [["language": "zh", "kind": "design_sample", "seconds": 8.1, "minimax": true]]])
    checkEqual(designed?.design?.model, "minimax-voice-design", "a designed voice keeps its model")
    checkEqual(designed?.language("zh")?.kind, "design_sample", "its sample is the reference")
    for bad: JSONValue in [["name": "no id"], ["id": "voice_short", "name": "x"], ["id": .string(sampleVoiceID)], ["id": .string(sampleVoiceID), "name": ""]] {
        check((try? SkyStudioVoice(json: bad)) == nil, "not a voice: \(bad.encodedString())")
    }
}

private func runVoiceListChecks() async {
    let api = jobAPI()
    SkyStudioStub.reset { _ in .http(200, JSONValue.object(["voices": [sampleVoice], "next_cursor": .null]).encodedString()) }
    let page = try? await api.voices(key: jobKey)
    checkEqual(page?.voices.map(\.id), [sampleVoiceID], "the list reads")
    checkEqual(page?.nextCursor, nil, "no next page")
    let seen = SkyStudioStub.log.first
    checkEqual(seen?.method, "GET", "listing is a GET")
    checkEqual(seen?.url, "http://127.0.0.1:8123/api/skycut/v1/voices?limit=50", "the list address")
    checkEqual(seen?.headers["Authorization"], "Bearer \(jobKey)", "the key goes along")
    check(seen?.headers["X-SkyCut-Machine"] != nil && seen?.headers["X-SkyCut-Version"] == "0.18.50", "the usual SkyCut headers")

    SkyStudioStub.reset { _ in .http(200, JSONValue.object(["voices": [], "next_cursor": "c-2"]).encodedString()) }
    _ = try? await api.voices(limit: 10, cursor: "c 1&x", key: jobKey)
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/voices?limit=10&cursor=c%201%26x", "the cursor is query-encoded")
    SkyStudioStub.reset { _ in .http(200, JSONValue.object(["voices": [["id": "Voice123", "name": "x"]]]).encodedString()) }
    if case .badAnswer? = await expectFailure("a list with a foreign id", { _ = try await api.voices(key: jobKey) }) {} else {
        check(false, "a voice id that is not Sky Studio's is not an answer")
    }
    SkyStudioStub.reset { _ in .http(200, voiceAnswer()) }
    checkEqual(try? await api.voice(sampleVoiceID, key: jobKey).id, sampleVoiceID, "one voice")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/voices/\(sampleVoiceID)", "one voice's address")
    if case .badAnswer? = await expectFailure("the wrong voice", { _ = try await api.voice("voice_" + String(repeating: "1", count: 32), key: jobKey) }) {} else {
        check(false, "asking for one voice and getting another is not an answer")
    }
    SkyStudioStub.reset { _ in .http(200, voiceAnswer()) }
    do { _ = try await api.voice("../models", key: jobKey); check(false, "a path-like id must not reach the network") }
    catch { check(SkyStudioStub.log.isEmpty, "an id that is not voice_… is refused before any request") }

    SkyStudioStub.reset { _ in .http(503, #"{"error":{"code":"voice_library_unavailable","message":"The voice library is not available right now."}}"#) }
    if case .server(let error)? = await expectFailure("library unavailable", { _ = try await api.voices(key: jobKey) }) {
        checkEqual(error.code, SkyStudioVoiceCodes.libraryUnavailable, "503 voice_library_unavailable is kept as the server said")
        checkEqual(error.status, 503, "status 503")
    } else { check(false, "voice_library_unavailable comes back as a server error") }
}

private func runVoiceWriteChecks() async {
    let api = jobAPI()
    let upload = URL(string: "https://r2.example/uploads/u/1.wav")!
    let source = SkyStudioVoiceReferenceSource(fileName: "talk.m4a", startSeconds: 72, endSeconds: 252, autoSelected: true)
    guard let asked = try? SkyStudioVoiceCreation(name: "  我的声音 ", language: "zh", referenceURL: upload, source: source,
                                                     consent: .thisRecording(statementVersion: "voice-consent-v1"), idempotencyKey: "voice-key-1"),
          let standing = try? SkyStudioVoiceCreation(name: "Sky", language: "zh", referenceURL: upload, consent: .standingGrant, idempotencyKey: "voice-key-2") else {
        check(false, "valid creations build"); return
    }
    SkyStudioStub.reset { _ in .http(201, voiceAnswer()) }
    checkEqual(try? await api.createVoice(asked, key: jobKey).id, sampleVoiceID, "a new voice comes back")
    let seen = SkyStudioStub.log.first
    checkEqual(seen?.method, "POST", "creating is a POST")
    checkEqual(seen?.url, "http://127.0.0.1:8123/api/skycut/v1/voices", "the create address")
    let body = seen?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(body, ["name": "我的声音", "language": "zh", "reference_url": "https://r2.example/uploads/u/1.wav", "idempotency_key": "voice-key-1",
                      "consent": true, "consent_statement_version": "voice-consent-v1",
                      "source": ["file_name": "talk.m4a", "start_seconds": 72, "end_seconds": 252, "auto_selected": true]],
               "the whole create body (source fields named as Sky Studio reads them)")
    checkEqual(standing.body["consent"], "standing_grant", "full access cites the standing grant")
    check(standing.body["consent_statement_version"] == nil && standing.body["source"] == nil, "no version or source when there is none")
    checkEqual(SkyStudioVoiceConsent.thisRecording(statementVersion: nil).fields, ["consent": true], "consent: true alone means the current version")
    SkyStudioStub.reset { _ in .http(201, voiceAnswer(["id": .string(sampleVoiceID), "name": "Sky", "languages": [["language": "en", "minimax": false]]])) }
    if case .badAnswer? = await expectFailure("a created voice without that language", { _ = try await api.createVoice(asked, key: jobKey) }) {} else {
        check(false, "a created voice must have the recording's language")
    }
    SkyStudioStub.reset { _ in .http(409, #"{"error":{"code":"voice_limit","message":"You can keep up to 50 voices.","limit":50}}"#) }
    if case .server(let error)? = await expectFailure("voice limit", { _ = try await api.createVoice(asked, key: jobKey) }) {
        checkEqual(error.code, SkyStudioVoiceCodes.voiceLimit, "voice_limit")
        checkEqual(error.fields["limit"]?.intValue, 50, "with the limit")
    } else { check(false, "voice_limit comes back as a server error") }

    // 名字按 Unicode code point 数（Sky Studio 的 characterCount = [...text].length）：80 个 emoji 是 80 个字（160 个 UTF-16 单位）。
    for name in ["   ", String(repeating: "声", count: 81), String(repeating: "🎙", count: 81)] {
        check((try? SkyStudioVoiceCreation(name: name, language: "zh", referenceURL: upload, consent: .standingGrant)) == nil,
              "a name that is empty or over 80 code points is refused before sending")
    }
    for name in [String(repeating: "声", count: 80), String(repeating: "🎙", count: 80), String(repeating: "🎙", count: 41)] {
        check((try? SkyStudioVoiceCreation(name: name, language: "zh", referenceURL: upload, consent: .standingGrant)) != nil,
              "\(name.unicodeScalars.count) code points (\(name.utf16.count) UTF-16 units) is fine, as on the server")
    }
    for language in ["ZH", "zh-Hans", "", "chinese"] {
        check((try? SkyStudioVoiceCreation(name: "Sky", language: language, referenceURL: upload, consent: .standingGrant)) == nil, "\(language) is not an ISO 639-1 code")
    }

    guard let english = try? SkyStudioVoiceReference(language: "en", referenceURL: upload, consent: .thisRecording(statementVersion: nil)) else {
        check(false, "a reference builds"); return
    }
    SkyStudioStub.reset { _ in .http(200, voiceAnswer()) }
    checkEqual(try? await api.addVoiceReference(english, to: sampleVoiceID, key: jobKey).language("en")?.seconds, 174.27, "the voice now has English")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/voices/\(sampleVoiceID)/references", "the reference address")
    checkEqual(SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) },
               ["language": "en", "reference_url": "https://r2.example/uploads/u/1.wav", "consent": true], "the reference body")

    SkyStudioStub.reset { _ in .http(200, voiceAnswer(["id": .string(sampleVoiceID), "name": "Sky 2", "source": "recording"])) }
    checkEqual(try? await api.renameVoice(sampleVoiceID, to: " Sky 2 ", key: jobKey).name, "Sky 2", "renamed")
    checkEqual(SkyStudioStub.log.first?.method, "PATCH", "renaming is a PATCH")
    checkEqual(SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }, ["name": "Sky 2"], "only the name goes")

    SkyStudioStub.reset { _ in .http(200, #"{"deleted": true}"#) }
    do { try await api.deleteVoice(sampleVoiceID, key: jobKey); check(true, "deleted") } catch { check(false, "deleting reads {deleted: true}: \(error)") }
    checkEqual(SkyStudioStub.log.first?.method, "DELETE", "deleting is a DELETE")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/voices/\(sampleVoiceID)", "the delete address")
    SkyStudioStub.reset { _ in .http(200, #"{"deleted": false}"#) }
    if case .badAnswer? = await expectFailure("not deleted", { try await api.deleteVoice(sampleVoiceID, key: jobKey) }) {} else {
        check(false, "a delete that does not say deleted is not an answer")
    }
    SkyStudioStub.reset { _ in .http(503, #"{"error":{"code":"storage_unavailable","message":"Try deleting again."}}"#) }
    if case .server(let error)? = await expectFailure("storage down", { try await api.deleteVoice(sampleVoiceID, key: jobKey) }) {
        checkEqual(error.status, 503, "storage trouble is a 503 the caller can retry")
    } else { check(false, "a 503 delete is a server error") }
}

private func runConsentGrantChecks() async {
    let api = jobAPI()
    let active = #"{"grant": {"statement_version": "voice-standing-consent-v1", "granted_at": "2026-11-20T10:00:00Z", "active": true}, "current_statement_version": "voice-standing-consent-v1"}"#
    SkyStudioStub.reset { _ in .http(200, active) }
    let state = try? await api.voiceConsentGrant(key: jobKey)
    checkEqual(state?.hasActiveGrant, true, "an active standing grant")
    checkEqual(state?.grant?.statementVersion, "voice-standing-consent-v1", "its version")
    checkEqual(SkyStudioStub.log.first?.url, "http://127.0.0.1:8123/api/skycut/v1/voices/consent-grant", "the consent-grant address")
    let outdated = #"{"grant": {"statement_version": "voice-standing-consent-v1", "granted_at": "2026-11-20T10:00:00Z", "active": false, "inactive_reason": "outdated"}, "current_statement_version": "voice-standing-consent-v2"}"#
    SkyStudioStub.reset { _ in .http(200, outdated) }
    let old = try? await api.voiceConsentGrant(key: jobKey)
    checkEqual(old?.hasActiveGrant, false, "an outdated grant is not active")
    checkEqual(old?.grant?.inactiveReason, "outdated", "and says why")
    checkEqual(old?.currentStatementVersion, "voice-standing-consent-v2", "the current version comes along")
    SkyStudioStub.reset { _ in .http(200, #"{"grant": null, "current_statement_version": "voice-standing-consent-v1"}"#) }
    let none = try? await api.voiceConsentGrant(key: jobKey)
    check(none != nil && none?.grant == nil && none?.hasActiveGrant == false, "never granted or revoked: a state without a grant")
    SkyStudioStub.reset { _ in .http(200, #"{"grant": {"granted_at": "2026-11-20T10:00:00Z"}}"#) }
    if case .badAnswer? = await expectFailure("a grant without a version", { _ = try await api.voiceConsentGrant(key: jobKey) }) {} else {
        check(false, "a grant without version / active is not an answer")
    }

    SkyStudioStub.reset { _ in .http(200, active) }
    checkEqual(try? await api.recordVoiceConsentGrant(statementVersion: "voice-standing-consent-v1", key: jobKey).hasActiveGrant, true, "recorded")
    checkEqual(SkyStudioStub.log.first?.method, "POST", "recording is a POST")
    checkEqual(SkyStudioStub.log.first?.body.flatMap { try? JSONValue.decode($0) }, ["statement_version": "voice-standing-consent-v1"], "with the version")
    SkyStudioStub.reset { _ in .http(200, outdated) }
    if case .badAnswer? = await expectFailure("recorded but not active", {
        _ = try await api.recordVoiceConsentGrant(statementVersion: "voice-standing-consent-v1", key: jobKey)
    }) {} else { check(false, "recording a grant that is not active is not an answer") }

    SkyStudioStub.reset { _ in .http(200, #"{"grant": null, "current_statement_version": "voice-standing-consent-v1"}"#) }
    do { try await api.revokeVoiceConsentGrant(key: jobKey); check(true, "revoked") } catch { check(false, "revoking reads: \(error)") }
    checkEqual(SkyStudioStub.log.first?.method, "DELETE", "revoking is a DELETE")
    SkyStudioStub.reset { _ in .http(200, active) }
    if case .badAnswer? = await expectFailure("revoked but still active", { try await api.revokeVoiceConsentGrant(key: jobKey) }) {} else {
        check(false, "a revoke that leaves an active grant is not an answer")
    }
}
