import Foundation
import SrtFlowMCPKit

// upscale_clip（2026-10-02；2026-10-28 起走 Sky Studio，收费方案第 6 刀）：小程序那份清单里的词表和 App 对账（档位 = Sky Studio 的模型名，
// 默认的那个在词表里；目标 = UpscaleTarget 按短边叫；范围 = UpscaleRangeChoice），工具的定义（参数、必填、枚举、只在存了 Sky Studio 的 Key 时列、
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
    checkEqual(MCPToolName.upscaleClip.provider, .skystudio, "upscale_clip belongs to Sky Studio (listed only with a Sky Studio key)")
    let definition = MCPToolName.upscaleClip.definition
    check(definition.openWorld, "upscale_clip reaches out to Sky Studio")
    check(!definition.readOnly && !definition.destructive, "upscale_clip writes a new file and changes clips but deletes nothing")
    let schema = definition.inputSchema
    checkEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["clip_id"], "only clip_id is required")
    let properties = schema["properties"]?.objectValue ?? [:]
    // `project`：碰工程的工具都收（2026-10-17 起一个会话剪几个工程，MCPToolName.takesProject）。
    // confirm_token：超了每日积分上限时回的确认码（AI 多开方案板 9）。
    checkEqual(Set(properties.keys), ["clip_id", "tier", "target", "range", "project", "confirm_token"], "the parameters")
    checkEqual(properties["tier"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTiers, "tier lists the models")
    checkEqual(properties["target"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleTargets, "target lists the targets")
    checkEqual(properties["range"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.upscaleRanges, "range lists the ranges")
    let text = definition.description
    for word in ["Sky Studio", "credits", "get_job", "needs_confirmation", "confirm_token", "credits_charged", "replaced_ids", "source_size",
                 "daily credit limit", "revert", "undo", "phase", "30 s", "30 fps", "cancel_job", "library"] {
        check(text.contains(word), "the description mentions \(word)")
    }
    check(!text.contains("fal.ai") && !text.contains("cost_usd"), "the description no longer talks about fal.ai or dollars")
    for id in MCPVocabulary.upscaleTiers { check(text.contains(id), "the description names model \(id)") }
    for name in MCPVocabulary.upscaleTargets + MCPVocabulary.upscaleRanges { check(text.contains(name), "the description names \(name)") }
    // 总说明的「Paid」那一行带着它（Claude Code 开场只看目录）；没存 Key 不提。
    check(MCPInstructions.text(providers: [.skystudio]).contains("upscale_clip"), "the instructions' paid line names upscale_clip")
    check(!MCPInstructions.text.contains("upscale_clip"), "without a key the instructions do not mention it")
}
