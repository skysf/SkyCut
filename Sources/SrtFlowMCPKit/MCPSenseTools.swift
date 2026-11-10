import Foundation

// MARK: - 工具说明：看、听（AI 的眼睛和耳朵）
//
// 管什么：look / listen 给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。
// 为什么有这两个：AI 看不见画面、听不见声音，2026-09-27 实测时只好拿用户电脑上的 ffmpeg 抽帧、量响度
// （方案第 31 条）。聊天型客户端连终端都没有，只能靠 SrtFlow 自己的工具。

public enum MCPSenseTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .look:
            return look
        case .listen:
            return listen
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    private static var listen: MCPToolDefinition {
        MCPToolDefinition(
            .listen, title: "Measure the sound",
            description: """
            Read-only. Measure sound: level, peak, silences, loudest moment and a level curve for one clip (with its volume, fades \
            and faders), a file, or every audible clip. beats=true finds tempo, beats and downbeats; cuts=true checks every V1 cut \
            for pauses and speech and suggests better in or out points. Outside files may return needs_confirmation.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("A clip on the timeline."),
                "file": MCPSchema.string("A media file instead (absolute, or relative to the opened folder)."),
                "from": MCPSchema.number("Timeline seconds to start at (≥ 0).", minimum: 0),
                "to": MCPSchema.number("Timeline seconds to stop at (≥ 0).", minimum: 0),
                "source_in": MCPSchema.number("With file: start, seconds in the file (≥ 0).", minimum: 0),
                "source_out": MCPSchema.number("With file: end, seconds in the file (≥ 0).", minimum: 0),
                "silence_db": MCPSchema.number("Quieter than this counts as silence (default -45).", minimum: -80, maximum: -10),
                "min_silence": MCPSchema.number("Shortest silence to report, seconds (default 0.5).", minimum: 0.1, maximum: 10),
                "beats": MCPSchema.boolean("Also find the tempo and every beat (one clip or file)."),
                "cuts": MCPSchema.boolean("Check every V1 cut: in a pause, or on speech with a better source_in / source_out."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }

    private static var look: MCPToolDefinition {
        MCPToolDefinition(
            .look, title: "Look at the picture",
            description: """
            Read-only. See frames instead of guessing: the composed timeline (time/times, or count across clip_id) or a file \
            (source seconds). Returns a labelled contact sheet plus boxes for faces/people/text, brightness and black bars. Also: \
            files (up to 24), shots=true (shot bounds), text_scan=true (burned-in subtitles, watermarks). Long scans return job_id; \
            wait with get_job. Outside files may return needs_confirmation. Details: skycut_guide topic=look.
            """,
            input: MCPSchema.object([
                "time": MCPSchema.number("One moment, seconds (≥ 0): timeline, or in the file with file.", minimum: 0),
                "times": MCPSchema.array(of: MCPSchema.number("Seconds."), "Several moments (up to 12)."),
                "clip_id": MCPSchema.string("Timeline: spread the frames over this clip's part of the timeline."),
                "file": MCPSchema.string("A media file instead of the timeline: absolute, or relative to the opened folder."),
                "source_in": MCPSchema.number("With file and no times: spread frames from here, seconds (≥ 0).", minimum: 0),
                "source_out": MCPSchema.number("With file and no times: stop here, seconds (≥ 0).", minimum: 0),
                "count": MCPSchema.integer("How many frames to spread (1–12).", minimum: 1, maximum: 12),
                "files": MCPSchema.array(of: MCPSchema.string("A media file."), "Several media files at once (up to 24)."),
                "shots": MCPSchema.boolean("Split file (a video) or clip_id into shots."),
                "text_scan": MCPSchema.boolean("Scan file (a video) or clip_id for text that stays on screen."),
                "from": MCPSchema.number("With shots: start at this second (≥ 0), the previous next_from.", minimum: 0),
                "size": MCPSchema.string("Picture size (default medium).", oneOf: ["small", "medium", "large"]),
                "image": MCPSchema.boolean("false: text descriptions only, no picture."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }
}
