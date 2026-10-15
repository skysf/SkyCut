import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 工具：export_subtitles（工程的字幕写成 .srt / .vtt 文件）
//
// 管什么：导出面板「高级」里「导出字幕文件」的 AI 版（2026-10-15，用户转来的反馈：AI 没有导出字幕文件的路；用户定做独立工具、
// 第一版不做 ASS）：原文 / 译文各写一份，名字和撞名见 `AISubtitleFiles`、语言标签见 `SubtitleFileLanguage`（按文字判 → 记的 → 省略）；
// 默认放 export_video 的那个文件夹、名字默认工程名
// （同 export_video），给了 name 就用它 —— 传导出的视频的名字，字幕文件就和视频配成一对。写盘走界面那一条
// （`SubtitleExportPlanner.writeValidated`：临时名 → 回读校验 → 原子替换），藏起来的句子不写（`subtitleDocument(for:)`，
// 和预览、烧录、界面导出同一份）。不改工程：不是一步撤销、不摆窗口。
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）；双语合在一个文件里（只给烧录用）、ASS。

@MainActor
enum AISubtitleFileExport {
    static func export(_ args: AIToolArguments, _ project: VideoEditProject) throws -> AIToolResult {
        let state = project.state
        let format = SubtitleFormat(rawValue: try args.choice("format", from: MCPVocabulary.subtitleFileFormats) ?? "srt") ?? .srt
        var documents: [SubtitleTrack: SubtitleDocumentModel] = [:]
        for track in SubtitleTrack.allCases {
            if let document = state.subtitleDocument(for: track), !document.cues.isEmpty { documents[track] = document }
        }
        let tracks = try AISubtitleFiles.tracks(
            try args.choice("track", from: AISubtitleFiles.trackChoices) ?? "both", available: Set(documents.keys)
        )
        let fallback = AIExportTools.defaultName(project)
        let stem = ExportFileName.stem(from: try args.string("name") ?? fallback, droppingExtension: format.rawValue, fallback: fallback)
        let folder = try args.string("folder").map { AIWorkspace.shared.resolve($0) }
            ?? AIWorkspace.shared.outputFolder(.exports, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 标签按每条轨现在的文字判、判不出来才用记的（SubtitleFileLanguage）：手写 / 导入的轨工程里没记语言，只读记录就导出成
        // 不带标签的 promo.vtt，播放器当成视频的默认字幕（2026-10-15）。
        let companion = state.subtitleCompanion
        let targets = AISubtitleFiles.targets(
            tracks, stem: stem, folder: folder, format: format,
            sourceLanguage: companion?.sourceLanguage, targetLanguage: companion?.targetLanguage
        ) { FileManager.default.fileExists(atPath: $0.path) }
        var files: [JSONValue] = []
        for target in targets {
            guard let document = documents[target.track] else { continue }
            let written = try SubtitleExportPlanner.writeValidated(document, format: format, to: target.url)
            files.append([
                "track": .string(target.track.rawValue),
                "path": .string(written.path),
                "lines": .number(Double(SubtitleSerializer.emittedCueCount(document, format: format)))
            ])
        }
        return .ok([
            "files": .array(files),
            "note": "Times are timeline seconds, so the files fit a video exported from this timeline. Hidden lines are left out."
        ])
    }
}
