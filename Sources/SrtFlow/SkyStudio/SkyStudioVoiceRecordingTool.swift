import Foundation
import SrtFlowMCPKit

// MARK: - manage_voices create / add_reference：用一段录音建声音、给声音加一种语言的录音
//
// 管什么（SkyCut 声音方案 4.5、4.6、第六节）：
// 1. 核对参数（file 必给，create 要 name、add_reference 要 voice；`language` 可选：给了就核对写法、照它的）；
// 2. 点名文件夹以外的文件先过 AIWorkspace.confirmReading（请求批准模式问、记住文件夹；全部权限不问）；
// 3. 本机做参考录音（VoiceReferenceSample：44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟、超过自动挑一段），免费、不碰服务器；
//    没给 `language` 就在这段参考录音上识别（SkyStudioVoiceRecordingLanguage：和新建声音对话框同一份；识别不出来叫 AI 带上
//    language 再调，什么都不问、不传），识别成了什么写进问句和结果；
// 4. **授权**：经 SkyStudioJobGate.voiceConsent 问（这一刀两种模式都问，长期授权是声音 PR 7），令牌绑录音的完整身份
//    （SkyStudioVoiceApproval.Recording：文件、做好的那段的内容哈希、用的那一段、语言、名字 / 声音、授权那句的版本）；
// 5. 点过头才传（`/uploads` 用途 `voice_reference`）、建（`POST /voices`）/ 加（`POST /voices/{id}/references`），带 `consent: true` +
//    那句的版本；建声音的 idempotency_key 从同一个身份算（同一件事重发回同一个声音）。身份和「传、建 / 加」这一步在
//    SkyStudioVoiceRecordingSubmission，设置里的新建声音对话框走同一份。
// AI 这一路的 `consent: true`（SkyStudioVoiceConsent.thisRecording）只在这里、只在点过头之后造（checks/sky-studio-wiring.sh 钉着；
// 另一处是对话框里用户自己勾了那一句之后，NewVoiceModel）。
// 不管什么：列出 / 改名 / 删除（SkyStudioVoiceLibraryTool）、设计（SkyStudioVoiceDesignTool）、配旁白。

@MainActor
enum SkyStudioVoiceRecordingTool {
    static func run(_ action: String, _ args: AIToolArguments, _ project: VideoEditProject, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let creating = action == "create"
        let file = AIWorkspace.shared.resolve(try args.requiredString("file"))
        guard FileManager.default.fileExists(atPath: file.path) else { throw AIToolError("There is no file at \(file.path).") }
        // AI 给了语言就照它的；没给的等参考录音做好再识别（下面）。
        let givenLanguage = try SkyStudioVoiceRecordingLanguage.given(args)
        let target: SkyStudioVoiceRecordingSubmission.Target
        if creating {
            target = .create(name: try checked { try SkyStudioVoiceNaming.checked(try args.requiredString("name")) })
        } else {
            let voice = try args.requiredString("voice").trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkyStudioVoice.isVoiceID(voice) else { throw AIToolError("voice must be a voice_… id from list_voices.") }
            target = .addReference(voice: voice)
        }
        let start = max(0, try args.double("start") ?? 0)
        let end = try args.double("end")
        if let end, end <= start { throw AIToolError("end must be after start.") }
        if let question = try AIWorkspace.shared.confirmReading([file], verb: "send to Sky Studio", args: args, project: project) { return question }

        let key = try await services.key()
        let statement = try await consentStatement(key: key, services: services)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut-voice-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = try await VoiceReferenceSample.prepare(from: file, start: start, end: end, folder: folder)
        let language = try await SkyStudioVoiceRecordingLanguage.resolve(given: givenLanguage, sample: sample, detect: services.detectLanguage)
        let doing: String
        switch target {
        case .create(let name): doing = "create the voice \"\(name)\""
        case .addReference(let voice): doing = "add a \(language.name) recording to \(voice)"
        }
        let submission = try checked {
            try SkyStudioVoiceRecordingSubmission(file: file, sample: sample, language: language.code, target: target, statement: statement)
        }
        let consentAction = submission.consentAction(account: SkyStudioCharacterAccess.stamp(key))
        let summary = sample.summary(name: file.lastPathComponent)
        // 识别出来的语言接在「用了哪一段」后面：用户点头之前看得到。
        let asked = [summary, SkyStudioVoiceRecordingLanguage.questionNote(language)].compactMap { $0 }.joined(separator: " ")
        let question = SkyStudioVoiceApproval.consentQuestion(statement: statement, doing: doing, sample: asked)
        if let ask = SkyStudioJobGate.voiceConsent(action: consentAction, question: question, token: try args.string("confirm_token")) {
            return SkyStudioVoiceRecordingLanguage.adding(language, to: ask)
        }
        // 点过头了：这段录音的授权就是这一次的（consent: true + 问的那句的版本）。
        let consent = SkyStudioVoiceConsent.thisRecording(statementVersion: statement.version)
        do {
            let voice = try await submission.send(consent: consent, key: key, api: services.api)
            return SkyStudioVoiceRecordingLanguage.adding(language, note: SkyStudioVoiceRecordingLanguage.resultNote(language), to: .ok([
                "status": .string(creating ? "created" : "reference_added"), "voice": voice.json, "sample": .string(summary),
                "next_step": .string("Use voice=\(voice.id) with add_voiceover. The first narration in a language may ask once to build "
                    + "the voice's MiniMax version (a one-time fee).")
            ]))
        } catch is CancellationError { throw CancellationError() }
        catch { throw AIToolError(SkyStudioVoiceLibraryErrors.message(error)) }
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
