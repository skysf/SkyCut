import Foundation
import SrtFlowMCPKit

// 迁移过的工具（名片写短、长话进说明书；方案 docs/plans/2026-11-09-mcp-guide.md 2.2、2.5、4.1、5.1、5.2）。只查 MCPGuideWrittenTopics.migrated 里的，
// 没迁移的等方案的 PR 4–5，上限到 PR 6 才对全部工具生效：
// - 名片 ≤ 450（目标 350，打印出来看）、按工具性质该写的固定说法都在（只读 / 一步撤销 / 任务号 / 花钱 / 会问 / 要先读说明书）；
// - 每条参数说明 ≤ 120，带 minimum / maximum 的说明里写着数字（Codex 不显示范围）；
// - 单个工具的参数定义 ≤ 4,500 UTF-8 字节，例外只有 edit_clip、generate_media（例外名单不许变长）；
// - 说明书的主题：overview 以迁移前的说明原文开头（一个字不丢）、迁移前后的名片不一样、几节都不空、有例子有相关主题；
//   手写的几节只提真有的名字（参数定义写成的 fields 几节是自动生成的，不算手写）。
//   没有可搬的原文的工具（行为和迁移一起改了，previousCard 为 nil）只许是写死的那几个（现在只有 add_voiceover，mcp-guide.md 第 14 条）。
// - 每一节讲什么（2026-11-10 试点实测之后）：手写的每一节带一行 about、fields 几节自动生成；分节回的主题第一次回答列出 contents、
//   next_step 叫它只读要用的那几节、常见的活只读哪一节（generate_media → spending、edit_clip → framing）。

let pilotCardLimit = 450
let pilotParameterLimit = 120
let pilotSchemaByteLimit = 4_500
/// 参数定义超过 4,500 字节的例外（方案 4.1：先列例外，名单不许变长）。
let pilotSchemaExceptions: Set<MCPToolName> = [.editClip, .generateMedia]
/// 没有可搬的原文的迁移工具：行为和迁移同一个 PR 改了，旧说明照抄进概要等于叫 AI 用已经没有的东西（add_voiceover：声音方案 4.10、4.2–4.4、
/// 第十二节 —— 默认 gemini:Charon、去掉 clone_from、不再收 Rachel；旧说明每一句去了哪写在那个 PR 的说明里）；从第一天起就按名片 + 说明书写的
/// 新工具（声音 PR 6 的 list_voices、manage_voices）。名单写死：加一个要改这里。
let pilotToolsWithoutPreviousCard: Set<MCPToolName> = [.addVoiceover, .listVoices, .manageVoices]

/// 迁移前的说明原文有多长（2026-11-10 从迁移前的清单量的，main 8b0d2a5）。overview 以 previousCard 开头是拼出来的、永远成立；
/// 原文一个字不丢靠这里钉住长度（PR 里另有逐字比对的记录），以后有人删改原文就红。
private let pilotPreviousCardLengths: [MCPToolName: Int] = [
    .editClip: 737, .generateMedia: 978, .setText: 249, .addClips: 577, .look: 968,
    // 第一批 25 个（main ac61520 的清单量的；原文在 MCPGuidePreviousCards，脚本照抄）。
    .editSubtitles: 819, .generateSubtitles: 542, .translateSubtitles: 548, .getSubtitles: 536, .exportSubtitles: 554, .transcribe:
    698, .listen: 660, .cutSpeech: 1023, .cutToBeat: 568, .syncVoiceover: 746, .exportVideo: 457, .inspectVideo: 487, .compressVideos:
    458, .burnSubtitles: 468, .getJob: 813, .setShape: 525, .setKeyframes: 466, .setFilter: 640, .freezeFrame: 584, .recordScreen:
    947, .manageFiles: 480, .openFolder: 697, .setSettings: 565, .upscaleClip: 1022, .manageCharacters: 508,
    // 第二批 27 个（main f76032e 的清单量的；原文在 MCPGuidePreviousCardsBatch2，脚本照抄）。
    .getStatus: 380, .setView: 442, .openProject: 710, .newProject: 556, .closeProject: 271, .saveProject: 158, .undo: 186, .seek: 93,
    .cancelJob: 58, .getSettings: 394, .getTimeline: 231, .setTrack: 253, .splitClip: 136, .deleteItems: 325, .duplicateItems: 418,
    .setTransition: 160, .setCanvas: 217, .editClips: 402, .setTexts: 420, .setShapes: 405, .findAudio: 516, .readDocument: 378,
    .convertSubtitles: 248, .recipes: 672, .saveRecipe: 415, .listCharacters: 481, .getCharacter: 360
]

/// 迁移过的工具按性质该写的固定说法（方案 2.2 第 4、5 条）。性质从工具本身看不全（会不会改时间线、要不要先读说明书），写在这里。
private let pilotNature: [MCPToolName: [String]] = [
    .editClip: ["One undo step", "skycut_guide topic=edit_clip"],
    .setText: ["One undo step"],
    .addClips: ["One undo step", "needs_confirmation"],
    .look: ["Read-only", "wait with get_job", "needs_confirmation", "skycut_guide topic=look"],
    .generateMedia: ["Paid (Sky Studio credits)", "quote_only", "needs_confirmation", "confirm_token", "daily credit limit",
                     "wait with get_job", "skycut_guide topic=generate_media"],
    // 第一批（2026-11-10）：改工程的 One undo step、回任务号的 wait with get_job、会问的 needs_confirmation、要先读的 skycut_guide topic=…；
    // 出片的 never overwrites / Never replaces a file、删文件的 Trash、export_video 的 music_credits、等用户的 waiting_for_user。
    .editSubtitles: ["One undo step"],
    .generateSubtitles: ["One undo step", "wait with get_job"],
    .translateSubtitles: ["One undo step", "wait with get_job", "waiting_for_user"],
    .getSubtitles: ["Read-only"],
    .exportSubtitles: ["Never replaces a file"],
    .transcribe: ["Read-only", "wait with get_job", "needs_confirmation"],
    .listen: ["Read-only", "needs_confirmation"],
    .cutSpeech: ["One undo step", "skycut_guide topic=cut_speech"],
    .cutToBeat: ["One undo step"],
    .syncVoiceover: ["one undo step", "wait with get_job", "skycut_guide topic=sync_voiceover"],
    .exportVideo: ["wait with get_job", "music_credits"],
    .inspectVideo: ["never edits", "wait with get_job", "needs_confirmation"],
    .compressVideos: ["wait with get_job", "needs_confirmation", "never overwrites"],
    .burnSubtitles: ["wait with get_job", "needs_confirmation", "never overwrites"],
    .getJob: ["Read-only", "waiting_for_user"],
    .setShape: ["One undo step"],
    .setKeyframes: ["One undo step"],
    .setFilter: ["One undo step"],
    .freezeFrame: ["One undo step"],
    .recordScreen: ["one undo step", "needs_confirmation", "skycut_guide topic=record_screen"],
    .manageFiles: ["needs_confirmation", "Trash"],
    .openFolder: ["Read-only"],
    .setSettings: ["needs_confirmation", "confirm_token"],
    .upscaleClip: ["Paid (Sky Studio credits)", "needs_confirmation", "confirm_token", "daily credit limit", "wait with get_job", "skycut_guide topic=upscale_clip"],
    .manageCharacters: ["Paid (Sky Studio credits)", "quote_only", "needs_confirmation", "confirm_token", "daily credit limit", "wait with get_job", "skycut_guide topic=manage_characters"],
    // add_voiceover 不收 quote_only（整段报价在回任务号之前自动做，声音方案 4.2），所以名片里没有它。
    .addVoiceover: ["One undo step", "Paid (Sky Studio credits)", "needs_confirmation", "daily credit limit", "wait with get_job",
                    "skycut_guide topic=add_voiceover"],
    .listVoices: ["Read-only", "skycut_guide topic=list_voices"],
    // 声音库的写：服务器上的事，不改工程、没有撤销（名片写明 no undo）；设计花积分、回任务号；授权 / 一次性费用 / 删除会问。
    .manageVoices: ["no undo", "Paid (Sky Studio credits)", "needs_confirmation", "daily credit limit", "wait with get_job",
                    "skycut_guide topic=manage_voices"],
    // 第二批（2026-11-10）：只读的 Read-only、改工程的 One undo step、会问的 needs_confirmation，外加各检查和扫描守卫要的说法
    // （get_status 的 screen recording 和 cloud_tasks、get_timeline 的 edit_limits、list_characters 的 compact summaries / 1 KiB、
    // recipes 的 which one you follow、delete_items 的 Linkage on:、convert_subtitles 的 or in folder）。
    .getStatus: ["Read-only", "screen recording", "and cloud_tasks grouped by project:"],
    .setView: ["Ask the user once per conversation"],
    .openProject: ["project=<id>"],
    .newProject: ["A taken name gets a number"],
    .closeProject: ["saved first"],
    .saveProject: ["one undo step"],
    .undo: ["one undo step"],
    .seek: ["Read-only"],
    .cancelJob: ["queued"],
    .getSettings: ["Read-only"],
    .getTimeline: ["Read-only", "edit_limits"],
    .setTrack: ["One undo step"],
    .splitClip: ["One undo step"],
    .deleteItems: ["One undo step", "Linkage on:"],
    .duplicateItems: ["One undo step"],
    .setTransition: ["One undo step"],
    .setCanvas: ["One undo step"],
    .editClips: ["one undo step"],
    .setTexts: ["one undo step"],
    .setShapes: ["one undo step"],
    .findAudio: ["Read-only", "music_credits", "never download"],
    .readDocument: ["Read-only", "needs_confirmation"],
    .convertSubtitles: ["never overwrites", "needs_confirmation", "or in folder"],
    .recipes: ["Read-only", "which one you follow"],
    .saveRecipe: ["only when they ask", "Trash"],
    .listCharacters: ["Read-only", "compact summaries", "1 KiB"],
    .getCharacter: ["Read-only"]
]

func runGuidePilotChecks() {
    checkEqual(Set(pilotNature.keys), Set(MCPGuideWrittenTopics.migrated), "every migrated tool has its required phrases listed")
    var cards: [String] = []
    for tool in MCPGuideWrittenTopics.migrated {
        let definition = tool.definition
        let card = definition.description
        cards.append("\(tool.rawValue) \(card.utf16.count)")
        check(card.utf16.count <= pilotCardLimit, "\(tool.rawValue): the card fits \(pilotCardLimit) characters (it is \(card.utf16.count))")
        for phrase in pilotNature[tool] ?? [] {
            check(card.contains(phrase), "\(tool.rawValue): the card says \"\(phrase)\"")
        }
        if definition.readOnly { check(card.contains("Read-only"), "\(tool.rawValue): a read-only tool says Read-only") }
        if definition.inputSchema["properties"]?["confirm_token"] != nil {
            check(card.contains("needs_confirmation"), "\(tool.rawValue): a tool that can ask says needs_confirmation")
        }
        let bytes = definition.inputSchema.encodedString().utf8.count
        if !pilotSchemaExceptions.contains(tool) {
            check(bytes <= pilotSchemaByteLimit, "\(tool.rawValue): the parameters fit \(pilotSchemaByteLimit) bytes (they are \(bytes))")
        }
        walkPilotParameters(definition.inputSchema, path: tool.rawValue)
        checkWrittenTopic(tool)
    }
    checkEqual(pilotSchemaExceptions, [.editClip, .generateMedia], "the over-4,500-byte exceptions stay edit_clip and generate_media only")
    let withoutPreviousCard = Set(MCPGuideWrittenTopics.migrated.filter { MCPGuideWrittenTopics.topic(for: $0)?.previousCard == nil })
    checkEqual(withoutPreviousCard, pilotToolsWithoutPreviousCard, "only the listed migrated tools have no pre-migration description to keep")
    checkEqual(pilotToolsWithoutPreviousCard, [.addVoiceover, .listVoices, .manageVoices],
               "the tools without a pre-migration description stay add_voiceover and the new voice library tools")
    print("MCP pilot cards: \(cards.joined(separator: ", ")) (limit \(pilotCardLimit), target 350).")
    runGuideFieldSplitChecks()
    runGuideContentsChecks()
}

/// 分节回的主题：第一次回答列出每一节讲什么（contents）、叫 AI 只读要用的那几节；迁移过的工具每个手写的节都写了讲什么；
/// 常见的活只读哪一节写在 next_step 里（2026-11-10 试点实测之后：只列节名、说「再按 section 取」时，模型把 generate_media 的六节全读了，输入 +41%）。
private func runGuideContentsChecks() {
    var parts: [String] = []
    for topic in MCPGuideTopics.all {
        let first = MCPGuide.answer(topic: topic.name, section: nil)
        guard first["next_step"] != nil else { continue }
        parts.append(topic.name)
        check(topic.sections.dropFirst().allSatisfy { !$0.about.isEmpty }, "\(topic.name): every section of a topic answered in parts says what it covers")
        checkEqual(first["contents"], .array(topic.sections.dropFirst().map { .string("\($0.name): \($0.about)") }),
                   "\(topic.name): the first answer lists what each section covers")
        check((first["next_step"]?.stringValue ?? "").contains("Read only the sections you need"), "\(topic.name): the next step says to read only what is needed")
    }
    print("MCP guide topics answered in parts: \(parts.joined(separator: ", ")).")
    for tool in MCPGuideWrittenTopics.migrated {
        for section in MCPGuideWrittenTopics.topic(for: tool)?.sections.dropFirst() ?? [] {
            check(!section.about.isEmpty && section.about.utf16.count <= pilotParameterLimit,
                  "\(tool.rawValue).\(section.name) says what it covers in at most \(pilotParameterLimit) characters")
            let unknown = guideUnknownNames(section.about)
            check(unknown.isEmpty, "\(tool.rawValue).\(section.name)'s about line names only real names (unknown: \(unknown.joined(separator: ", ")))")
        }
    }
    // 写了 readingTip 的主题：提示里点到的节真的有；分节回时 next_step 以它收尾。
    for topic in MCPGuideTopics.all {
        guard let tip = topic.readingTip else { continue }
        let named = tip.components(separatedBy: "section=").dropFirst().compactMap { $0.split(whereSeparator: { !$0.isLetter && $0 != "_" }).first.map(String.init) }
        check(!named.isEmpty && named.allSatisfy { name in topic.sections.contains { $0.name == name } }, "\(topic.name): the reading tip names a real section (\(tip))")
        if let next = MCPGuide.answer(topic: topic.name, section: nil)["next_step"]?.stringValue {
            check(next.hasSuffix(" " + tip), "\(topic.name): the next step ends with the reading tip")
        }
    }
    // 常见的活只读哪一节：花积分之前报价再问只要 spending、改画幅取景只要 framing。
    for (tool, section) in [("generate_media", "spending"), ("edit_clip", "framing")] {
        let next = MCPGuide.answer(topic: tool, section: nil)["next_step"]?.stringValue ?? ""
        check(next.contains("read only section=\(section)"), "\(tool): the first answer says the common job needs only section=\(section)")
        check(MCPGuideTopics.topic(named: tool)?.sections.contains { $0.name == section } == true, "\(tool): the tip names a real section")
    }
}

/// fields 几节自动切（review-344 第 5 条，2026-11-10 定）：按整个第一层参数切成 fields、fields_2……，每节 ≤ sectionBudget，
/// 一个参数连同里层不拆开、自己就超过的单独成一节；切完一行不丢、顺序不变。真实清单里每个工具都查，再拿手造的大参数定义证明真会切。
private func runGuideFieldSplitChecks() {
    var split: [String] = []
    for tool in MCPToolName.allCases {
        let sections = MCPGuideFields.sections(for: tool.definition.inputSchema)
        problemsInFieldSections(sections, schema: tool.definition.inputSchema).forEach { check(false, "\(tool.rawValue): \($0)") }
        if sections.count > 1 { split.append("\(tool.rawValue) (\(sections.count))") }
        // 每一节讲什么：拆开的写从哪个参数到哪个参数（第一次回答的 contents 里列着）。
        check(sections.allSatisfy { !$0.about.isEmpty }, "\(tool.rawValue): every fields section says what it covers")
        if sections.count > 1 {
            check(sections.allSatisfy { $0.about.hasPrefix("parameters ") || $0.about.hasPrefix("the parameter ") },
                  "\(tool.rawValue): a split fields section names the parameters it holds")
        }
        let topic = MCPGuideTopics.topic(named: tool.rawValue)?.sections.filter { $0.name == "fields" || $0.name.hasPrefix("fields_") }
        checkEqual(topic?.map(\.name), sections.map(\.name), "\(tool.rawValue): the topic carries every fields section")
    }
    print("MCP guide fields split into several sections: \(split.isEmpty ? "none" : split.joined(separator: ", ")).")

    // 手造：30 个第一层参数（每行约 230 字）+ 一个带 5 个里层字段的对象 + 一个自己就超过上限的参数。
    var properties: [String: JSONValue] = [:]
    for index in 1...30 { properties[String(format: "p%02d", index)] = ["type": "string", "description": .string(String(repeating: "word ", count: 44))] }
    var inner: [String: JSONValue] = [:]
    for index in 1...5 { inner["inner\(index)"] = ["type": "number", "description": .string(String(repeating: "deep ", count: 44))] }
    properties["p15_nested"] = ["type": "object", "properties": .object(inner)]
    properties["p31_huge"] = ["type": "string", "description": .string(String(repeating: "x", count: MCPGuideFields.sectionBudget + 100))]
    let schema: JSONValue = ["type": "object", "properties": .object(properties)]
    let sections = MCPGuideFields.sections(for: schema)
    check(sections.count >= 3, "a parameter list over the budget is split (into \(sections.count) sections)")
    let problems = problemsInFieldSections(sections, schema: schema)
    check(problems.isEmpty, "the synthetic split keeps every line in order: \(problems.joined(separator: "; "))")
    check(sections.contains { $0.text.hasPrefix("- p31_huge (") && !$0.text.contains("\n") }, "a parameter longer than the budget gets a section of its own")
    let empty = MCPGuideFields.sections(for: ["type": "object", "properties": [:]])
    checkEqual(empty.map(\.name), ["fields"], "a tool without parameters has one fields section")
    checkEqual(empty.first?.text, "This tool takes no parameters.", "it says the tool takes no parameters")
}

/// 一组 fields 节对不对：名字依次是 fields、fields_2……；拼起来正好是每个参数的那一行、顺序不变；没有一节从里层的行开始；
/// 超过上限的只许是单独一个第一层参数（连同它的里层）。
private func problemsInFieldSections(_ sections: [MCPGuideSection], schema: JSONValue) -> [String] {
    var problems: [String] = []
    let names = sections.indices.map { $0 == 0 ? "fields" : "fields_\($0 + 1)" }
    if sections.map(\.name) != names { problems.append("sections are named \(sections.map(\.name)), not \(names)") }
    let lines = MCPGuideFields.entries(for: schema).map(\.line)
    let joined = sections.flatMap { $0.text.components(separatedBy: "\n") }
    if !lines.isEmpty, joined != lines { problems.append("the sections do not hold every parameter line exactly once, in order") }
    for section in sections {
        if section.text.hasPrefix("  ") { problems.append("\(section.name) starts inside a parameter (an indented line)") }
        let topLevel = section.text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        if section.text.utf16.count > MCPGuideFields.sectionBudget, topLevel > 1 {
            problems.append("\(section.name) is \(section.text.utf16.count) characters with \(topLevel) parameters (budget \(MCPGuideFields.sectionBudget))")
        }
    }
    return problems
}

/// 每条参数说明 ≤ 120；带范围的写着数字。
private func walkPilotParameters(_ schema: JSONValue, path: String) {
    for (name, field) in schema["properties"]?.objectValue ?? [:] {
        let here = "\(path).\(name)"
        let description = field["description"]?.stringValue ?? ""
        check(description.utf16.count <= pilotParameterLimit, "\(here): the description fits \(pilotParameterLimit) characters (it is \(description.utf16.count))")
        if field["minimum"] != nil || field["maximum"] != nil {
            check(description.range(of: #"\d"#, options: .regularExpression) != nil, "\(here): the description spells out its range in numbers")
        }
        walkPilotParameters(field, path: here)
        if let items = field["items"] { walkPilotParameters(items, path: here + "[]") }
    }
}

/// 说明书里这个工具的主题：迁移前的原文还在、手写的几节齐全、只提真有的名字。
private func checkWrittenTopic(_ tool: MCPToolName) {
    guard let written = MCPGuideWrittenTopics.topic(for: tool), let topic = MCPGuideTopics.topic(named: tool.rawValue) else {
        check(false, "\(tool.rawValue): a migrated tool has a written guide topic")
        return
    }
    if let previousCard = written.previousCard {
        check(topic.sections.first?.text.hasPrefix(previousCard) == true, "\(tool.rawValue): the overview starts with the pre-migration description, word for word")
        checkEqual(previousCard.utf16.count, pilotPreviousCardLengths[tool], "\(tool.rawValue): the pre-migration description is kept whole (its measured length)")
        check(previousCard != tool.definition.description, "\(tool.rawValue): the card was rewritten (the long text now lives in the guide)")
    }
    checkEqual(Set(topic.sections.map(\.name)).count, topic.sections.count, "\(tool.rawValue): section names are unique")
    // 至少两节手写的（概要之外）：试点那 5 个大工具都有四节以上，第一批里 set_filter 这类小工具两节就写全了。
    check(written.sections.count >= 3, "\(tool.rawValue): the written topic has its own sections beyond the overview")
    check(!written.examples.isEmpty && !written.related.isEmpty, "\(tool.rawValue): the written topic has examples and related topics")
    for section in written.sections {
        check(!section.text.isEmpty, "\(tool.rawValue).\(section.name) is written")
        // overview 开头是迁移前的原文（名单之外的结果字段名照收），后面的手写部分只许提真有的名字。
        let text = section.name == MCPGuideSection.overview ? String(section.text.dropFirst(written.previousCard?.count ?? 0)) : section.text
        let unknown = guideUnknownNames(text)
        check(unknown.isEmpty, "\(tool.rawValue).\(section.name) names only real tools and parameters (unknown: \(unknown.joined(separator: ", ")))")
    }
}
