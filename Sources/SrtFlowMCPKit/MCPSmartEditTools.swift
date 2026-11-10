import Foundation

// MARK: - 工具清单：分析数据 + 智能剪（方案第 13 条、第 3 块）
//
// 管什么：transcribe（词级时间）、cut_speech（按文字剪、删停顿和口头禅）、cut_to_beat（踩点）的说明文字和参数。
// 静音段和鼓点在 listen 里（MCPSenseTools）。
// 不管什么：怎么转写、读哪份缓存（App 里的 AITranscribeTool）。

enum MCPSmartEditTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .transcribe:
            return MCPToolDefinition(
                .transcribe, title: "Transcribe speech",
                description: """
                Read-only. What is said where: sentences with start, end and text, and every word with words=true. Timeline clips give \
                timeline seconds; a file gives file seconds. Media never transcribed returns job_id: wait with get_job, then call \
                again with the same arguments. Long transcripts continue from next_from. Outside files may return needs_confirmation. \
                Cut what you find with cut_speech.
                """,
                input: MCPSchema.object([
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Clips to transcribe (default: video-track clips with sound)."),
                    "file": MCPSchema.string("A media file instead of clips (absolute, or relative to the opened folder)."),
                    "source_in": MCPSchema.number("With file: start, seconds in the file (≥ 0).", minimum: 0),
                    "source_out": MCPSchema.number("With file: end, seconds in the file (≥ 0).", minimum: 0),
                    "language": MCPSchema.string("Spoken language, e.g. en, zh-Hans, ja; auto (default) detects it."),
                    "from": MCPSchema.number("Read from this time on (≥ 0; timeline seconds, or file seconds with file).", minimum: 0),
                    "to": MCPSchema.number("Read up to this time, seconds (≥ 0).", minimum: 0),
                    "words": MCPSchema.boolean("Also list every word with its start and end (estimates: 0.1-0.3 s off around pauses)."),
                    "max_chars": MCPSchema.integer("Roughly how much text per call (default 12000).", minimum: 1000, maximum: 60000),
                    "confirm_token": MCPSchema.confirmToken
                ]),
                readOnly: true
            )
        case .cutSpeech:
            let range = MCPSchema.object([
                "start": MCPSchema.number("Timeline seconds (≥ 0).", minimum: 0),
                "end": MCPSchema.number("Timeline seconds (≥ 0).", minimum: 0)
            ], required: ["start", "end"])
            return MCPToolDefinition(
                .cutSpeech, title: "Cut speech",
                description: """
                Tighten a talking clip on V1: cut ranges (sentence or word times from transcribe), keep only some ranges, shorten \
                pauses, remove filler words and repeats (both need transcribe first). Cuts snap into measured pauses; moved lists \
                every shifted time. Later V1 clips close up. Linkage on: subtitles and items on the clip follow its pieces; off: other \
                tracks stay. One undo step. Read skycut_guide topic=cut_speech before the first call.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("The talking clip on V1."),
                    "remove": MCPSchema.array(of: range, "Ranges to cut out."),
                    "keep": MCPSchema.array(of: range, "Keep only these ranges of the clip; the rest of it is cut."),
                    "snap": MCPSchema.boolean("false: cut remove / keep exactly at the given times, only rounded to frames (default true)."),
                    "remove_pauses": MCPSchema.number("Shorten pauses longer than this many seconds (e.g. 0.6).", minimum: 0.2),
                    "pause_left": MCPSchema.number("Seconds of each shortened pause to leave (default 0.25).", minimum: 0, maximum: 2),
                    "remove_fillers": MCPSchema.boolean("Cut filler words (needs transcribe first)."),
                    "remove_repeats": MCPSchema.boolean("Cut words said twice in a row, like \"I I\" (needs transcribe first)."),
                    "silence_db": MCPSchema.number("Quieter than this counts as a pause, -80 to -10 dBFS (default: measured from the clip).", minimum: -80, maximum: -10),
                    "language": MCPSchema.string("Language of the transcript to use (default auto).")
                ], required: ["clip_id"])
            )
        case .cutToBeat:
            return MCPToolDefinition(
                .cutToBeat, title: "Cut to the beat",
                description: """
                Re-time a run of V1 clips so every cut lands on a beat of a music clip: each clip keeps its in point and gets a new \
                out point on a beat (nearest, or beats_per_clip beats; on=downbeats for bars). Later V1 clips and linked sound follow; \
                the music stays. Needs a steady beat (listen beats=true). One undo step.
                """,
                input: MCPSchema.object([
                    "music_clip_id": MCPSchema.string("The music clip whose beats to cut on."),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "V1 clips next to each other (default: the V1 clips playing while the music does)."),
                    "beats_per_clip": MCPSchema.integer("Every clip lasts exactly this many beats (1–64).", minimum: 1, maximum: 64),
                    "on": MCPSchema.string("Cut on every beat (default) or only on the first beat of each bar.", oneOf: ["beats", "downbeats"])
                ], required: ["music_clip_id"])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
