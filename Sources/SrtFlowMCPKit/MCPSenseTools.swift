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

    // 2026-11-16: mix=true (per-layer mix measurement) arrived with about 940 units left in the whole catalog, so the card and the
    // parameter notes were cut down and the long wording lives in the skycut_guide listen topic (what / levels / beats / cuts / mix);
    // the catalog is no longer than before mix=true.
    private static var listen: MCPToolDefinition {
        MCPToolDefinition(
            .listen, title: "Measure the sound",
            description: """
            Read-only. Level, peak, silences, loudest moment and curve of a clip (with its volume, fades and faders), a file or \
            every audible clip; mix=true: the mix itself per track, to the frame; voice=A1: is each narration line covered. \
            beats=true finds the beat; cuts=true checks V1 cuts. Outside files may return needs_confirmation.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("A timeline clip."),
                "file": MCPSchema.string("A media file (absolute, or in the opened folder)."),
                "from": MCPSchema.number("Timeline start (≥ 0 s).", minimum: 0),
                "to": MCPSchema.number("Timeline end (≥ 0 s).", minimum: 0),
                "source_in": MCPSchema.number("File start (≥ 0 s).", minimum: 0),
                "source_out": MCPSchema.number("File end (≥ 0 s).", minimum: 0),
                "silence_db": MCPSchema.number("Silence below this (default -45 dB).", minimum: -80, maximum: -10),
                "min_silence": MCPSchema.number("Shortest silence (default 0.5 s).", minimum: 0.1, maximum: 10),
                "beats": MCPSchema.boolean("Tempo and beats (one clip or file)."),
                "cuts": MCPSchema.boolean("Check V1 cuts for pauses and speech."),
                "mix": MCPSchema.boolean("Measure the mix itself."),
                "layers": MCPSchema.array(of: ["type": "string"], "With mix: A1, V1+V2 or rest (≤ 12).", maxItems: 12),
                "frames": MCPSchema.boolean("With mix: per frame."),
                "voice": MCPSchema.string("Narration track(s): A1, A1+A2 or auto."),
                "confirm_token": MCPSchema.confirmToken
            ]),
            readOnly: true
        )
    }

    private static var look: MCPToolDefinition {
        MCPToolDefinition(
            .look, title: "Look at the picture",
            description: """
            Read-only. See frames, don't guess: the timeline (time/times, or count over clip_id) or a file (source seconds) as a labelled \
            contact sheet with face/people/text boxes, brightness, black bars. Also files (24 max), shots=true, text_scan=true (subtitles, \
            watermarks). Slow looks return job_id: wait with get_job. Outside files may return needs_confirmation. skycut_guide topic=look.
            """,
            input: MCPSchema.object([
                "time": MCPSchema.number("One moment, seconds (≥ 0): timeline, or in the file with file.", minimum: 0),
                "times": MCPSchema.array(of: MCPSchema.number("Seconds."), "Several moments (up to 12)."),
                "clip_id": MCPSchema.string("Timeline: spread the frames over this clip's part of the timeline."),
                "file": MCPSchema.string("A media file instead of the timeline: absolute or relative to the opened folder."),
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
