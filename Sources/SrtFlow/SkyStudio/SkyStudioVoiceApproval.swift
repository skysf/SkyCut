import CryptoKit
import Foundation
import SrtFlowMCPKit

// MARK: - 声音库要问用户的三件事：令牌绑什么、问句怎么写（纯值）
//
// 管什么（SkyCut 声音方案 4.5）：用录音建声音 / 给声音加一种语言的录音（授权）、一次性费用（建 MiniMax 版、设计声音）、删声音。
// 令牌绑**完整的身份**，换了任何一样另发一张（AIConfirmations：三十分钟、一次有效、同一件事等答复时回同一张）：
// - 授权：录音的文件身份（路径 + 大小 + 修改时间）、做好的那段参考录音的内容哈希、用的那一段、语言、建成什么名字 / 加到哪个声音、授权那句的版本；
// - 建 MiniMax 版：kind、模型、声音、语言、精确积分；
// - 设计：描述、名字、试读句、精确积分；
// - 删除：声音 id。
// 每一件的 action 都以 `skystudio:` 开头、带账户戳（SkyStudioCharacterAccess.stamp）：换账户时 SkyStudioCharacterAccess.invalidate
// 一起作废，别的账户点过的头不能拿来用。
// 不管什么：什么时候问（SkyStudioJobGate 的声音那几样）、问到了怎么做（SkyStudioVoiceRecordingTool / SkyStudioVoiceDesignTool /
// SkyStudioVoiceOneTimeStep / SkyStudioVoiceLibraryTool）。

enum SkyStudioVoiceApproval {
    /// 一段录音的身份（授权的令牌绑它）。
    struct Recording: Equatable, Sendable {
        var path: String
        var bytes: Int
        /// 修改时间（秒，1970 起）。
        var modified: Double
        /// 做好的参考录音（要上传的那个 WAV）的 SHA-256：同一个文件换了一段、内容变了都不一样。
        var sampleSHA256: String
        var start: Double
        var end: Double
        var language: String
        /// `create:<名字>` 或 `add_reference:<voice_…>`。
        var target: String
        /// 问的那句授权的版本（`/models` 的 `voice_consent.per_recording.version`），交的时候原样带上。
        var statementVersion: String
    }

    static func consentAction(_ recording: Recording, account: String) -> String {
        "skystudio:voice_consent:" + account + ":" + [
            recording.path, String(recording.bytes), number(recording.modified), recording.sampleSHA256,
            number(recording.start), number(recording.end), recording.language, recording.target, recording.statementVersion
        ].joined(separator: "|")
    }

    /// 授权的问句：服务器那句英文原文和版本、要做什么、用的是哪一段（AI 照会话的语言转述给用户）。
    static func consentQuestion(statement: SkyStudioVoiceConsentStatement, doing: String, sample: String) -> String {
        "Before SkyCut sends this recording to Sky Studio to \(doing), the user must confirm Sky Studio's consent statement "
            + "(\(statement.version)): \"\(statement.statement)\" Show it to the user in their language and ask whether it is true for "
            + "this recording: it must be their own voice, or the speaker agreed. \(sample) It is free."
    }

    static func oneTimeAction(_ item: SkyStudioVoiceOneTime, account: String) -> String {
        "skystudio:voice_one_time:" + account + ":" + [
            item.kind, item.model ?? "", item.voice ?? "", item.language ?? "", item.credits.map(number) ?? ""
        ].joined(separator: "|")
    }

    /// 建 MiniMax 版的问句：多少积分（一次性、这种语言一次）、建了以后用什么读、不建的话这一单用哪个不花钱的读。
    static func oneTimeQuestion(_ item: SkyStudioVoiceOneTime, credits: Double, noFeeModel: String?) -> String {
        let language = item.language.map(SkyStudioVoicePick.languageName) ?? "this language"
        var text = "Sky Studio reads this voice in \(language) best after building its MiniMax version: a one-time fee of "
            + "\(SkyStudioCredits.text(credits)) credits for \(language), then every later narration in \(language) uses it."
        if let why = item.why, !why.isEmpty { text += " (\(why))" }
        if let noFeeModel { text += " Without it, this narration reads now with \(noFeeModel) at no extra fee." }
        return text + " Build it?"
    }

    /// 中途的备用要先建 MiniMax 版（任务结束码 fallback_needs_one_time）时的问句：建了用备用接着做，不建就用原来的模型重试没做成的几批。
    static func fallbackQuestion(_ item: SkyStudioVoiceOneTime, credits: Double) -> String {
        let language = item.language.map(SkyStudioVoicePick.languageName) ?? "this language"
        return "One part of this narration failed on Sky Studio, and its fallback first needs the voice's MiniMax version for \(language): "
            + "a one-time fee of \(SkyStudioCredits.text(credits)) credits, after which the missing parts can be read with the fallback. "
            + "Without it, the missing parts can be retried with the same model at no extra fee. Build it?"
    }

    static func designAction(description: String, name: String, sampleText: String?, credits: Double, account: String) -> String {
        "skystudio:voice_design:" + account + ":" + [
            sha256(Data(description.utf8)), name, sampleText.map { sha256(Data($0.utf8)) } ?? "", number(credits)
        ].joined(separator: "|")
    }

    static func designQuestion(name: String, credits: Double, expected: Double?) -> String {
        let price = expected.map { "about \(SkyStudioCredits.text($0)) Sky Studio credits (at most \(SkyStudioCredits.text(credits)))" }
            ?? "\(SkyStudioCredits.text(credits)) Sky Studio credits"
        return "Design a new voice called \"\(name)\" from this description: a one-time fee of \(price). A failed design is refunded. Design it?"
    }

    static func deletionAction(voice: String, account: String) -> String {
        "skystudio:voice_delete:" + account + ":" + voice
    }

    static func deletionQuestion(name: String) -> String {
        "Delete the voice \"\(name)\" from the user's Sky Studio voice library? Its recordings go with it; it cannot be restored."
    }

    /// 小写十六进制的 SHA-256。
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 同一个请求在服务器那边认成同一个（`POST /voices` 的 `idempotency_key`）：从令牌绑的那个身份算，同一件事重发回同一个声音。
    static func idempotencyKey(for action: String) -> String {
        String(sha256(Data(action.utf8)).prefix(32))
    }

    /// 数字写进身份时用固定的写法（同一个数两次写出来一样）。
    private static func number(_ value: Double) -> String { String(format: "%.6f", value) }
}
