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
            Measure sound: clip_id is one timeline clip including volume/fades/faders; neither clip nor file lists all \
            audible clips. from/to limits timeline seconds. file uses source seconds, source_in/source_out narrows it. \
            Returns level_db (RMS excluding silence), peak_db, silences (silence_db/min_silence), loudest_at and per-step \
            curve for one clip/file; dBFS -60 or less is silent. beats=true returns tempo_bpm, beats and downbeats for one \
            clip/file. cuts=true with neither checks every V1 head/tail for pauses/speech, names words from transcribe and \
            gives edit_clip suggested_source_in / suggested_source_out. External-file approval follows the AI permission mode.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("A clip on the timeline."),
                "file": MCPSchema.string("A media file instead (absolute, or relative to the opened folder)."),
                "from": MCPSchema.number("Timeline seconds to start at.", minimum: 0),
                "to": MCPSchema.number("Timeline seconds to stop at.", minimum: 0),
                "source_in": MCPSchema.number("With file: start, seconds in the file.", minimum: 0),
                "source_out": MCPSchema.number("With file: end, seconds in the file.", minimum: 0),
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
            Inspect frames instead of guessing. Without file: composed timeline (tracks, crop, placement, filters, shapes, \
            text, subtitles), at time/times or count moments across clip_id; default playhead. With file: source seconds; \
            no times uses count (default 6) across source_in/source_out or the whole file. Returns labelled contact sheet \
            and Vision guesses (trust the images), face/person/subject/text boxes, brightness and black bars; timeline also \
            lists visible items. image=false omits pictures. External-file approval follows the AI permission mode. files \
            samples up to 24 files at their middle. shots=true with video file/clip_id gives shot bounds, middle-frame \
            descriptions/thumbnails, 24 per call; paginate from=next_from. Long scans return job_id: wait with get_job, \
            then repeat look. text_scan=true with video file/clip_id samples every 2 seconds for burned-in subtitle bands, \
            watermarks and slides/screens with boxes; clip_id also reports project subtitle_overlaps.
            """,
            input: MCPSchema.object([
                "time": MCPSchema.number("One moment, seconds (timeline, or in the file with file).", minimum: 0),
                "times": MCPSchema.array(of: MCPSchema.number("Seconds."), "Several moments (up to 12)."),
                "clip_id": MCPSchema.string("Timeline: spread the frames over this clip's part of the timeline."),
                "file": MCPSchema.string("Look at this media file instead of the timeline (absolute, or relative to the opened folder)."),
                "source_in": MCPSchema.number("With file and no times: where to start spreading the frames, seconds.", minimum: 0),
                "source_out": MCPSchema.number("With file and no times: where to stop, seconds.", minimum: 0),
                "count": MCPSchema.integer("How many frames to spread (1–12).", minimum: 1, maximum: 12),
                "files": MCPSchema.array(of: MCPSchema.string("A media file."), "Several media files at once (up to 24)."),
                "shots": MCPSchema.boolean("Split file (a video) or clip_id into shots."),
                "text_scan": MCPSchema.boolean("Scan file (a video) or clip_id for text that stays on screen."),
                "from": MCPSchema.number("With shots: list shots from this time on (next_from of the last call).", minimum: 0),
                "size": MCPSchema.string("Picture size (default medium).", oneOf: ["small", "medium", "large"]),
                "image": MCPSchema.boolean("false: only the text descriptions, no picture (for models that cannot see images)."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }
}
