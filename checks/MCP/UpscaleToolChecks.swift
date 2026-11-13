import Foundation
import SrtFlowMCPKit

// upscale_clip（2026-10-02；2026-10-28 起走 Sky Studio，收费方案第 6 刀）：小程序那份清单里的词表和 App 对账（档位 = Sky Studio 的模型名，
// 默认的那个在词表里；目标 = UpscaleTarget 按短边叫；范围 = UpscaleRangeChoice），工具的定义（参数、必填、枚举、始终列出、
// 上网、不删东西），说明里每个模型都点了名、说清积分 / 30 秒 / 30 fps / 只有排队中能取消，总说明的「Paid」那一行带着它。

func runUpscaleToolChecks() {
    // ---- 词表 ↔ App
    checkEqual(MCPVocabulary.upscaleTiers, ["topaz-starlight", "bytedance-upscaler-pro"], "the tier vocabulary is Sky Studio's two upscale models (2026-10-28)")
    check(MCPVocabulary.upscaleTiers.contains(AIUpscaleNames.defaultTierID), "the default tier is in the vocabulary")
    checkEqual(AIUpscaleNames.defaultTierID, UpscaleTier.defaultID, "the AI and the panel default to the same model")
    checkEqual(MCPVocabulary.upscaleTargets, UpscaleTarget.allCases.map(AIUpscaleNames.name(of:)), "the targets are the App's three, named by short side")
    checkEqual(AIUpscaleNames.target("2160p"), .p2160, "2160p is the 4K target")
    checkEqual(AIUpscaleNames.target("1080p"), .p1080, "1080p")
    check(AIUpscaleNames.target("4k") == nil && AIUpscaleNames.target("4K") == nil && AIUpscaleNames.target("2K") == nil,
          "Sky Studio's own names are not AI names (the vocabulary says 1440p / 2160p)")
    for name in MCPVocabulary.upscaleTargets {
        check(AIUpscaleNames.target(name).flatMap { UpscaleTarget(skyStudioName: $0.skyStudioName) } != nil, "target \(name) maps to a Sky Studio name and back")
    }
    for name in MCPVocabulary.upscaleRanges { check(AIUpscaleNames.range(name) != nil, "range \(name) resolves") }
    checkEqual(AIUpscaleNames.range("longest"), .longestUse, "longest is the longest use in the project")
    checkEqual(AIUpscaleNames.range("clip"), .thisClip, "clip is this clip")
    checkEqual(AIUpscaleNames.range("file"), .wholeFile, "file is the whole file")
    for choice in [UpscaleRangeChoice.thisClip, .longestUse, .wholeFile] {
        check(MCPVocabulary.upscaleRanges.contains(AIUpscaleNames.name(of: choice)), "range \(choice) has a name in the vocabulary")
        checkEqual(AIUpscaleNames.range(AIUpscaleNames.name(of: choice)), choice, "range names round-trip")
    }

    // ---- 定义
    checkEqual(MCPToolName.upscaleClip.provider, .skystudio, "upscale_clip belongs to Sky Studio (Key checked when called)")
    let definition = MCPToolName.upscaleClip.definition
    check(definition.openWorld, "upscale_clip reaches out to Sky Studio")
    check(!definition.readOnly && !definition.destructive, "upscale_clip writes a new file and changes clips but deletes nothing")
    let schema = definition.inputSchema
    checkEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["clip_id"], "only clip_id is required")
    let properties = schema["properties"]?.objectValue ?? [:]
    // `project`：碰工程的工具都收（2026-10-17 起一个会话剪几个工程，MCPToolName.takesProject）。
    // confirm_token：请求批准模式下 upscale 超出低成本草稿时回的确认码（2026-11-01 起；超了每日硬上限回 daily_budget_exceeded、不发码）。
    checkEqual(Set(properties.keys), ["clip_id", "tier", "target", "range", "project", "confirm_token", "approval_scope", "user_requested_overrides", "user_request"], "the parameters")
    checkEqual(properties["tier"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTiers, "tier lists the models")
    checkEqual(properties["target"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTargets, "target lists the targets")
    checkEqual(properties["range"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleRanges, "range lists the ranges")
    // 2026-11-10 名片迁移（方案 5.2 的分类）：花钱、确认、上限、撤销留在名片，结果字段、模型、目标、范围进说明书（topic=upscale_clip）。
    let text = definition.description
    for word in ["Sky Studio", "credits", "get_job", "needs_confirmation", "confirm_token", "daily credit limit", "revert", "undo", "30 s", "30 fps"] {
        check(text.contains(word), "the card mentions \(word)")
    }
    let guide = (MCPGuideTopics.topic(named: "upscale_clip")?.sections ?? []).map(\.text).joined(separator: "\n")
    for word in ["credits_charged", "replaced_ids", "source_size", "phase", "cancel_job", "library"] {
        check(guide.contains(word), "the upscale_clip guide topic mentions \(word)")
    }
    check(!(text + guide).contains("fal.ai") && !(text + guide).contains("cost_usd"), "neither the card nor the guide talks about fal.ai or dollars")
    for id in MCPVocabulary.upscaleTiers { check(guide.contains(id), "the guide topic names model \(id)") }
    for name in MCPVocabulary.upscaleTargets + MCPVocabulary.upscaleRanges { check(guide.contains(name), "the guide topic names \(name)") }
    // 说明书地图的「Paid」那一行始终带着它（2026-11-10 起目录在地图里）。
    check(guideMapText().contains("upscale_clip (sharper, larger clips)"), "the guide map's paid line names upscale_clip")
}
