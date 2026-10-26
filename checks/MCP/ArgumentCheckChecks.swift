import Foundation
import SrtFlowMCPKit

// 参数名对不上工具的说明，整个调用不做（`MCPArgumentCheck`，docs/bugfixes/2026-10-27-unknown-tool-arguments-silently-ignored.md）：
// 2026-10-26 真 Codex 冒烟里它给 set_text 传了 `end`，以前被悄悄丢掉、时长用了默认的 3 秒，看起来对，其实是碰巧。

func runArgumentCheckChecks() {
    // 冒烟里的原样调用：不认 end，话里说清楚没做、改用 duration。
    let codex = MCPArgumentCheck.problem(tool: .setText, arguments: ["project": "p1", "text": "Codex test", "start": 0, "end": 3])
    check(codex?.contains("\"end\"") == true, "set_text with end is refused and names end: \(codex ?? "nil")")
    check(codex?.contains("nothing was done") == true, "the refusal says nothing was done: \(codex ?? "nil")")
    check(codex?.contains("give duration") == true, "the refusal points an end time to duration: \(codex ?? "nil")")

    // 说明上有的都过；值是 null 的等于没传。
    checkEqual(MCPArgumentCheck.problem(tool: .setText, arguments: ["text": "Hi", "start": 0, "duration": 3, "end": nil]), nil,
               "known names pass and a null value counts as not given")
    // project 哪个工具都能带：get_job 不收 project，子代理照规矩每次都带。
    checkEqual(MCPArgumentCheck.problem(tool: .getJob, arguments: ["job_id": "export-1", "wait_seconds": 30, "project": "p1"]), nil,
               "project is accepted even by a tool that does not take it")
    // 只收 project 的工具，别的名字都不认，话里列出它收什么。
    let timeline = MCPArgumentCheck.problem(tool: .getTimeline, arguments: ["verbose": true])
    check(timeline?.contains("Its parameters: project.") == true, "a tool that only takes project lists it: \(timeline ?? "nil")")

    // 大小写、下划线写得不一样：猜一个。
    let camel = MCPArgumentCheck.problem(tool: .setText, arguments: ["text": "Hi", "fontSize": 40])
    check(camel?.contains("Did you mean \"font_size\"?") == true, "fontSize suggests font_size: \(camel ?? "nil")")

    // 实现里认的别名照收：set_shape 把 length 当成 width。
    checkEqual(MCPArgumentCheck.problem(tool: .setShape, arguments: ["kind": "line", "length": 0.5]), nil, "set_shape keeps length as a width alias")

    // 里层：数组里的对象、对象里的对象，报出位置。
    let clip = MCPArgumentCheck.problem(tool: .addClips, arguments: ["clips": [["file": "a.mp4"], ["file": "b.mp4", "duration": 2]]])
    check(clip?.contains("in clips[1]") == true && clip?.contains("\"duration\"") == true, "a wrong field in clips[1] is named with its place: \(clip ?? "nil")")
    let effect = MCPArgumentCheck.problem(tool: .addClips, arguments: ["clips": [["sound_effect": ["preset": "whoosh", "loudness": 3]]]])
    check(effect?.contains("in clips[0].sound_effect") == true, "a wrong field two levels down is named with its place: \(effect ?? "nil")")
    let style = MCPArgumentCheck.problem(tool: .editSubtitles, arguments: ["style": ["size": 48, "colour": "#ffffff"]])
    check(style?.contains("\"colour\"") == true && style?.contains("in style") == true, "a wrong style field is refused: \(style ?? "nil")")
    // 里层的自由对象照收：generate_media 的 options 原样转给模型。
    checkEqual(MCPArgumentCheck.problem(tool: .generateMedia, arguments: ["kind": "image", "prompt": "a cat", "options": ["seed": 7, "anything": true]]), nil,
               "a free-form object such as options is not checked")

    // 每个工具：说明上第一层的每个名字都认（新加参数、改说明之后，这一步保证核对不会把说明上写着的挡掉）。
    for tool in MCPToolName.allCases {
        guard let properties = tool.definition.inputSchema["properties"]?.objectValue else { continue }
        var everything: [String: JSONValue] = [:]
        for name in properties.keys { everything[name] = "x" }
        checkEqual(MCPArgumentCheck.problem(tool: tool, arguments: .object(everything)), nil, "\(tool.rawValue) accepts every name its description lists")
    }
}
