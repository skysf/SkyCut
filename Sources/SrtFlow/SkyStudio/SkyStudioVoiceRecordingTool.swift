import Foundation
import SrtFlowMCPKit

// MARK: - manage_voices create / add_reference：用一段录音建声音、给声音加一种语言的录音
//
// 管什么（SkyCut 声音方案 4.5、4.6、第六节）：
// 1. 核对参数（file、language 必给，create 要 name、add_reference 要 voice）；
// 2. 点名文件夹以外的文件先过 AIWorkspace.confirmReading（请求批准模式问、记住文件夹；全部权限不问）；
// 3. 本机做参考录音（VoiceReferenceSample：44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟、超过自动挑一段），免费、不碰服务器；
// 4. **授权**：经 SkyStudioJobGate.voiceConsent 问（这一刀两种模式都问，长期授权是声音 PR 7），令牌绑录音的完整身份
//    （SkyStudioVoiceApproval.Recording：文件、做好的那段的内容哈希、用的那一段、语言、名字 / 声音、授权那句的版本）；
// 5. 点过头才传（`/uploads` 用途 `voice_reference`）、建（`POST /voices`）/ 加（`POST /voices/{id}/references`），带 `consent: true` +
//    那句的版本；建声音的 idempotency_key 从同一个身份算（同一件事重发回同一个声音）。身份和「传、建 / 加」这一步在
//    SkyStudioVoiceRecordingSubmission，设置里的新建声音对话框走同一份。
// AI 这一路的 `consent: true`（SkyStudioVoiceConsent.thisRecording）只在这里、只在点过头之后造（checks/sky-studio-wiring.sh 钉着；
// 另一处是对话框里用户自己勾了那一句之后，NewVoiceModel）。
// 录音的语言这一路要 AI 给（界面上的对话框用本机检测预选、可改：VoiceSampleLanguage）。
// 不管什么：列出 / 改名 / 删除（SkyStudioVoiceLibraryTool）、设计（SkyStudioVoiceDesignTool）、配旁白。

@MainActor
enum SkyStudioVoiceRecordingTool {
    static func run(_ action: String, _ args: AIToolArguments, _ project: VideoEditProject, services: SkyStudioVoiceServices) async throws -> AIToolResult {
        let creating = action == "create"
        let file = AIWorkspace.shared.resolve(try args.requiredString("file"))
        guard FileManager.default.fileExists(atPath: file.path) else { throw AIToolError("There is no file at \(file.path).") }
        let language = try checked { try SkyStudioVoiceNaming.checkedLanguage(try args.requiredString("language").lowercased()) }
        let target: SkyStudioVoiceRecordingSubmission.Target
        let doing: String
        if creating {
            let name = try checked { try SkyStudioVoiceNaming.checked(try args.requiredString("name")) }
            target = .create(name: name)
            doing = "create the voice \"\(name)\""
        } else {
            let voice = try args.requiredString("voice").trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkyStudioVoice.isVoiceID(voice) else { throw AIToolError("voice must be a voice_… id from list_voices.") }
            target = .addReference(voice: voice)
            doing = "add a \(SkyStudioVoicePick.languageName(language)) recording to \(voice)"
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
        let submission = try checked {
            try SkyStudioVoiceRecordingSubmission(file: file, sample: sample, language: language, target: target, statement: statement)
        }
        let consentAction = submission.consentAction(account: SkyStudioCharacterAccess.stamp(key))
        let summary = sample.summary(name: file.lastPathComponent)
        let question = SkyStudioVoiceApproval.consentQuestion(statement: statement, doing: doing, sample: summary)
        if let ask = SkyStudioJobGate.voiceConsent(action: consentAction, question: question, token: try args.string("confirm_token")) {
            return ask
        }
        // 点过头了：这段录音的授权就是这一次的（consent: true + 问的那句的版本）。
        let consent = SkyStudioVoiceConsent.thisRecording(statementVersion: statement.version)
        do {
            let voice = try await submission.send(consent: consent, key: key, api: services.api)
            return .ok([
                "status": .string(creating ? "created" : "reference_added"), "voice": voice.json, "sample": .string(summary),
                "next_step": .string("Use voice=\(voice.id) with add_voiceover. The first narration in a language may ask once to build "
                    + "the voice's MiniMax version (a one-time fee).")
            ])
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
