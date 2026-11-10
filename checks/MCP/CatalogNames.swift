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
    // 试点迁移的工具主题提到的结果字段（2026-11-10）：edit_limits 里的 image_source_duration（AIEditLimits）、look shots / transcribe
    // 读不完时的 next_from（AILookShots、AITranscriptFormat）、look text_scan 带 clip_id 时的 subtitle_overlaps（AISubtitleOverlaps）。
    names.formUnion(["image_source_duration", "next_from", "subtitle_overlaps"])
    // add_voiceover 的说明书（MCPGuideVoiceTopics，2026-11-10 声音 PR 3）提到的结果字段（SkyStudioVoiceoverRun、SkyStudioVoiceCheckpoint.detail、
    // SkyStudioJobGate.budgetBlocked 里真有的键）和角色的本机音色名（af_heart 这种）。
    names.formUnion(["recovery_file", "voice_plan", "fallback_used", "cross_language", "completed_line_indices", "not_generated_line_indices",
                     "unknown_batch_indices", "recharge_url"])
    // 字幕时间（声音 PR 5）：AIVoiceoverTool 结果里的 subtitle_timing、subtitles.estimated_line_indices，任务里装转写模型时 get_job 的 local_step。
    names.formUnion(["subtitle_timing", "estimated_line_indices", "local_step"])
    // 声音 PR 4（几批同时交、中途换备用）：get_job 的 batches_done / batches_running / batches_waiting（SkyStudioVoiceBatchBoard.json）、
    // 各句是哪个模型读的 line_models（SkyStudioVoiceCheckpoint.detail）、任务结束码 fallback_needs_one_time（SkyStudioVoiceCodes）。
    names.formUnion(["batches_done", "batches_running", "batches_waiting", "line_models", "fallback_needs_one_time"])
    names.formUnion(AIVoiceRole.all.map(\.kokoroVoice))
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
