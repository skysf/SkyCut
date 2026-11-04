import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// read/validate 的边界台架：真实 Film、TimelineState 与 Snapshot；仅合成属性文件，无媒体解码。
func runAnchorReaderChecks() throws {
    let fixture = try SourceFrameFixture()
    defer { fixture.remove() }
    var state = TimelineState()
    state.frameRate = .fps24
    state.mainClips = (0..<3).map { EditClip(sourceURL: fixture.source, sourceDuration: 10, timelineStart: Double($0) * 10) }
    let clip = state.mainClips[1]
    let context = SkyStudioFilm.Context(environment: .interior, lightSource: .practical, shotTask: .readAction)
    let physical = SkyStudioFilm.State(actorPosition: "at table", hand: .right, grip: "holding object", propLocation: "right hand",
        actionPhase: "held", spatialRelation: "facing table", gaze: "object", screenDirection: "left to right", lighting: "steady", completedActions: [])
    let sound = SkyStudioFilm.Sound(bedID: "room", music: "quiet", environment: "room tone", foley: "none")
    let first = "https://assets.example/originals/account/first.png", last = "https://assets.example/originals/account/last.png"
    let render = SkyStudioFilm.Render(kind: .imageToVideo, model: "public-model", prompt: "An original test shot", params: [:],
        inputs: ["image_url": .string(first), "last_frame_url": .string(last)], context: context)
    func shot(_ id: String, index: Int) throws -> AIFilmProductionGraph.Shot {
        let value = SkyStudioFilm.Shot(id: id, index: index, total: 3, revision: 1, entry: physical, exit: physical, actions: [])
        var film = SkyStudioFilm(context: context, shot: value, sound: sound)
        if index > 0 { film.previous = .init(shotID: index == 1 ? "previous" : "current", render: render, soundBedID: "room", cut: .continuous, state: physical) }
        if index < 2 { film.next = .init(shotID: index == 0 ? "current" : "next", render: render, soundBedID: "room", cut: .continuous, state: physical) }
        let output = state.mainClips[index].id
        let binding = AIFilmProductionSnapshot.fingerprint(try AIFilmProductionSnapshot.source(output, state: state, picture: true))
        return .init(record: .init(film: try film.json.encodedData(), render: try render.json.encodedData(), outputClipID: output, boundSourceFingerprint: binding), film: film, render: render)
    }
    let current = try shot("current", index: 1)
    let graph = try [shot("previous", index: 0), current, shot("next", index: 2)]
    let approved: Set<URL> = [fixture.png]
    func input(_ role: String, _ edge: String, from: String, asset: String? = nil) throws -> JSONValue {
        var selected = fixture
        let sourceIndex = ["previous": 0, "current": 1, "next": 2][from]!
        selected.bound.timelineStart = state.mainClips[sourceIndex].timelineStart
        return ["role": .string(role), "source_edge": .string(edge), "from_shot_id": .string(from),
         "asset_url": .string(asset ?? (role == "first" ? first : last)),
         "source_frame": try selected.evidence(atEnd: edge == "last_used", scratch: UUID())]
    }
    func read(_ value: JSONValue, allowed: Set<URL>? = nil, subject: AIFilmProductionGraph.Shot? = nil,
              in graphValue: [AIFilmProductionGraph.Shot]? = nil) throws -> [FilmProductionState.SourceAnchor] {
        try AIFilmProductionAnchorReader.read(value, shot: subject ?? current, graph: graphValue ?? graph, state: state, allowedImages: allowed ?? approved)
    }
    for (role, edge, from) in [("first", "last_used", "previous"), ("first", "first_used", "current"),
                               ("last", "last_used", "current"), ("last", "first_used", "next")] {
        let value = try input(role, edge, from: from)
        let anchors = try read(.array([value]))
        try AIFilmProductionAnchorReader.validate(anchors, shot: current, graph: graph, state: state, allowedImages: approved)
        check(anchors.count == 1 && anchors[0].fromShotID == from && !anchors[0].fingerprint.isEmpty,
              "supported \(role) from \(from).\(edge) survives canonical revalidation")
        let frame = try SourceFrameReader.read(try JSONDecoder().decode(JSONValue.self, from: anchors[0].sourceFrame))
        check(frame.sourceClipID != clip.id, "scratch source clip UUID is provenance and may differ from the authoritative output UUID")
    }
    let valid = try input("last", "last_used", from: "current")
    rejected("unapproved PNG path is rejected before stat") { _ = try read(.array([valid]), allowed: []) }
    rejected("unknown private anchor metadata is rejected") { _ = try read(.array([changed(valid, ["recipe_pin"], "secret")])) }
    rejected("duplicate input roles are rejected") { _ = try read(.array([valid, valid])) }
    for (role, edge, from) in [("first", "first_used", "previous"), ("first", "last_used", "current"),
                               ("last", "first_used", "current"), ("last", "last_used", "next"), ("first", "last_used", "next")] {
        rejected("wrong role/source edge \(role) from \(from).\(edge) is rejected") { _ = try read(.array([input(role, edge, from: from)])) }
    }
    rejected("asset for the other input role cannot be reused") { _ = try read(.array([input("last", "last_used", from: "current", asset: first)])) }
    for asset in ["https://assets.example/generated/account/last.png", "https://assets.example/originals/account/last.png?token=secret"] {
        var changedShot = current
        changedShot.render.inputs["last_frame_url"] = .string(asset)
        rejected("only durable original image asset URLs are accepted") { _ = try read(.array([input("last", "last_used", from: "current", asset: asset)]), subject: changedShot) }
    }
    var noOutput = current
    noOutput.record.outputClipID = nil
    rejected("an anchor cannot cite an outputless source shot") { _ = try read(.array([valid]), in: [graph[0], noOutput, graph[2]]) }
    check(try read([], subject: noOutput, in: [graph[0], noOutput, graph[2]]).isEmpty, "bootstrap plan may omit anchors before outputs exist")
    let records = try read(.array([valid]))
    var corrupt = records
    let storedFrame = try JSONDecoder().decode(JSONValue.self, from: records[0].sourceFrame)
    corrupt[0].sourceFrame = try changed(storedFrame, ["recipe_pin"], "private").encodedData()
    rejected("even stale stored anchors cannot expose unknown source-frame fields through json") {
        _ = try AIFilmProductionAnchorReader.json(corrupt[0])
    }
    corrupt = records
    corrupt[0].fingerprint = String(repeating: "0", count: 64)
    rejected("persisted mismatched fingerprint fails closed") {
        try AIFilmProductionAnchorReader.validate(corrupt, shot: current, graph: graph, state: state, allowedImages: approved)
    }
    corrupt = records
    corrupt[0].sourceFrame = Data("{broken".utf8)
    rejected("persisted corrupt native metadata fails closed") {
        try AIFilmProductionAnchorReader.validate(corrupt, shot: current, graph: graph, state: state, allowedImages: approved)
    }
    var changedState = state
    changedState.mainClips[1].sourceDuration = 8
    rejected("trim after anchoring invalidates source-frame evidence") {
        try AIFilmProductionAnchorReader.validate(records, shot: current, graph: graph, state: changedState, allowedImages: approved)
    }
    try Data("source replaced with a different identity and byte count".utf8).write(to: fixture.source)
    rejected("source replacement after anchoring fails current-authority validation") {
        try AIFilmProductionAnchorReader.validate(records, shot: current, graph: graph, state: state, allowedImages: approved)
    }
}
