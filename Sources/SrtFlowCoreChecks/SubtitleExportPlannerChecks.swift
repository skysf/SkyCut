import Foundation
import SrtFlowCore

// The subtitle export planner (moved out of main.swift on 2026-11-19, which may only shrink): bilingual documents, file
// names, and the replacing write (temporary name → read back → atomic replace) that the export panel uses after Replace.
// The never-replacing writes are in ExclusivePlacementChecks.swift.

func runSubtitleExportPlannerChecks() throws {
    do {
        let a = SubtitleCue(index: 1, start: 0, end: 2, text: "hello")
        let b = SubtitleCue(index: 2, start: 2, end: 4, text: "world")
        let original = SubtitleDocumentModel(cues: [a, b])
        var translation = SubtitleDocumentModel(cues: [a])
        translation.cues[0].text = "你好"

        let bilingual = SubtitleExportPlanner.bilingualDocument(original: original, translation: translation)
        checkEqual(bilingual.cues[0].text, "hello\n你好", "双语：原文上译文下")
        checkEqual(bilingual.cues[1].text, "world", "双语：缺译文的行只有原文，不编造")

        checkEqual(
            SubtitleExportPlanner.fileName(
                base: "movie", choice: .translation, sourceLanguage: "en",
                targetLanguage: "zh-Hans", format: .srt
            ),
            "movie.zh-Hans.srt", "命名：译文带目标语言标签"
        )
        checkEqual(
            SubtitleExportPlanner.fileName(
                base: "movie", choice: .bilingual, sourceLanguage: "en",
                targetLanguage: "zh-Hans", format: .vtt
            ),
            "movie.en-zh-Hans.vtt", "命名：双语 <src>-<dst>"
        )
        checkEqual(
            SubtitleExportPlanner.fileName(
                base: "movie", choice: .original, sourceLanguage: nil,
                targetLanguage: nil, format: .srt
            ),
            "movie.srt", "命名：没有语言标签就省略"
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("srtflow-planner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 同名：导出面板先提示、再确认，确认之后原子地整份替换（2026-09-24 起；
        // 以前是追加 -2/-3，重导几次就堆出一串，见 docs/architecture/export-settings.md）。
        try Data("x".utf8).write(to: dir.appendingPathComponent("movie.srt"))
        let replaced = dir.appendingPathComponent("movie.en.srt")
        try Data("old".utf8).write(to: replaced)

        // 写盘 → 回读校验 → 能再解析。
        let written = try SubtitleExportPlanner.writeValidated(original, format: .srt, to: replaced)
        let parsed = SubtitleParser.parse(
            try String(contentsOf: written, encoding: .utf8), format: .srt, filename: "movie.en.srt"
        )
        checkEqual(parsed.cues.count, 2, "写盘：同名旧文件被整份替换，SRT 回读 cue 数一致")
        checkEqual(parsed.cues.first?.text, "hello", "写盘：内容无损")

        let vtt = try SubtitleExportPlanner.writeValidated(
            translation, format: .vtt, to: dir.appendingPathComponent("movie.zh-Hans.vtt")
        )
        check(
            try String(contentsOf: vtt, encoding: .utf8).hasPrefix("WEBVTT"),
            "写盘：VTT 头正确"
        )

        // 失败路径：目标目录不存在 → 抛错，且不产生半截文件。
        let bogus = dir.appendingPathComponent("no-such-dir/out.srt")
        check(
            (try? SubtitleExportPlanner.writeValidated(original, format: .srt, to: bogus)) == nil,
            "写盘：坏目录要抛错"
        )
        check(
            !FileManager.default.fileExists(atPath: bogus.path),
            "写盘：失败不留半截文件"
        )
        // 既有文件在失败场景下原样保留。
        let precious = dir.appendingPathComponent("movie.srt")
        checkEqual(
            try String(contentsOf: precious, encoding: .utf8), "x",
            "写盘：规划器永不碰用户已有文件"
        )

        // 空文本 cue 是编辑器的合法状态（新建一行、拆分的后半都是空的）：写盘要
        // 跳过它，校验期望数必须与序列化器同账。曾在校验里按 text.isEmpty 另算
        // 一份：空 cue 序列化后只剩孤零零的时间行、回读仍算一条，两边差 1，
        // 带一条空 cue 的工程 VTT/SRT 全导不出（"verification failed"）。
        // 案例：docs/bugfixes/2026-08-22-subtitle-export-empty-cue-verification.md
        let midEmpty = SubtitleDocumentModel(cues: [
            SubtitleCue(index: 1, start: 0, end: 2, text: "hello"),
            SubtitleCue(index: 2, start: 2, end: 3, text: ""),
            SubtitleCue(index: 3, start: 3, end: 4, text: "world")
        ])
        let vttSkipped = try SubtitleExportPlanner.writeValidated(
            midEmpty, format: .vtt, to: dir.appendingPathComponent("empty-cue.vtt")
        )
        let vttSkippedDoc = SubtitleParser.parse(
            try String(contentsOf: vttSkipped, encoding: .utf8), format: .vtt
        )
        checkEqual(vttSkippedDoc.cues.count, 2, "写盘：空文本 cue 不写进 VTT，校验也不数它")
        checkEqual(vttSkippedDoc.cues.map(\.text), ["hello", "world"], "写盘：VTT 跳过空 cue 后内容无损")
        let srtSkipped = try SubtitleExportPlanner.writeValidated(
            midEmpty, format: .srt, to: dir.appendingPathComponent("empty-cue.srt")
        )
        let srtRaw = try String(contentsOf: srtSkipped, encoding: .utf8)
        checkEqual(SubtitleParser.parse(srtRaw, format: .srt).cues.count, 2, "写盘：空文本 cue 不写进 SRT")
        check(!srtRaw.contains("\n3\n"), "写盘：SRT 序号按写出的 cue 连续编，不给跳过的 cue 留号")

        // cue 文本自带的空行是块分隔符：写盘要清掉。不清的话后半段没有时间行，
        // 回读时被整段丢掉 —— cue 数对得上、校验绿灯，内容却悄悄少了半条。
        let gap = SubtitleDocumentModel(cues: [SubtitleCue(index: 1, start: 0, end: 2, text: "up\n\ndown")])
        let gapURL = try SubtitleExportPlanner.writeValidated(
            gap, format: .vtt, to: dir.appendingPathComponent("gap.vtt")
        )
        let gapDoc = SubtitleParser.parse(try String(contentsOf: gapURL, encoding: .utf8), format: .vtt)
        checkEqual(gapDoc.cues.count, 1, "写盘：文本内的空行不许把 cue 劈成两块")
        checkEqual(gapDoc.cues.first?.text, "up\ndown", "写盘：清掉空行后两截文本都保住")

        // ASS 的 Dialogue 行不怕空文本：逐条照写、逐条读回，校验期望数 = 全部 cue。
        let assURL = try SubtitleExportPlanner.writeValidated(
            midEmpty, format: .ass, to: dir.appendingPathComponent("empty-cue.ass")
        )
        let assDoc = SubtitleParser.parse(try String(contentsOf: assURL, encoding: .utf8), format: .ass)
        checkEqual(assDoc.cues.count, 3, "写盘：ASS 逐条照写，空文本 cue 也回得来")
    }
}
