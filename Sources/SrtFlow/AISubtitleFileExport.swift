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
// The folder is made, checked and listed, and the files are written, off the main thread through ExportDestinationProbe with
// export_video's deadline (AIExportDestination; docs/bugfixes/2026-11-19-ai-export-folder-checked-on-main-thread.md).
// 不管什么：说明文字（SrtFlowMCPKit/MCPSubtitleExportTools.swift）；双语合在一个文件里（只给烧录用）、ASS。

@MainActor
enum AISubtitleFileExport {
    /// `destination` / `deadline`: the checks pass a drive that never answers or is read-only (ExportDestinationProbe).
    static func export(
        _ args: AIToolArguments, _ project: VideoEditProject,
        destination probe: ExportDestinationProbe = .shared, deadline: TimeInterval = AIExportDestination.deadline
    ) async throws -> AIToolResult {
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
        let place = Place(folder: try args.string("folder"), project: project)
        // 标签按每条轨现在的文字判、判不出来才用记的（SubtitleFileLanguage）：手写 / 导入的轨工程里没记语言，只读记录就导出成
        // 不带标签的 promo.vtt，播放器当成视频的默认字幕（2026-10-15）。
        let languages = SubtitleFileLanguage.tags(in: state)
        // The folder: made, checked and listed off the main thread; a name already there makes the whole set numbered.
        let planned = await probe.run(on: place.near, deadline: deadline, timedOut: Planned.refused(.noResponse, place.near)) { files in
            let folder = place.folder(files)
            let report = AIExportDestination.prepareFolder(folder, fileSystem: files)
            if let problem = report.problem { return .refused(problem, folder) }
            return .ready(AISubtitleFiles.targets(
                tracks, stem: stem, folder: folder, format: format,
                sourceLanguage: languages.source, targetLanguage: languages.target
            ) { report.contains($0.lastPathComponent) })
        }
        let targets: [AISubtitleFiles.Target]
        switch planned {
        case .refused(let problem, let folder): throw AIExportDestination.refusal(problem, folder: folder)
        case .ready(let ready): targets = ready
        }
        let writes = targets.compactMap { target in documents[target.track].map { (target: target, document: $0) } }
        // Written off the main thread too: temporary name → read back → atomic replace.
        let outcome = await probe.run(on: place.near, deadline: deadline, timedOut: Written.notResponding) { _ in
            do {
                return .written(try writes.map { target, document in
                    let written = try SubtitleExportPlanner.writeValidated(document, format: format, to: target.url)
                    return WrittenFile(track: target.track, path: written.path, lines: SubtitleSerializer.emittedCueCount(document, format: format))
                })
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        switch outcome {
        case .notResponding:
            let folder = targets.first?.url.deletingLastPathComponent() ?? place.near
            throw AIToolError("The drive with “\(folder.lastPathComponent)” stopped responding while SkyCut was writing the subtitle files "
                + "into \(AIWorkspace.shared.display(folder)). They may appear there when the drive answers; check before writing them again.")
        case .failed(let message):
            throw AIToolError(message)
        case .written(let files):
            return .ok([
                "files": .array(files.map {
                    ["track": .string($0.track.rawValue), "path": .string($0.path), "lines": .number(Double($0.lines))]
                }),
                "note": "Times are timeline seconds, so the files fit a video exported from this timeline. Hidden lines are left out."
            ])
        }
    }

    /// Which folder: `folder` as given (resolved like every AI path), else export_video's folder. Read on the main thread;
    /// the drive is asked off it.
    struct Place: Sendable {
        var named: String?
        var preferred: URL?
        var fallback: URL?
        var start: URL

        @MainActor init(folder named: String?, project: VideoEditProject) {
            self.named = named
            (preferred, fallback) = AIWorkspace.shared.resolutionFolders()
            start = AIWorkspace.shared.startFolder(project: project)
        }

        /// Asking the drive which of two folders holds a relative `folder`, and whether the old `SrtFlow` folder is there.
        func folder(_ files: ExportDestinationProbe.FileSystem) -> URL {
            folder(exists: { files.kind($0) != .missing }, isFolder: { files.kind($0) == .folder })
        }

        /// The same folder without asking the drive: picks the drive and names the folder when it does not answer.
        var near: URL { folder(exists: { _ in false }, isFolder: { _ in false }) }

        private func folder(exists: (URL) -> Bool, isFolder: (URL) -> Bool) -> URL {
            named.map { AIPathResolution.resolve($0, preferred: preferred, fallback: fallback, exists: exists) }
                ?? AIWorkspace.outputFolder(.exports, in: start, isFolder: isFolder)
        }
    }

    enum Planned: Sendable {
        case refused(ExportDestinationProblem, URL)
        case ready([AISubtitleFiles.Target])
    }

    struct WrittenFile: Sendable {
        var track: SubtitleTrack
        var path: String
        var lines: Int
    }

    enum Written: Sendable {
        case written([WrittenFile])
        case failed(String)
        case notResponding
    }
}
