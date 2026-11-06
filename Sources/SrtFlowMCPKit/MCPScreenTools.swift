import Foundation

// MARK: - 工具说明：录屏（record_screen）
//
// 管什么：录屏这个工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。
// 产品口径见 docs/plans/2026-10-03-screen-recording-mcp.md：AI 自己挑来源（不开系统的选择窗口）、没授权时请求一次、
// 开录不问、开录之后马上回来好让 AI 一边录一边操作电脑。App 里怎么做在 AIScreenRecordingTool。
// 不管什么：状态、权限、能录的屏幕 / 窗口 / 麦克风 —— 那些是只读的，放在 get_status（screen=true）里
// （只读的和写文件的不放进同一个工具，MCP 方案第 33 条）。

public enum MCPScreenTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .recordScreen:
            return MCPToolDefinition(
                .recordScreen, title: "Record the screen",
                description: """
                Record the Mac's screen to .mov and add it to the end of V1 (microphone: a new audio track). action=start starts \
                recording; a late action=stop returns the completed job id, status, file, project, clip ids, stopped_by and \
                stop_method. User Stop is also reported on your next tool result. get_status screen=true lists displays, windows \
                and microphones. Choose a source yourself. A small Stop panel at the bottom left of the main display shows the \
                countdown, then start returns while capture continues; it is invisible in screenshots, so do not click there. \
                Recording ends on action=stop, duration, or the user's Stop. get_job shows progress and the same receipt. An \
                incomplete recording still lands and says why. Frame rate follows set_canvas fps. Without Screen & System Audio \
                Recording permission macOS asks the user once; the result explains next steps. macOS may remind them every \
                30 days. action=resolve settles an earlier unfinished recording.
                """,
                input: MCPSchema.object([
                    "action": MCPSchema.string(
                        "start, stop (or return the result if already stopped), or resolve a leftover one.", oneOf: MCPVocabulary.recordingActions
                    ),
                    "source": MCPSchema.string(
                        "What to record (default display). drag: the user drags the area.", oneOf: MCPVocabulary.recordingSources
                    ),
                    "display": MCPSchema.integer("Display number from get_status screen=true (default 1, the main one).", minimum: 1),
                    "window": MCPSchema.string("For window: app name, title words, or the window number from get_status; the frontmost match."),
                    "rect": MCPSchema.object([
                        "x": MCPSchema.number("Left edge.", minimum: 0, maximum: 1),
                        "y": MCPSchema.number("Top edge.", minimum: 0, maximum: 1),
                        "width": MCPSchema.number("Width.", minimum: 0, maximum: 1),
                        "height": MCPSchema.number("Height.", minimum: 0, maximum: 1)
                    ], required: ["x", "y", "width", "height"], description: "For region: the area as fractions of the display, 0,0 top left."),
                    "ratio": MCPSchema.string("For drag: lock the area's shape.", oneOf: MCPVocabulary.recordingRatios),
                    "computer_audio": MCPSchema.boolean("Record the computer's sound (default true)."),
                    "microphone": MCPSchema.string("Narration on its own track: default, or a name from get_status screen=true. Off if left out."),
                    "pointer": MCPSchema.string(
                        "shown (default), hidden, or clicks (shown, clicks highlighted).", oneOf: MCPVocabulary.recordingPointers
                    ),
                    "countdown": MCPSchema.integer("Seconds before it starts (default 3; 0 when you operate the Mac yourself).", minimum: 0, maximum: 10),
                    "duration": MCPSchema.number("Stop by itself after this many seconds.", minimum: 1, maximum: 14_400),
                    "title": MCPSchema.string("File name (default Screen Recording <date time>), in SkyCut/Screen Recordings; a taken name gets a number."),
                    "add_to_timeline": MCPSchema.boolean("Put it on the timeline when it stops (default true); false keeps only the file."),
                    "decision": MCPSchema.string(
                        "For resolve: add to the timeline, keep the file only, or discard (asks in approval mode).", oneOf: MCPVocabulary.recordingDecisions
                    ),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["action"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
