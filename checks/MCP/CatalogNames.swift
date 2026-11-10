import Foundation
import SrtFlowMCPKit

// 写给 AI 的长文字（剪辑风格卡、说明书 skycut_guide 手写的部分）里提到的名字必须真的存在：工具改了名、参数换了，
// 文字没跟着改，AI 照着调就会报错。RecipeChecks 和 GuideChecks 共用这两个小件（2026-11-10 从 RecipeChecks 拆出来：同一个做法的第二个用处）。

/// 工具名、所有参数名（整份工具清单里的 properties）、选项词表里的值，外加 AI 能在结果里读到的几个字段名。
func catalogKnownNames() -> Set<String> {
    var names = Set(MCPToolName.allCases.map(\.rawValue))
    func walk(_ value: JSONValue) {
        switch value {
        case .object(let object):
            if case .object(let properties)? = object["properties"] { names.formUnion(properties.keys) }
            // 清单里的选项值（export_video 的 quick_review、ai_access_mode 的 full_access……）也是真名字。
            if case .array(let choices)? = object["enum"] { names.formUnion(choices.compactMap(\.stringValue)) }
            object.values.forEach(walk)
        case .array(let items):
            items.forEach(walk)
        default:
            break
        }
    }
    walk(MCPToolName.listJSON)
    names.formUnion(MCPVocabulary.transitions + MCPVocabulary.filterPresetIDs + MCPVocabulary.textAnimations
        + MCPVocabulary.clipAnimations + MCPVocabulary.soundScenes + MCPVocabulary.textEmphasis
        + MCPVocabulary.numberStyles + MCPVocabulary.voiceRoles + MCPVocabulary.textPositions + MCPVocabulary.subtitlePositions
        + MCPVocabulary.keyframeEasings + MCPVocabulary.shapeAnimations)
    names.insert("music_credits")  // get_timeline 的结果里的字段
    names.insert("lines_with_word_times")  // get_subtitles 的结果里的字段
    names.formUnion(["new_video", "new_audio"])  // track 参数开新轨的两个值（只写在说明里，不是参数名）
    // generate_media（只有存了 Sky Studio 的 Key 才在清单里，但 listJSON 是配好时的全份）的词表和结果字段：卡里提到它们时要对得上。
    names.formUnion(MCPVocabulary.generationKinds + MCPVocabulary.videoResolutions + MCPVocabulary.generationAspects)
    names.formUnion(["credits", "credits_charged", "waiting_for_user", "job_id", "needs_confirmation"])
    // 说明书的通用主题提到的结果字段和报错代码（2026-11-10）：get_timeline 的 edit_limits、get_status 的 skycut_plan、
    // 没存过的工程存下来时的 project_saved_to、每日硬上限的 daily_budget_exceeded、几乎每个结果都有的 next_step、MCP 结果的 isError。
    names.formUnion(["edit_limits", "skycut_plan", "project_saved_to", "daily_budget_exceeded", "next_step", "isError"])
    return names
}

/// 看起来像工具名 / 参数名（snake_case）或者选项值（camelCase，如 pushLeft、coldWhite）的词。
/// camelCase 两头都要至少两个小写字母：「15 dB」的 dB 不算。
func catalogIdentifiers(in text: String) -> Set<String> {
    let pattern = #"\b(?:[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[a-z]{2,}[A-Z][a-z]+[A-Za-z]*)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
}
