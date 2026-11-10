import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// manage_voices 的 `language` 可选、不给就识别（SkyCut 声音方案 4.6；案例 docs/bugfixes/2026-11-11-manage-voices-language-required.md）。
// 真 App 对象 + 假协议（VoiceLibraryHTTP）；识别换成假的（VoiceLibraryFixture.detectedLanguage，`detections` 数它被叫了几次）：
// - 不给 language：在做好的参考录音上识别一次；识别成了什么写进授权的问句和结果（language、language_detected），没点头之前什么都不传；
//   照原样带上确认码再调（仍不给 language）认同一张令牌，`POST /voices` 带识别出来的那个；带上识别出来的 language 再调也认、不再识别；
// - 识别不出来：一样都不问、不传，回 `reason: language_undetected` 和「带上 language 再调」，不叫 AI 去点界面；
// - 给了就照给的：识别的那一头一次都不叫、不被它的结果盖掉；大写收成小写；写错的照旧报错（不悄悄改成识别）；给空的算没给；
// - add_reference 同一条路：问句写识别出来的语言，`POST /voices/{id}/references` 带它；识别出来的语言这个声音已经有：问之前就说
//   （和 AI 给的那种同一句，另说它是识别出来的、认错了带上 language 再调），什么都不传。

@MainActor
func runVoiceLibraryLanguageChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("library-language"))
    let file = try fixture.recording()
    try await detectedChecks(fixture, file)
    try await undetectedChecks(fixture, file)
    try await givenChecks(fixture, file)
    try await referenceChecks(fixture, file)
}

@MainActor
private func detectedChecks(_ fixture: VoiceLibraryFixture, _ file: URL) async throws {
    fixture.detectedLanguage = "zh"
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Auto"]
    let asked = try await fixture.manage(args)
    let token = asked.payload["confirm_token"]?.stringValue
    let question = asked.payload["question"]?.stringValue ?? ""
    require(token != nil && fixture.detections == 1, "create without language detects it on the prepared sample, once, and then asks")
    require(asked.payload["language"] == "zh" && asked.payload["language_detected"] == true,
            "the question's result names the detected language: \(asked.payload)")
    require(question.contains("detected the recording's language as Chinese (zh)") && question.contains("call again with language"),
            "the consent question names the detected language and how to correct it: \(question)")
    require(VoiceLibraryHTTP.calls("POST", "/uploads").isEmpty && VoiceLibraryHTTP.calls("POST", "/voices").isEmpty,
            "nothing is uploaded or created before the user agrees")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = .string(token ?? "")
    let created = try await fixture.manage(.object(confirmed))
    require(created.payload["status"] == "created", "the same call with the token (still without language) is accepted: \(created.payload)")
    require(created.payload["language"] == "zh" && created.payload["language_detected"] == true
            && created.payload["language_note"]?.stringValue?.contains("Chinese (zh)") == true,
            "the result says which language was detected and asks the AI to tell the user")
    require(VoiceLibraryHTTP.calls("POST", "/voices").first?["language"] == "zh", "POST /voices carries the detected language")

    // 问的时候没给、点过头再调时带上识别出来的那个：同一件事，同一张令牌，不再识别。
    VoiceLibraryHTTP.reset()
    fixture.detectedLanguage = "en"
    let second: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Auto Two"]
    let again = try await fixture.manage(second)
    let before = fixture.detections
    var named = second.objectValue ?? [:]
    named["language"] = "en"
    named["confirm_token"] = again.payload["confirm_token"] ?? .null
    let made = try await fixture.manage(.object(named))
    require(made.payload["status"] == "created" && fixture.detections == before && made.payload["language_detected"] == nil,
            "repeating with the detected language spelled out redeems the same token without detecting again: \(made.payload)")
}

@MainActor
private func undetectedChecks(_ fixture: VoiceLibraryFixture, _ file: URL) async throws {
    VoiceLibraryHTTP.reset()
    fixture.detectedLanguage = nil
    do {
        let result = try await fixture.manage(["action": "create", "file": .string(file.path), "name": "Sky Unknown"])
        require(false, "an undetected language must stop the call, never guess: \(result.payload)")
    } catch let error as AIToolError {
        require(error.details["reason"] == .string(SkyStudioVoiceRecordingLanguage.undetectedReason) && error.details["reason"] == "language_undetected",
                "an undetected language is reported with reason language_undetected: \(error.details)")
        require(error.message == SkyStudioVoiceRecordingLanguage.undetectedMessage
                && error.message.contains("Call manage_voices again with language") && error.message.contains("ISO 639-1")
                && error.message.contains("Nothing was sent"),
                "the AI is told to call again with language, and that nothing was sent: \(error.message)")
        for word in ["panel", "Settings", "dialog", "window", "click", "sheet"] {
            require(!error.message.localizedCaseInsensitiveContains(word), "the AI is not sent to the interface (\(word)): \(error.message)")
        }
    }
    require(VoiceLibraryHTTP.calls("POST", "/uploads").isEmpty && VoiceLibraryHTTP.calls("POST", "/voices").isEmpty,
            "nothing is uploaded or created when the language is unknown")
}

@MainActor
private func givenChecks(_ fixture: VoiceLibraryFixture, _ file: URL) async throws {
    VoiceLibraryHTTP.reset()
    // 识别会说中文；AI 说英文：照 AI 的，识别的那一头一次都不叫。
    fixture.detectedLanguage = "zh"
    let before = fixture.detections
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Sky Given", "language": "EN"]
    let asked = try await fixture.manage(args)
    let question = asked.payload["question"]?.stringValue ?? ""
    require(asked.payload["language"] == "en" && asked.payload["language_detected"] == nil && !question.contains("detected"),
            "a given language is used as given and not reported as detected: \(asked.payload)")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let created = try await fixture.manage(.object(confirmed))
    require(created.payload["status"] == "created" && created.payload["language"] == "en" && created.payload["language_note"] == nil
            && VoiceLibraryHTTP.calls("POST", "/voices").first?["language"] == "en",
            "POST /voices carries the given language, not the one detection would have found")
    require(fixture.detections == before, "a given language never runs the detection")

    do {
        _ = try await fixture.manage(["action": "create", "file": .string(file.path), "name": "Sky Wrong", "language": "chinese"])
        require(false, "a malformed language is refused")
    } catch let error as AIToolError {
        require(error.message.contains("ISO 639-1") && fixture.detections == before,
                "a malformed language is refused as before, not silently replaced by detection: \(error.message)")
    }

    // 给空的算没给：识别。
    let blank = try await fixture.manage(["action": "create", "file": .string(file.path), "name": "Sky Blank", "language": " "])
    require(blank.payload["language"] == "zh" && blank.payload["language_detected"] == true && fixture.detections == before + 1,
            "a blank language counts as omitted: \(blank.payload)")
}

@MainActor
private func referenceChecks(_ fixture: VoiceLibraryFixture, _ file: URL) async throws {
    VoiceLibraryHTTP.reset()
    fixture.detectedLanguage = "ja"
    let args: JSONValue = ["action": "add_reference", "voice": .string(VoiceLibraryHTTP.voiceID), "file": .string(file.path)]
    let asked = try await fixture.manage(args)
    let question = asked.payload["question"]?.stringValue ?? ""
    require(asked.payload["language"] == "ja" && asked.payload["language_detected"] == true && question.contains("add a Japanese recording to"),
            "add_reference without language asks with the detected language: \(question)")
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let added = try await fixture.manage(.object(confirmed))
    require(added.payload["status"] == "reference_added" && VoiceLibraryHTTP.calls("POST", "/references").first?["language"] == "ja",
            "POST /voices/{id}/references carries the detected language: \(added.payload)")

    // 夹具里的声音「Sky」已经有英文：识别出来的也是英文，问之前就说（另说它是识别出来的），什么都不传。
    VoiceLibraryHTTP.reset()
    fixture.detectedLanguage = "en"
    do {
        let result = try await fixture.manage(args)
        require(false, "a detected language the voice already has is refused before anything is asked: \(result.payload)")
    } catch let error as AIToolError {
        require(error.message.contains("The voice \"Sky\" already has a recording in English") && error.message.contains("SkyCut detected English (en)")
                && error.message.contains("call again with language") && error.message.contains("Nothing was sent"),
                "a detected language the voice already has is refused, saying it was detected and how to correct it: \(error.message)")
    }
    require(VoiceLibraryHTTP.calls("POST", "/uploads").isEmpty && VoiceLibraryHTTP.calls("POST", "/references").isEmpty,
            "nothing is uploaded or sent for a detected language the voice already has")
}
