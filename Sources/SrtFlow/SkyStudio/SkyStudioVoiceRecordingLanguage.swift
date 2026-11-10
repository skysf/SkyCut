import Foundation
import SrtFlowMCPKit

// MARK: - manage_voices 的录音说的是哪种语言：AI 给了就照它的，没给就本机识别
//
// 管什么（SkyCut 声音方案 4.6：create / add_reference 的 `language` 可选、自动识别）：
// - AI 给了 `language`：核对写法、照它的，**不识别、不拿识别的结果盖掉**（它多半是照用户说的填的；识别只在这台 Mac 装了的语言里
//   裁决，认错的正是没装的那一种）。
// - 没给（或给的是空的）：在做好的参考录音上识别，和设置里的新建声音对话框**同一份**（SkyStudioVoiceServices.detectLanguage 的默认值
//   就是 VoiceSampleLanguage.detect → SpokenLanguageProbe：macOS 26、只在已装的转写语言里裁决、不为它下载模型、探针是参考录音的
//   前 20 秒）。这里不许另写一份候选 / 裁决（checks/sky-studio-wiring.sh 钉着）。
// - 识别不出来（把握不够、一个模型都没装、macOS 15）：一样都不问、不传，回给 AI 一句它能照做的 —— 带上 language 再调
//   （同 AIHarvestFailure：不叫它去点界面，它没有界面），结构化的 `reason: language_undetected`。**不许猜一个**：语言记错了，
//   服务器选模型、选参考就跟着错。
// - 识别出来的写进授权的问句和结果（`language`、`language_detected: true`）：用户点头之前看得到识别成了什么，认错了带上 language 再调。
// 不管什么：怎么识别（VoiceSampleLanguage / SpokenLanguageProbe）、参考录音怎么做（VoiceReferenceSample）、问授权和交
// （SkyStudioVoiceRecordingTool）。

@MainActor
enum SkyStudioVoiceRecordingLanguage {
    /// 定下来的语言，和它是哪来的。
    struct Resolved: Equatable, Sendable {
        /// ISO 639-1（`zh`、`en`…）。
        let code: String
        /// AI 没给、这台 Mac 识别出来的。
        let detected: Bool

        var name: String { SkyStudioVoicePick.languageName(code) }
    }

    /// 识别不出来时结构化报错里的 `reason`。
    static let undetectedReason = "language_undetected"

    /// 识别不出来时回给 AI 的话：它能照做的是带上 language 再调（不知道就问用户），不是去点界面。
    static let undetectedMessage = "Couldn't tell which language this recording is in: SkyCut only checks the speech languages installed "
        + "on this Mac (macOS 26 or later), and the recording may be in another one or too unclear. Call manage_voices again with "
        + "language (the ISO 639-1 code of what is said, for example en or zh); ask the user if you are not sure. Nothing was sent."

    /// AI 给的 `language`（核对过写法、小写）；没给、给的是空的都是 nil。
    static func given(_ args: AIToolArguments) throws -> String? {
        guard let raw = try args.string("language")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        do { return try SkyStudioVoiceNaming.checkedLanguage(raw.lowercased()) }
        catch let problem as SkyStudioVoiceRequestProblem { throw AIToolError(problem.message) }
    }

    /// 定下录音的语言：`given` 不是 nil 就照它的（不识别）；否则在做好的参考录音上识别，识别不出来抛「带上 language 再调」。
    static func resolve(given: String?, sample: VoiceReferenceSample.Sample,
                        detect: @MainActor (URL, Double) async -> String?) async throws -> Resolved {
        if let given { return Resolved(code: given, detected: false) }
        let found = await detect(sample.url, sample.seconds)
        // 识别的那一头把取消也收成 nil：别把「停了」说成「识别不出来」。
        try Task.checkCancellation()
        guard let found else { throw AIToolError(undetectedMessage, details: ["reason": .string(undetectedReason)]) }
        return Resolved(code: found, detected: true)
    }

    /// 加一种语言：这个声音已经有这种语言了（一种语言一段，Sky Studio 会拒）就当场说，什么都不问、不传。识别出来的那种多说一句
    /// 它是识别出来的、认错了怎么办。
    static func refuseExisting(_ language: Resolved, in voice: SkyStudioVoice) throws {
        guard voice.languages.contains(where: { $0.language == language.code }) else { return }
        var message = SkyStudioVoiceLibraryErrors.referenceExists(languageName: language.name, voice: voice.name)
        if language.detected {
            message += " SkyCut detected \(language.name) (\(language.code)) in this recording; if it is in another language, call again "
                + "with language."
        }
        throw AIToolError(message + " Nothing was sent.")
    }

    /// 问之前：接在授权问句里「用了哪一段」后面的那一句（AI 给的语言不写）。用户点头之前看得到识别成了什么、认错了怎么改。
    static func questionNote(_ language: Resolved) -> String? {
        guard language.detected else { return nil }
        return "SkyCut detected the recording's language as \(language.name) (\(language.code)); tell the user, and if that is wrong "
            + "call again with language."
    }

    /// 做成之后：结果里叫 AI 转告的那一句（AI 给的语言不写）。这一版换不了一段录音的语言，认错了只能删了重建。
    static func resultNote(_ language: Resolved) -> String? {
        guard language.detected else { return nil }
        return "SkyCut detected the recording's language as \(language.name) (\(language.code)); tell the user. A wrong language can "
            + "only be fixed by deleting the voice and creating it again with language."
    }

    /// 把语言并进结果（问句的那一个、做成了的那一个）：`language`；识别出来的加 `language_detected`，`note` 写进 `language_note`。
    static func adding(_ language: Resolved, note: String? = nil, to result: AIToolResult) -> AIToolResult {
        guard case .object(var value) = result.payload else { return result }
        value["language"] = .string(language.code)
        if language.detected { value["language_detected"] = true }
        if let note { value["language_note"] = .string(note) }
        var copy = result
        copy.payload = .object(value)
        return copy
    }
}
