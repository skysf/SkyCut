import Foundation
import SrtFlowCore

/// 为一次烧字幕（或一次预览）准备好临时工作目录。
///
/// 目录里放两样东西：`subtitle.ass` 和 `fonts/`（里面软链着选中的字体文件）。
/// ffmpeg 进程的工作目录会设成这里，滤镜里只写 `subtitles=filename=subtitle.ass`
/// 这种相对名 —— 绕开了 ffmpeg 滤镜图里那套要给 `:` `'` `\` `[` `]` `,` 层层
/// 转义的规则，路径里有空格或冒号也不会出问题。
///
/// 写 ASS 之前先把每句的折行点写进字里（`prewrapped`，2026-10-15）：在哪儿折由 App 按预览、AI 的框同一份 `SubtitleLineWrap` 算，
/// 写成换行（`assDocument` 再写成 `\N`）并关掉 libass 自己的折行（WrapStyle 2）。libass 只会在 ASCII 空格处折，没有空格的长中文句
/// 成片整行溢出到画面两边（docs/bugfixes/2026-10-15-chinese-subtitles-overflow-without-spaces.md）；现在三处折在同一个地方。
enum BurnInWorkspace {

    struct Prepared {
        var directory: URL
        var paths: FFmpegCommand.BurnIn
    }

    static func create(
        cues: [SubtitleCue],
        style: BurnInStyle,
        fontFileURL: URL?,
        aspectRatio: Double,
        title: String,
        layout: SubtitleLayout? = nil
    ) throws -> Prepared {
        try create(
            blocks: [SubtitleRenderBlock(cues: cues, layout: layout)], style: style,
            fontFileURL: fontFileURL, aspectRatio: aspectRatio, title: title
        )
    }

    /// 几块字幕各用各的布局（视频编辑器里原文、译文分开摆时是两块，`TimelineState.subtitleScreenBlocks`）。
    static func create(
        blocks: [SubtitleRenderBlock],
        style: BurnInStyle,
        fontFileURL: URL?,
        aspectRatio: Double,
        title: String
    ) throws -> Prepared {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SrtFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let paths = FFmpegCommand.BurnIn()
        // 折行点 App 算、写成换行，libass 不再自己折；这台 Mac 上 libass 找不到回退字体的字（没下载苹方时的中文）点名一个每台 Mac 都有的，
        // 预览用同一个（SubtitleFallbackFont）。
        let ass = style.assDocument(
            blocks: prewrapped(blocks, style: style, aspectRatio: aspectRatio), aspectRatio: aspectRatio, title: title,
            fontOverrides: { SubtitleFontScale.burnOverrides($0, style: style) }, prewrapped: true
        )
        try Data(ass.utf8).write(to: directory.appendingPathComponent(paths.assFileName))

        let fontsDirectory = directory.appendingPathComponent(paths.fontsDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        if let fontFileURL {
            // 软链就够了：中文字体动辄十几兆，没必要每个任务真拷一份。
            try? FileManager.default.createSymbolicLink(
                at: fontsDirectory.appendingPathComponent(fontFileURL.lastPathComponent),
                withDestinationURL: fontFileURL
            )
        }

        return Prepared(directory: directory, paths: paths)
    }

    /// 每一块里每一段事件的字换成 `SubtitleLineWrap` 折好的几行（行间是换行、行首行尾的空格去掉），亮着的词的位置跟着换算到新的字里；
    /// 没有字的事件原样留着。字号 / 字距 / 可用宽度按 ASS 的虚拟画布算（`BurnInStyle.playResolution`，1080 高），和预览、`SubtitleLineBoxes` 同一份口径。
    static func prewrapped(_ blocks: [SubtitleRenderBlock], style: BurnInStyle, aspectRatio: Double) -> [SubtitleRenderBlock] {
        let canvasWidth = Double(BurnInStyle.playResolution(aspectRatio: aspectRatio).width)
        return blocks.map { block in
            let usable = SubtitleLineWrap.usableWidth(canvasWidth: canvasWidth, style: style, layout: block.layout)
            let fontSize = style.fontSize * (block.layout?.fontScale ?? 1)
            var copy = block
            for (k, cue) in block.cues.enumerated() {
                let plain = SubtitleSerializer.plainText(cue.text)
                let lit = (block.highlights[cue.id] ?? []).map { NSRange(location: $0.location, length: $0.length) }
                let lines = SubtitleLineWrap.lines(
                    of: plain, runs: SubtitleFontScale.runs(plain, style: style), style: style, fontSize: fontSize,
                    letterSpacing: style.letterSpacing, maxWidth: usable, lit: lit, litScale: block.highlight?.scale ?? 1
                )
                guard !lines.isEmpty else { continue }
                let joined = SubtitleLineWrap.joined(lines, of: plain, lit: lit)
                copy.cues[k].text = joined.text
                if block.highlights[cue.id] != nil {
                    copy.highlights[cue.id] = joined.lit.map { SubtitleTextRange(location: $0.location, length: $0.length) }
                }
            }
            return copy
        }
    }
}

/// 读字幕文件，编码探测跟文档窗口那边保持一致。
enum SubtitleLoader {
    static func load(_ url: URL) throws -> SubtitleDocumentModel {
        let data = try Data(contentsOf: url)
        // UTF-8 → UTF-16 → GBK，规则只在 SrtFlowCore 的 TextDecoding 一处（批量转换、AI 读文稿同一份）。
        guard let content = TextDecoding.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let format = SubtitleFormat.detect(from: url.lastPathComponent) ?? .text
        return SubtitleParser.parse(content, format: format, filename: url.lastPathComponent)
    }

    /// 按文件名给视频配字幕：`lesson01.mp4` ↔ `lesson01.srt`。
    ///
    /// 也接受字幕名多一段后缀的常见写法，比如 `lesson01.zh.srt`、
    /// `lesson01_中文.srt`。
    static func match(videos: [URL], subtitles: [URL]) -> [URL: URL] {
        var result: [URL: URL] = [:]
        var remaining = subtitles

        for video in videos {
            let base = video.deletingPathExtension().lastPathComponent.lowercased()

            // 先找完全同名的。
            if let index = remaining.firstIndex(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == base
            }) {
                result[video] = remaining.remove(at: index)
                continue
            }

            // 再找以视频名开头的（多一段语言后缀那种）。
            if let index = remaining.firstIndex(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base)
            }) {
                result[video] = remaining.remove(at: index)
            }
        }

        // 一个视频配一个字幕的场景最常见，直接给它配上，省得用户再点一次。
        if result.isEmpty, videos.count == 1, remaining.count == 1 {
            result[videos[0]] = remaining[0]
        }

        return result
    }
}
