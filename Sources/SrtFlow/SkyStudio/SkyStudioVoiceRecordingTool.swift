import Foundation
import SrtFlowMCPKit

// MARK: - manage_voices create / add_reference：用一段录音建声音、给声音加一种语言的录音
//
// 管什么（SkyCut 声音方案 4.5、4.6、第六节）：
// 1. 核对参数（file 必给，create 要 name、add_reference 要 voice；`language` 可选：给了就核对写法、照它的）；
// 2. 加一种语言（add_reference）先读那个声音（`GET /voices/{id}`）：AI 给的语言它已经有就当场说（一种语言一段，Sky Studio 会拒），
//    什么都不问、不读文件、不传；问句里写声音的名字，不写 id（2026-11-10 案例，T 的免费冒烟）；
//    点名文件夹以外的文件再过 AIWorkspace.confirmReading（请求批准模式问、记住文件夹；全部权限不问）；
// 3. 本机做参考录音（VoiceReferenceSample：44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟、超过自动挑一段），免费、不碰服务器；
//    没给 `language` 就在这段参考录音上识别（SkyStudioVoiceRecordingLanguage：和新建声音对话框同一份；识别不出来叫 AI 带上
//    language 再调，什么都不问、不传），识别成了什么写进问句和结果；识别出来的语言那个声音已经有，同样在问之前就说；
// 4. **授权**：经 SkyStudioJobGate.voiceConsent，照 SkyStudioVoiceStanding.voiceAsk：请求批准模式问；全部权限下有有效的长期授权
//    不问（声音 PR 7），没有就问一次、问句带打开全部权限时那段说明、点过头补记。令牌绑录音的完整身份
//    （SkyStudioVoiceApproval.Recording：文件、做好的那段的内容哈希、用的那一段、语言、名字 / 声音、授权那句的版本）；
// 5. 才传（`/uploads` 用途 `voice_reference`）、建（`POST /voices`）/ 加（`POST /voices/{id}/references`）：问过的带 `consent: true` +
//    那句的版本，全部权限 + 长期授权带 `consent: "standing_grant"`（Sky Studio 拒了 —— 刚被撤或文案升版 —— 就照 4.5 问一次）；
//    建声音的 idempotency_key 从同一个身份算（同一件事重发回同一个声音）。身份和「传、建 / 加」这一步在
//    SkyStudioVoiceRecordingSubmission，设置里的新建声音对话框走同一份。全部权限下没问的，结果和提示条都说一句做了什么。
// AI 这一路的 `consent: true`（SkyStudioVoiceConsent.thisRecording）和 `consent: "standing_grant"`（.standingGrant）只在这里、只在
// SkyStudioJobGate.voiceConsent 放行之后造（checks/sky-studio-wiring/voice-library.sh 钉着；另一处 `consent: true` 是对话框里用户自己
// 勾了那一句之后，NewVoiceModel）。
// 不管什么：列出 / 改名 / 删除（SkyStudioVoiceLibraryTool）、设计（SkyStudioVoiceDesignTool）、配旁白。

@MainActor
enum SkyStudioVoiceRecordingTool {
    static func run(_ action: String, _ args: AIToolArguments, _ project: VideoEditProject, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let creating = action == "create"
        let file = AIWorkspace.shared.resolve(try args.requiredString("file"))
        guard FileManager.default.fileExists(atPath: file.path) else { throw AIToolError("There is no file at \(file.path).") }
        // AI 给了语言就照它的；没给的等参考录音做好再识别（下面）。
        let givenLanguage = try SkyStudioVoiceRecordingLanguage.given(args)
        let start = max(0, try args.double("start") ?? 0)
        let end = try args.double("end")
        if let end, end <= start { throw AIToolError("end must be after start.") }
        let key = try await services.key()
        let target: SkyStudioVoiceRecordingSubmission.Target
        // 加一种语言时读到的那个声音（问句写它的名字、查它有没有这种语言）。
        var existing: SkyStudioVoice?
        if creating {
            target = .create(name: try checked { try SkyStudioVoiceNaming.checked(try args.requiredString("name")) })
        } else {
            let id = try args.requiredString("voice").trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkyStudioVoice.isVoiceID(id) else { throw AIToolError("voice must be a voice_… id from list_voices.") }
            // 先读这个声音：AI 给的语言它已经有就当场说，不问、不读文件、不传；问句写它的名字（令牌照旧绑 id）。
            let voice = try await existingVoice(id, key: key, services: services)
            if let givenLanguage { try SkyStudioVoiceRecordingLanguage.refuseExisting(.init(code: givenLanguage, detected: false), in: voice) }
            target = .addReference(voice: id)
            existing = voice
        }
        if let question = try AIWorkspace.shared.confirmReading([file], verb: "send to Sky Studio", args: args, project: project) { return question }

        let statement = try await consentStatement(key: key, services: services)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut-voice-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = try await VoiceReferenceSample.prepare(from: file, start: start, end: end, folder: folder)
        let language = try await SkyStudioVoiceRecordingLanguage.resolve(given: givenLanguage, sample: sample, detect: services.detectLanguage)
        // 识别出来的语言这个声音已经有：同一句，问之前就说（AI 给的那种上面查过了）。
        if language.detected, let existing { try SkyStudioVoiceRecordingLanguage.refuseExisting(language, in: existing) }
        let doing: String
        switch target {
        case .create(let name): doing = "create the voice \"\(name)\""
        case .addReference(let id): doing = "add a \(language.name) recording to the voice \"\(existing?.name ?? id)\""
        }
        let submission = try checked {
            try SkyStudioVoiceRecordingSubmission(file: file, sample: sample, language: language.code, target: target, statement: statement)
        }
        let consentAction = submission.consentAction(account: SkyStudioCharacterAccess.stamp(key))
        let summary = sample.summary(name: file.lastPathComponent)
        // 识别出来的语言接在「用了哪一段」后面：用户点头之前看得到。
        let sampleNote = [summary, SkyStudioVoiceRecordingLanguage.questionNote(language)].compactMap { $0 }.joined(separator: " ")
        let question = SkyStudioVoiceApproval.consentQuestion(statement: statement, doing: doing, sample: sampleNote)
        let standing = SkyStudioVoiceStanding.shared
        let ask = await standing.voiceAsk(key: key, api: services.api)
        if let asked = SkyStudioJobGate.voiceConsent(action: consentAction, question: question, token: try args.string("confirm_token"), ask: ask) {
            return SkyStudioVoiceRecordingLanguage.adding(language, to: asked)
        }
        await standing.recordAfterApproval(ask, key: key, api: services.api)
        // 全部权限 + 长期授权：引用它；别的是这一次点过头（consent: true + 问的那句的版本）。
        let consent: SkyStudioVoiceConsent = ask == .standing ? .standingGrant : .thisRecording(statementVersion: statement.version)
        do {
            let voice = try await submission.send(consent: consent, key: key, api: services.api)
            var result: [String: JSONValue] = [
                "status": .string(creating ? "created" : "reference_added"), "voice": voice.json, "sample": .string(summary),
                "next_step": .string("Use voice=\(voice.id) with add_voiceover. The first narration in a language may need the voice's "
                    + "MiniMax version (a one-time fee).")
            ]
            if ask == .standing {
                result["consent"] = "standing_grant"
                result["full_access"] = .string("Full access: SkyCut used the user's standing voice consent and did not ask. Tell the user what "
                    + "was created and which part of the recording was used (sample).")
                standing.notify(creating
                    ? String(format: L10n("Full access: SkyCut created the voice “%@” from a recording."), voice.name)
                    : String(format: L10n("Full access: SkyCut added a recording to the voice “%@”."), voice.name), project: project)
            }
            return SkyStudioVoiceRecordingLanguage.adding(language, note: SkyStudioVoiceRecordingLanguage.resultNote(language), to: .ok(.object(result)))
        } catch is CancellationError { throw CancellationError() }
        catch where ask == .standing && SkyStudioVoiceLibraryErrors.refusedStanding(error) {
            // 长期授权刚被撤（别的 Mac 关了全部权限）或文案升了版本：照方案 4.5 问一次，问句带那段说明，点过头补记。
            let once = await standing.missing(key: key, api: services.api)
            if let asked = SkyStudioJobGate.voiceConsent(action: consentAction, question: question, token: nil, ask: once) {
                return SkyStudioVoiceRecordingLanguage.adding(language, to: asked)
            }
            throw AIToolError(SkyStudioVoiceLibraryErrors.message(error))
        }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
    }

    /// 加一种语言之前读那个声音（问句写它的名字、查它有没有这种语言）。读不到就照声音库的错误说，什么都没传。
    private static func existingVoice(_ id: String, key: String, services: SkyStudioVoiceServices) async throws -> SkyStudioVoice {
        do { return try await services.api.voice(id, key: key) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
    }

    /// `/models` 的 `voice_consent.per_recording`：问句照它的英文原文，交的时候带它的版本。读不到就不问、不传。
    private static func consentStatement(key: String, services: SkyStudioVoiceServices) async throws -> SkyStudioVoiceConsentStatement {
        let catalog: SkyStudioCatalog
        do { catalog = try await SkyStudioCatalogCache.shared.catalog(key: key, api: services.api) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.uncharged(error)) }
        guard let statement = catalog.voices?.perRecordingConsent else {
            throw AIToolError("Sky Studio does not provide its voice consent statement yet, so SkyCut cannot ask for it. Nothing was sent.")
        }
        return statement
    }

    private static func checked<T>(_ make: () throws -> T) throws -> T {
        do { return try make() }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message) }
    }
}
