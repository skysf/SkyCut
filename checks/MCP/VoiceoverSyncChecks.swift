import Foundation
import SrtFlowMCPKit

// MCP 发现 / 参数合同；媒体与真实 App 接线在 check-voiceover-sync 验，不用纯值绿代替生产路径。
func runVoiceoverSyncChecks() {
    let tool = MCPToolName.syncVoiceover
    check(tool.takesProject && !tool.definition.readOnly, "narration sync is a project mutation")
    check(AIProjectBinding.usesProject(tool, AIToolArguments([:])), "narration sync resolves the caller's own project")
    let args: JSONValue = ["paragraphs": [["from": 0, "to": 10, "voiceover_id": "c3", "old_voiceover_id": "c2",
                                          "clips": [["clip_id": "c1", "fit": "freeze"]], "texts": ["t1"],
                                          "shapes": ["s1"], "subtitles": ["l1"]]], "language": "zh", "project": "p2"]
    check(MCPArgumentCheck.problem(tool: tool, arguments: args) == nil, "complete explicit mapping has no unknown parameters")
    for bad: JSONValue in [
        ["paragraphs": [["from": 0, "to": 10, "voiceover_id": "c3", "guess": true]], "language": "zh"],
        ["paragraphs": [["clips": [["clip_id": "c1", "duration": 8]]]], "language": "zh"],
        ["paragraphs": [["project": "p3"]]],
        ["scale_subtitles": true]
    ] {
        check(MCPArgumentCheck.problem(tool: tool, arguments: bad) != nil, "sync rejects unknown mapping/nested parameters atomically")
    }
    let opening = String(tool.definition.description.prefix(512))
    for word in ["get_job", "no paid generation", "one undo", "Subtitles"] {
        check(opening.contains(word), "sync's first 512 characters explain \(word)")
    }
}
