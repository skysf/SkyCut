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
                Record the Mac's screen to .mov at the end of V1, one undo step. Source: get_status screen=true. \
                action=start returns while recording; action=stop returns the job id, file, clip ids, stopped_by and stop_method; a user Stop \
                appears in your next tool result. action=resolve settles an unfinished one (discard may return needs_confirmation). Read \
                skycut_guide topic=record_screen first.
                """,
                input: MCPSchema.object([
                    "action": MCPSchema.string("start, stop or resolve a leftover.", oneOf: MCPVocabulary.recordingActions),
                    "source": MCPSchema.string("Default display.", oneOf: MCPVocabulary.recordingSources),
                    "display": MCPSchema.integer("Default 1, the main one.", minimum: 1),
                    "window": MCPSchema.string("App name, title words or window number."),
                    "rect": MCPSchema.object([
                        "x": MCPSchema.number("Left edge, 0–1.", minimum: 0, maximum: 1),
                        "y": MCPSchema.number("Top edge, 0–1.", minimum: 0, maximum: 1),
                        "width": MCPSchema.number("Width, 0–1.", minimum: 0, maximum: 1),
                        "height": MCPSchema.number("Height, 0–1.", minimum: 0, maximum: 1)
                    ], required: ["x", "y", "width", "height"], description: "region: display fractions, 0,0 top left."),
                    "ratio": MCPSchema.string("For drag: lock the area's shape.", oneOf: MCPVocabulary.recordingRatios),
                    "computer_audio": MCPSchema.boolean("The Mac's sound; default true."),
                    "microphone": MCPSchema.string("default or a mic name; omitted = off."),
                    "pointer": MCPSchema.string("Default shown.", oneOf: MCPVocabulary.recordingPointers),
                    "countdown": MCPSchema.integer("Seconds, 0-10; default 3.", minimum: 0, maximum: 10),
                    "duration": MCPSchema.number("Auto-stop after seconds, 1-14400.", minimum: 1, maximum: 14_400),
                    "title": MCPSchema.string("File name; default: date and time."),
                    "add_to_timeline": MCPSchema.boolean("Default true; false keeps only the file."),
                    "decision": MCPSchema.string("For resolve; discard may ask first.", oneOf: MCPVocabulary.recordingDecisions),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["action"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
