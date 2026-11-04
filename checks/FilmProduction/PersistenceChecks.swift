import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 单元夹具走生产 ProjectIO 编解码；实际后台工程的编辑/撤销/重开另由 MCP 冒烟完成。
func runProductionPersistenceChecks(root: URL) throws {
    var state = TimelineState()
    check(state.production == nil && !state.requiresFormatVersion34, "ordinary timeline has no v34 production data")
    let empty = try JSONEncoder().encode(state)
    let emptyObject = try JSONSerialization.jsonObject(with: empty) as! [String: Any]
    check(emptyObject["production"] == nil, "absent production remains absent in ordinary timeline JSON")
    check(try JSONDecoder().decode(TimelineState.self, from: empty).production == nil, "old absent field decodes as nil")
    state.production = try productionFixture()
    check(!state.isEmpty && state.requiresFormatVersion34, "storyboard-only project is nonempty and requires v34")
    let path = root.appendingPathComponent("public-production.skycut")
    try VideoEditProjectIO.save(state, to: path)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    check(saved["formatVersion"] as? Int == 34, "production writer hard-codes the expected v34 contract")
    let loaded = try VideoEditProjectIO.load(from: path).timeline
    check(loaded.production == state.production, "normal ProjectIO reopens every public production record")
    check(try AIFilmProductionGraph.decode(loaded.production!).count == 3, "reopened declarations pass the same strict graph adapter")
    let summary = AIFilmProductionSummary.make(loaded)
    check(summary["evidence_kind"] == "caller_authored_observations", "reopened plan does not imply machine-certified continuity")
    check(summary["catalog_status"] == "not_revalidated_by_get_timeline", "offline readback does not pretend catalog validation")
    check(summary["plan"]?["shots"]?.arrayValue?.count == 3, "public plan remains readable without a hot model cache")
    var invalid = state
    var film = try JSONDecoder().decode(JSONValue.self, from: invalid.production!.shots[0].film).objectValue!
    film["unrecognized_field"] = true
    invalid.production!.shots[0].film = try JSONValue.object(film).encodedData()
    try VideoEditProjectIO.save(invalid, to: path)
    let corrupted = try VideoEditProjectIO.load(from: path).timeline
    check(AIFilmProductionSummary.make(corrupted)["status"] == "invalid_stored_production", "persisted bytes cannot bypass strict production validation on read/use")
    check(AIFilmProductionSummary.make(corrupted)["official_generation_allowed"] == false, "invalid public plan explicitly blocks official generation")
}
