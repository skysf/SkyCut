import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 真 API 页 → MCP 摘要、真实文件命名器与远端任务状态；不碰账户或付费供应商。
@MainActor
func runToolResultChecks() async {
    do {
        for count in [28, 50] {
            let characters = (0..<count).map { index -> JSONValue in
                var value = characterJSON().objectValue!
                value["id"] = .string(String(format: "11111111-1111-4111-8111-%012d", index))
                value["name"] = .string("飞行员 \(index + 1)")
                value["default_generation_model"] = "nano2"
                value["default_generation_resolution"] = "2K"
                value["created_at"] = "2026-11-07T08:00:00.000Z"
                value["updated_at"] = "2026-11-07T09:00:00.000Z"
                value["source_prompt"] = .string(String(repeating: "a long prompt ", count: 1000))
                return .object(value)
            }
            SkyStudioStub.reset { _ in .http(200, JSONValue.object(["characters": .array(characters), "next_cursor": .string(characterID)]).encodedString()) }
            let page = try await SkyStudioAPI(session: SkyStudioStub.session).characters(limit: count, key: "test")
            let result = page.json, bytes = try result.encodedData().count
            print("Compact Character page \(count): \(bytes) UTF-8 bytes, \(result.encodedString().utf16.count) UTF-16 units.")
            print("Character page \(count) MCP text-result envelope: \(try AIToolResult.ok(result).json.encodedData().count) UTF-8 bytes.")
            check(bytes <= count * SkyStudioCharacterSummary.maximumBytes + 100, "the full page has a bounded compact size")
            checkEqual(result["next_cursor"], .string(characterID), "summary keeps pagination unchanged")
            checkEqual(result["characters"]?.arrayValue?.count, count, "summary never drops characters")
            for entry in result["characters"]!.arrayValue! {
                check(try entry.encodedData().count <= 1024, "one summary fits in 1 KiB including JSON escaping")
                checkEqual(entry["available_roles"], .array(SkyStudioCharacter.roles.map(JSONValue.string)), "summary lists available views in canonical order")
                check(entry["images"] == nil && entry["source_prompt"] == nil && !entry.encodedString().contains("https://"), "list excludes assets, thumbnails and prompts")
                checkEqual(entry["default_generation_model"], "nano2", "saved native model remains selectable")
            }
            checkEqual(page.characters[0].json, characters[0], "cached/full detail DTO remains unchanged by summary projection")
        }
        for name in [String(repeating: "\u{0001}", count: 5000), String(repeating: "🧑🏽‍🚀", count: 1000), "a" + String(repeating: "\u{0301}", count: 5000)] {
            var raw = characterJSON().objectValue!; raw["name"] = .string(name)
            raw["default_generation_model"] = .string(String(repeating: "m", count: 2000))
            raw["images"] = ["front": raw["images"]!["front"]!, "headshot": .null]
            let summary = SkyStudioCharacterSummary.json(try SkyStudioCharacter(json: .object(raw)))
            check(try summary.encodedData().count <= 1024, "escaped/control/combined Unicode names cannot exceed the per-entry cap")
            checkEqual(summary["available_roles"], ["front"], "null views are unavailable")
            check(summary["default_generation_model"] == nil, "overlong optional model identities are omitted, never cut into a different id")
        }
        var maximum = characterJSON().objectValue!
        for (key, length) in [("name", 1000), ("status", 100), ("default_generation_model", 94), ("default_generation_resolution", 30), ("created_at", 38), ("updated_at", 38)] {
            maximum[key] = .string(String(repeating: "x", count: length))
        }
        check(try SkyStudioCharacterSummary.json(SkyStudioCharacter(json: .object(maximum))).encodedData().count <= 1024,
            "all optional fields simultaneously at their budgets still fit one entry")
        let capabilities = characterCapabilitiesJSON()
        SkyStudioStub.reset { _ in .http(200, capabilities.encodedString()) }
        checkEqual(try await SkyStudioAPI(session: SkyStudioStub.session).characterCapabilities(key: "test").json, capabilities,
            "the independent capabilities object stays complete and unchanged")
        for status in ["done", "failed", "cancelled"] {
            let parsed = SkyStudioJobStatus(json: ["job_id": "finished", "status": .string(status), "phase": "queued", "queue_position": 2, "phase_seconds": 42])!
            check(parsed.phase == nil && parsed.queuePosition == nil && parsed.phaseSeconds == nil, "terminal remote states override stale provider phase: \(status)")
        }
        checkEqual(SkyStudioJobStatus(json: ["job_id": "active", "status": "running", "phase": "saving"])?.phase, "saving", "active server phase remains visible")
        let normal = SkyStudioCharacterJobReport.completionMessage(resuming: false)
        check(normal.contains("Character ready") && !normal.contains("recovered"), "ordinary completion and later reads do not claim restart recovery")
        checkEqual(SkyStudioCharacterJobReport.completionMessage(resuming: false, previousStatus: "done"), normal, "refreshing a completed original keeps its normal message")
        check(SkyStudioCharacterJobReport.completionMessage(resuming: true).contains("recovered"), "actual resume reports recovery")
        check(SkyStudioCharacterJobReport.completionMessage(resuming: false, previousStatus: "failed").contains("recovered"), "original failed finalization later recovered is described truthfully")
        runGeneratedNameChecks()
    } catch { check(false, "tool result production checks: \(error)") }
}

private func runGeneratedNameChecks() {
    let source = URL(fileURLWithPath: "/tmp/小屋.png")
    var generation = SkyStudioGeneration(kind: .image, prompt: "", params: [:], notes: [], operation: "camera_angle")
    func name(_ explicit: String? = nil) -> String { SkyStudioGenerationName.stem(name: explicit, generation: generation, source: source, fallback: "Image") }
    checkEqual(name(), "小屋 angle", "promptless camera angle uses source stem and short operation")
    generation.operation = "upscale"; generation.params["upscale_factor"] = "x3"
    checkEqual(name(), "小屋 x3", "upscale uses requested factor with source name")
    checkEqual(name("My chosen name"), "My chosen name", "explicit name still wins")
    generation.params = [:]
    checkEqual(name(), "小屋 x2", "default factor is represented in filename")
    let folder = URL(fileURLWithPath: "/tmp")
    let collision = ExportFileName.unoccupied(in: folder, stem: name(), pathExtension: "png") { $0.lastPathComponent == "小屋 x2.png" }
    checkEqual(collision.lastPathComponent, "小屋 x2 2.png", "same shared collision suffix avoids overwriting")
    generation.operation = "generate"; generation.prompt = "A quiet house."
    checkEqual(name(), "A quiet house", "ordinary prompt-derived naming stays intact")
}
