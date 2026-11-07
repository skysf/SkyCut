import Foundation
import SrtFlowMCPKit

// 工程作者输入从紧凑清单展开同一公开合同；深层未知字段不能因为按需说明而绕过。
// 媒体身份/状态延续的值校验在生产状态自检，本文件只钉真实 MCP 名字入口和公开语义。
func runProductionSchemaChecks() {
    let compact = MCPToolName.saveProject.definition.inputSchema["properties"]!
    checkEqual(Set(compact.objectValue!.keys), ["path", "project", "production", "expected_revision"], "save_project exposes the production CAS entry")
    checkEqual(compact["production"]?["type"], ["object", "null"], "production can author or explicitly clear the plan")
    check(compact["production"]?["properties"] == nil, "large production contract remains on demand")
    checkEqual(compact["expected_revision"]?["minimum"], 0, "absent production starts at expected revision zero")
    checkEqual(MCPProductionSchema.validationSchema(for: .saveProject)?["properties"]?["production"], MCPFilmSchema.contract["production_schema"], "published production schema is the actual expanded argument validator")
    checkEqual(MCPFilmSchema.contract["production_enabled"], .null, "public schema alone never proves server deployment")

    let plan = MCPFilmSchema.contract["production_schema"]!["properties"]!
    let shot = plan["shots"]!["items"]!["properties"]!
    checkEqual(shot["film"], MCPFilmSchema.film, "saved stories use the same public film contract")
    checkEqual(shot["render"], MCPFilmSchema.render, "saved and neighbor renders share one public contract")
    check(shot["output_binding"] != nil && shot["output_review"]?["properties"]?["source_snapshot"] != nil, "output binding and output observation snapshot are separate fields")
    let anchor = shot["anchors"]!["items"]!["properties"]!
    let source = anchor["source_frame"]!
    checkEqual(Set(source["required"]!.arrayValue!.compactMap(\.stringValue)), Set(source["properties"]!.objectValue!.keys), "every accepted source-frame metadata field is required")
    checkEqual(source["required"]!.arrayValue!.count, 15, "accepted native anchor metadata has its full fifteen-field shape")
    checkEqual(source["properties"]?["actual_in_used_window"]?["enum"], [true], "out-of-window native evidence is not an accepted anchor")
    checkEqual(source["properties"]?["requested_source_time"]?["properties"]?["timescale"]?["enum"], [600], "requested native time scale is explicit")
    let alignment = plan["sound_cues"]!["items"]!["properties"]!["alignment"]!["properties"]!
    check(alignment["measured_note"] != nil && alignment["listened_note"] != nil, "numeric measurement and actual auditioning stay distinct")

    let unknown: [JSONValue] = [
        ["recipe_pin": "opaque"],
        ["shots": [["output_binding_snapshot": "wrong_name"]]],
        ["shots": [["film": ["shot": ["entry": ["actorPosition": "wrong_name"]]]]]],
        ["shots": [["render": ["input": [:]]]]],
        ["shots": [["output_review": ["sourceSnapshot": "wrong_name"]]]],
        ["shots": [["output_review": ["action_samples": [["action": "wrong_name"]]]]]],
        ["shots": [["output_review": ["previous": ["source_times": []]]]]],
        ["shots": [["anchors": [["source_frame": ["actual_time": 0]]]]]],
        ["shots": [["anchors": [["source_frame": ["actual_source_time": ["ticks": "0"]]]]]]],
        ["shots": [["anchors": [["source_frame": ["image": ["file_identity": ["size": "1"]]]]]]]],
        ["sound_cues": [["alignment": ["listened": true]]]],
        ["sound_cues": [["end": 2]]]
    ]
    for (index, value) in unknown.enumerated() {
        check(MCPArgumentCheck.problem(tool: .saveProject, arguments: ["production": value, "expected_revision": 0]) != nil,
              "production deep unknown-field guard \(index) reaches the actual MCP validator")
    }
    check(MCPArgumentCheck.problem(tool: .saveProject, arguments: ["path": "/tmp/story.skycut", "project": "p1"]) == nil,
          "ordinary project saves preserve their argument surface")
    check(MCPArgumentCheck.problem(tool: .saveProject, arguments: ["production": .null, "expected_revision": 1]) == nil,
          "explicit plan clearing passes name validation")
    // 2026-11-07 用户定：角色 A/B 的三个工具将全清单上限提高到 110,000。
    let count = JSONValue.object(["tools": MCPToolName.listJSON]).encodedString().utf16.count
    check(count <= 110_000, "production authoring keeps the complete catalog within 110000 UTF16 units (\(count))")
    check(MCPToolName.freezeFrame.definition.description.contains("upright_source"), "native freeze evidence does not promise final composed pixels")
    let workflow = MCPFilmSchema.contract["production_workflow"]!.encodedString()
    for phrase in ["historical inputs", "GET-only", "expected_snapshots.shots[].output_binding", "actually auditioning"] {
        check(workflow.contains(phrase), "production workflow preserves \(phrase)")
    }
}
