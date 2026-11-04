import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 作者 round-trip / 显式重绑定 / 离线原样保存的真实 Reader 回归；不启动 App 或任何媒体任务。
func runProductionReaderChecks(root: URL) throws {
    typealias Reader = AIFilmProductionReader
    typealias Graph = AIFilmProductionGraph
    typealias Snapshot = AIFilmProductionSnapshot
    check(try Reader.input(AIToolArguments([:])) == nil, "ordinary save without production or CAS remains ordinary")
    let strayCAS: [JSONValue] = [0, .null]
    for value in strayCAS {
        do { _ = try Reader.input(AIToolArguments(["expected_revision": value])); check(false, "CAS without production must reject, including an explicit null") }
        catch { check(true, "CAS without production rejects before legacy save") }
    }
    check(try Reader.input(AIToolArguments(["production": .null, "expected_revision": 1])) == .null,
          "explicit clear reaches production CAS validation instead of ordinary save")
    let file = root.appendingPathComponent("production-reader-synthetic.mp4")
    try Data(repeating: 1, count: 512).write(to: file)
    var state = TimelineState()
    state.mainClips = (0..<3).map { EditClip(sourceURL: file, sourceDuration: 5, timelineStart: Double($0) * 5) }
    var plan = try productionFixture()
    for index in plan.shots.indices {
        plan.shots[index].outputClipID = state.mainClips[index].id
        plan.shots[index].boundSourceFingerprint = Snapshot.fingerprint(try Snapshot.source(state.mainClips[index].id, state: state, picture: true))
    }
    let first = try Graph.decode(plan)[0]
    let firstWindow = AIFilmProductionReadiness.window(state.mainClips[0], state: state)
    plan.shots[0].review = .init(sourceTimes: firstWindow.sourceRequests, notes: "Synthetic historic observations",
        sourceFingerprint: Snapshot.fingerprint(try Snapshot.authoredSource(first, state: state)))
    state.production = plan
    func json(_ value: FilmProductionState, in state: TimelineState) throws -> JSONValue {
        try AIFilmProductionJSON.plan(value, graph: Graph.decode(value), ids: AIShortIDs(state: state))
    }
    func replace(_ value: JSONValue, shot index: Int, _ updates: [String: JSONValue]) -> JSONValue {
        var object = value.objectValue!, rows = object["shots"]!.arrayValue!
        var row = rows[index].objectValue!
        row.merge(updates) { _, new in new }; rows[index] = .object(row); object["shots"] = .array(rows)
        return .object(object)
    }
    let readback = try json(plan, in: state)
    let unchanged = try Reader.read(readback, expectedRevision: 1, previous: plan, state: state)
    check(unchanged == plan, "unchanged plan with old observations saves offline as a no-op")
    var edited = state; edited.mainClips[0].sourceStart = 0.25
    let stale = try Reader.read(readback, expectedRevision: 1, previous: plan, state: edited)
    check(stale == plan, "same UUID changed output keeps original binding/review on plain save")
    let current = Snapshot.fingerprint(try Snapshot.source(edited.mainClips[0].id, state: edited, picture: true))
    let rebound = try Reader.read(replace(readback, shot: 0, ["output_binding": .string(current)]),
        expectedRevision: 1, previous: plan, state: edited)
    check(rebound.revision == 2 && rebound.shots[0].boundSourceFingerprint == current, "explicit current output_binding accepts new geometry")
    check(rebound.shots[0].review == plan.shots[0].review, "rebinding output never silently renews its old observations")
    let oldSnapshot = plan.shots[0].review!.sourceFingerprint
    check(oldSnapshot != Snapshot.fingerprint(try Snapshot.authoredSource(Graph.decode(rebound)[0], state: edited)), "retained old source review stays stale after explicit rebind")
    let wrong = replace(readback, shot: 0, ["output_binding": .string(String(repeating: "f", count: 64))])
    do { _ = try Reader.read(wrong, expectedRevision: 1, previous: plan, state: edited); check(false, "invented output binding rejected") }
    catch { check(true, "invented output binding rejected") }
    edited.mainClips[0] = EditClip(sourceURL: file, sourceDuration: 4, timelineStart: 0)
    let changedClip = replace(readback, shot: 0, ["clip_id": .string(edited.mainClips[0].id.uuidString), "output_binding": .null])
    let replaced = try Reader.read(changedClip, expectedRevision: 1, previous: plan, state: edited)
    check(replaced.shots[0].outputClipID == edited.mainClips[0].id && replaced.shots[0].review == plan.shots[0].review,
          "choosing another current clip explicitly rebinds it but preserves old review as stale")
    var removed = state; removed.mainClips.removeFirst()
    let orphan = try json(plan, in: removed)
    check(orphan["shots"]!.arrayValue![0]["clip_id"] == .string(plan.shots[0].outputClipID!.uuidString.lowercased()), "orphaned binding round-trips with its exact retained UUID")
    check(try Reader.read(orphan, expectedRevision: 1, previous: plan, state: removed) == plan, "deleted historical output remains readable and resavable as stale")
    let invented = replace(orphan, shot: 0, ["clip_id": .string(UUID().uuidString), "output_binding": .null])
    do { _ = try Reader.read(invented, expectedRevision: 1, previous: plan, state: removed); check(false, "new nonexistent UUID cannot masquerade as a historical binding") }
    catch { check(true, "new nonexistent UUID cannot masquerade as a historical binding") }
    do { _ = try Reader.read(readback, expectedRevision: 2, previous: plan, state: state); check(false, "authored revision CAS rejects stale callers") }
    catch { check(true, "authored revision CAS rejects stale callers") }
    var maximum = plan; maximum.revision = 100_000
    check(try Reader.read(json(maximum, in: state), expectedRevision: maximum.revision, previous: maximum, state: state) == maximum,
          "no-op readback at revision limit does not pre-increment into an invalid plan")
    let rewritten = try productionFixture(prompt: "A different render", revisions: [2, 2, 2])
    do { _ = try Reader.read(json(rewritten, in: state), expectedRevision: 1, previous: plan, state: state); check(false, "new render cannot silently query a missing catalog") }
    catch { check(true, "new render requires an explicit previously loaded public catalog") }
    check(state.production == plan, "pure author validation never mutates the captured TimelineState")
    try productionPermissionProjection(plan, root: root)
}

private func productionPermissionProjection(_ plan: FilmProductionState, root: URL) throws {
    let image = root.appendingPathComponent("not-written-permission.png").standardizedFileURL
    let candidate: JSONValue = ["image": ["file": .string(image.path)]]
    var scanning = plan
    scanning.shots[0].film = Data("intentionally invalid film; permission scanning must not parse it".utf8)
    scanning.shots[0].anchors = [.init(role: .first, sourceEdge: .firstUsed, fromShotID: "a",
        assetURL: URL(string: "https://assets.example/originals/account/frame.png")!,
        sourceFrame: try candidate.encodedData(), fingerprint: String(repeating: "a", count: 64))]
    check(AIFilmProductionJSON.anchorImageURLs(scanning) == [image], "permission scan only reads typed anchor image.file, without graph decode or file stat")
    check(SourceFrameReader.permissionImageURL(candidate) == image, "author JSON and saved Data use the same permission path rule")
    do { _ = try SourceFrameReader.read(candidate); check(false, "a permission candidate is never accepted as native evidence") }
    catch { check(true, "a permission candidate still needs complete strict native validation") }
    scanning.shots[0].anchors[0].sourceFrame = Data(repeating: 32, count: 32_769)
    check(AIFilmProductionJSON.anchorImageURLs(scanning).isEmpty, "oversized stored source-frame Data is not decoded for permissions")
    check(SourceFrameReader.permissionImageURL(["image": ["file": "relative.png"]]) == nil, "permission projection rejects relative paths")
}
