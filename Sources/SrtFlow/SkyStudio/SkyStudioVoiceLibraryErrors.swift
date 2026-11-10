import Foundation
import SrtFlowMCPKit

// MARK: - 声音库的错误怎么跟 AI 说（纯值）
//
// 管什么（SkyCut 声音方案 4.6）：服务器的错误码（SkyStudioVoiceCodes）换成 AI 能照做的话：声音满了（50 个）、这种语言已经有录音、
// 有效人声不够、太长、传得太大、语言不支持、要授权；声音库用不了（503 `voice_library_unavailable`：Sky Studio 的私有声音桶没配）时
// 一律说「暂时用不了、一分没花、稍后再试、预设照常」，**不退本机**（4.3）。认不出来的码照旧用服务器的原话（SkyStudioJobError）。
// 不管什么：什么时候报（各工具）、一次性费用（SkyStudioVoiceOneTimeStep）。

enum SkyStudioVoiceLibraryErrors {
    static let unavailable = "Sky Studio's voice library is not available right now; nothing was charged. Try again later. "
        + "Preset voices (gemini:Name) still work."

    /// 花钱之前就停下时的话：没说「没花钱」的补上一句。
    static func uncharged(_ error: Error) -> String {
        let text = message(error)
        return text.lowercased().contains("charged") || text.lowercased().contains("nothing was") ? text : text + " Nothing was charged."
    }

    /// 删除时存储一时不可用（同一个码，`reason: storage_unavailable`、`retryable`）：声音已经看不见了，再发一次 DELETE 接着删。
    static let storageUnavailable = "storage_unavailable"

    /// 服务器明说声音库用不了（私有声音桶没配）。
    static func isUnavailable(_ error: Error) -> Bool {
        server(error)?.code == SkyStudioVoiceCodes.libraryUnavailable && !isStorageRetry(error)
    }

    /// 删除时存储一时不可用：再发一次 DELETE。
    static func isStorageRetry(_ error: Error) -> Bool {
        guard let server = server(error), server.code == SkyStudioVoiceCodes.libraryUnavailable else { return false }
        return server.fields["reason"]?.stringValue == storageUnavailable
    }

    /// 这个账号的声音库里没有这个 id（或正在删、已经看不见）。
    static func isNotFound(_ error: Error) -> Bool { server(error)?.code == "not_found" }

    /// 这个声音已经有这种语言的参考（一种语言一段）：服务器回 409 `reference_exists`，加之前本机读到的（SkyStudioVoiceRecordingTool）也照这一句说。
    static func referenceExists(languageName: String, voice: String?) -> String {
        "\(voice.map { "The voice \"\($0)\"" } ?? "This voice") already has a recording in \(languageName): one per language. To replace it, "
            + "delete the voice and create it again."
    }

    /// 带 `consent: "standing_grant"` 被拒：长期授权刚被撤（别的 Mac 关了全部权限）或文案升了版本。照方案 4.5 问一次。
    static func refusedStanding(_ error: Error) -> Bool {
        guard let server = server(error), server.code == "invalid_request" else { return false }
        let reason = server.fields["reason"]?.stringValue
        return reason == SkyStudioVoiceCodes.Reason.noStandingGrant || reason == SkyStudioVoiceCodes.Reason.consentOutdated
    }

    /// 给 AI 的一句话。
    static func message(_ error: Error) -> String {
        guard let server = server(error) else {
            if let job = error as? SkyStudioJobError { return job.message }
            if let failure = error as? SkyStudioFailure { return SkyStudioJobError.request(failure).message }
            if let tool = error as? AIToolError { return tool.message }
            if let problem = error as? SkyStudioVoiceRequestProblem { return problem.message + " Nothing was sent." }
            return error.localizedDescription
        }
        let limit = server.fields["limit"]?.doubleValue.map { $0.rounded() == $0 ? String(Int($0)) : String($0) }
        let language = server.fields["language"]?.stringValue.map(SkyStudioVoicePick.languageName) ?? "that language"
        switch server.code {
        case SkyStudioVoiceCodes.libraryUnavailable:
            guard server.fields["reason"]?.stringValue == storageUnavailable else { return unavailable }
            return "Sky Studio's voice storage is not reachable right now. The voice is already gone from the library; call "
                + "manage_voices action=delete again later to finish removing its files."
        case SkyStudioVoiceCodes.voiceLimit:
            return "The user's voice library is full (at most \(limit ?? "50") voices). Delete one with manage_voices action=delete "
                + "first. Nothing was charged."
        case SkyStudioVoiceCodes.referenceExists:
            return referenceExists(languageName: language, voice: nil) + " Nothing was changed."
        case SkyStudioVoiceCodes.minimaxVoiceExists:
            return "This voice already has its MiniMax version for \(language); nothing was charged. Call add_voiceover again."
        case "not_found":
            return "There is no voice with that id in the user's library (it may have been deleted). Use list_voices."
        case "invalid_request":
            return invalidRequest(server, limit: limit, language: language)
        default:
            return SkyStudioJobError.request(.server(server)).message
        }
    }

    private static func invalidRequest(_ server: SkyStudioServerError, limit: String?, language: String) -> String {
        switch server.fields["reason"]?.stringValue {
        case SkyStudioVoiceCodes.Reason.tooLittleSpeech?:
            return "Sky Studio found less than \(limit ?? "10") seconds of clear speech in the recording. Use a part where one person "
                + "talks clearly, without music. Nothing was charged."
        case SkyStudioVoiceCodes.Reason.tooLong?:
            return "The recording is longer than Sky Studio accepts (\(limit ?? "180") seconds). Pick a shorter part with start and end. "
                + "Nothing was charged."
        case SkyStudioVoiceCodes.Reason.uploadTooLarge?:
            return "The recording is too large to upload (at most 35 MB). Pick a shorter part. Nothing was charged."
        case SkyStudioVoiceCodes.Reason.unsupportedLanguage?:
            return "Sky Studio does not support \(language) for this. Nothing was charged."
        case SkyStudioVoiceCodes.Reason.consentRequired?, SkyStudioVoiceCodes.Reason.noStandingGrant?,
             SkyStudioVoiceCodes.Reason.consentOutdated?:
            return "Sky Studio needs the user's consent for this recording again; call manage_voices again and ask the user. "
                + "Nothing was saved."
        default:
            return "Sky Studio refused this: \(server.message) Nothing was charged."
        }
    }

    private static func server(_ error: Error) -> SkyStudioServerError? {
        if case .server(let server)? = error as? SkyStudioFailure { return server }
        if case .request(.server(let server))? = error as? SkyStudioJobError { return server }
        return nil
    }
}
