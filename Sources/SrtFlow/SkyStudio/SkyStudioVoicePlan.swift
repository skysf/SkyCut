import Foundation
import SrtFlowMCPKit

// MARK: - 配音的请求批次（纯值，模型与上限只认 /models）
// 管什么：普通旁白一句一单，克隆在字符上限内合并多句；语言换成接口的写法，读动态 cap，构造 /quote 和 /jobs 共用的请求。
// 不管什么：Key、价、额度、上传、执行、音频切分、入轨。

struct SkyStudioVoicePlan: Sendable {
    struct Batch: Sendable {
        let speech: SkyStudioVoiceBatch
        var request: SkyStudioJobRequest
    }

    let model: SkyStudioModel
    let language: String
    let batches: [Batch]
    var clones: Bool { model.kind == "voice_clone" }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func make(lines: [String], model: SkyStudioModel, voice: String, language: String) throws -> SkyStudioVoicePlan {
        guard !lines.isEmpty, lines.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Problem(message: "Give at least one non-empty voiceover line.")
        }
        let clones = model.kind == "voice_clone"
        guard clones || model.kind == "voice" else { throw Problem(message: "Sky Studio did not offer a voice model.") }
        let code = clones ? cloneLanguage(language) : String(language.lowercased().prefix(2))
        let cap: Double?
        if clones {
            guard model.choices("language").contains(code) else {
                throw Problem(message: "Sky Studio's cloning model does not support \(language).")
            }
            cap = model.limits["max_characters_by_language"]?[code]?.doubleValue
        } else {
            cap = model.limit("max_characters")
        }
        guard let cap, cap.isFinite, cap >= 1, cap < Double(Int.max) else {
            throw Problem(message: "Sky Studio did not give a character limit for this voice's language.")
        }
        let speech = try SkyStudioVoiceBatch.make(lines: lines, limit: Int(cap), pack: clones)
        let batches = speech.map { batch in
            Batch(speech: batch, request: SkyStudioJobRequest(
                kind: model.kind, model: model.id, prompt: batch.prompt,
                params: clones ? ["language": .string(code)] : ["voice": .string(voice), "language_code": .string(code)]
            ))
        }
        return SkyStudioVoicePlan(model: model, language: code, batches: batches)
    }

    /// 语言名是接口的词表；额度来自 /models，不在这里抄每种语言的字符数。
    static func cloneLanguage(_ language: String) -> String {
        let code = language.lowercased().replacingOccurrences(of: "-", with: "_")
        switch code {
        case "en_gb": return code
        case "en", "en_us": return "en_us"
        case "zh", "zh_cn", "zh_hans", "cmn": return "cmn"
        case "fr", "fr_fr": return "fr_fr"
        case "pt", "pt_br": return "pt_br"
        default: return String(code.split(separator: "_").first ?? "")
        }
    }
}
