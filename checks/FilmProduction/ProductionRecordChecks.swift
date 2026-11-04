import Foundation
import SrtFlowCore
import SrtFlowMCPKit

func productionFixture(prompt: String = "A still original room", revisions: [Int] = [1, 1, 1]) throws -> FilmProductionState {
    typealias Film = SkyStudioFilm
    let context = Film.Context(environment: .interior, lightSource: .practical, shotTask: .readAction)
    let entry = Film.State(actorPosition: "at table", hand: .right, grip: "holding lamp", propLocation: "right hand",
        actionPhase: "held", spatialRelation: "table ahead", gaze: "lamp", screenDirection: "right", lighting: "steady", completedActions: ["arrive"])
    var exit = entry
    exit.grip = "resting on handle"; exit.propLocation = "on table"; exit.actionPhase = "placed"; exit.completedActions += ["place"]
    let sound = Film.Sound(bedID: "room", music: "quiet", environment: "continuous room tone", foley: "one contact")
    let a = Film.Render(kind: .imageToVideo, model: "public-video", prompt: "A held lamp", params: ["duration": 5],
        inputs: ["image_url": "https://assets.example/originals/account/first.png"], context: context)
    var b = a; b.prompt = prompt
    var c = a; c.prompt = "The lamp stays on the table"
    let first = Film(context: context, shot: .init(id: "a", index: 0, total: 3, revision: revisions[0], entry: entry, exit: entry, actions: []),
        next: .init(shotID: "b", render: b, soundBedID: "room", cut: .continuous, state: entry), sound: sound)
    let middle = Film(context: context, shot: .init(id: "b", index: 1, total: 3, revision: revisions[1], entry: entry, exit: exit, actions: ["place"]),
        previous: .init(shotID: "a", render: a, soundBedID: "room", cut: .continuous, state: entry),
        next: .init(shotID: "c", render: c, soundBedID: "room", cut: .continuous, state: exit), sound: sound)
    let last = Film(context: context, shot: .init(id: "c", index: 2, total: 3, revision: revisions[2], entry: exit, exit: exit, actions: []),
        previous: .init(shotID: "b", render: b, soundBedID: "room", cut: .continuous, state: exit), sound: sound)
    let shots = try zip([first, middle, last], [a, b, c]).map { film, render in
        FilmProductionState.Shot(film: try film.json.encodedData(), render: try render.json.encodedData())
    }
    return .init(revision: 1, story: "An original three-shot story", shots: shots, soundCues: [])
}

func runProductionRecordChecks() throws {
    typealias Graph = AIFilmProductionGraph
    typealias Plan = FilmProductionState
    let original = try productionFixture()
    let graph = try Graph.decode(original)
    check(graph.count == 3, "complete original graph decodes")
    let roundtrip = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(original))
    check(roundtrip == original, "public Data records round-trip canonically")
    func reject(_ value: Plan, _ message: String) { do { _ = try Graph.decode(value); check(false, message) } catch { check(true, message) } }
    func film(_ index: Int, in plan: inout Plan, _ change: (inout SkyStudioFilm) -> Void) throws {
        var value = try JSONDecoder().decode(SkyStudioFilm.self, from: plan.shots[index].film)
        change(&value); plan.shots[index].film = try value.json.encodedData()
    }
    var bad = original; bad.revision = 0; reject(bad, "invalid stored production revision rejects")
    bad = original; bad.shots = []; reject(bad, "empty story graph rejects")
    bad = original; bad.story = String(repeating: "s", count: 2001); reject(bad, "story bound enforced on load")
    bad = original; try film(1, in: &bad) { $0.shot.total = 4 }; reject(bad, "authoritative total cannot diverge")
    bad = original; try film(1, in: &bad) { $0.previous!.render.prompt = "Different preceding render" }; reject(bad, "neighbor render must match authoritative row")
    bad = original; try film(0, in: &bad) { $0.next!.cut = .intentional(kind: .montage, reason: "An explicit angle cut", resetFields: [], offscreenActions: []) }; reject(bad, "both cut declarations must agree")
    bad = original; let id = UUID(); bad.shots[0].outputClipID = id; bad.shots[1].outputClipID = id; reject(bad, "one output cannot bind two shots")
    bad = original; bad.shots[0].film = Data(repeating: 32, count: 131_073); reject(bad, "stored film Data bounded before decode")
    bad = original; var raw = try JSONDecoder().decode(JSONValue.self, from: bad.shots[0].film).objectValue!; raw["unrecognized_field"] = true
    bad.shots[0].film = try JSONValue.object(raw).encodedData(); reject(bad, "stored Film unknown fields cannot bypass strict adapter")
    bad = original; var render = graph[0].render; render.context.shotTask = .readObject; bad.shots[0].render = try render.json.encodedData(); reject(bad, "current render context matches own film")
    let changed = try Graph.decode(productionFixture(prompt: "A changed original shot", revisions: [2, 2, 2]))
    do { try Graph.revisions(changed, after: graph); check(true, "changed declarations advance once") } catch { check(false, "changed revisions: \(error)") }
    do { try Graph.revisions(try Graph.decode(productionFixture(prompt: "A changed original shot")), after: graph); check(false, "changed request cannot reuse old revision") } catch { check(true, "changed request cannot reuse old revision") }
    do { try Graph.revisions(try Graph.decode(productionFixture(revisions: [2, 2, 2])), after: graph); check(false, "unchanged declaration cannot silently advance") } catch { check(true, "unchanged declaration cannot silently advance") }
    let fingerprint = String(repeating: "a", count: 64)
    bad = original; bad.shots[0].boundSourceFingerprint = fingerprint; reject(bad, "unbound record cannot claim source binding")
    bad = original; bad.shots[0].review = .init(sourceTimes: [0, 0.5], notes: "Historical observations", sourceFingerprint: fingerprint)
    check((try? Graph.decode(bad)) != nil, "well-shaped old observation can remain historical without output")
    bad.shots[0].review!.sourceTimes = [.nan]; reject(bad, "nonfinite stored sample requests reject")
    bad = original; bad.shots[0].review = .init(sourceTimes: [1, 0], notes: "Old", sourceFingerprint: fingerprint); reject(bad, "unordered stored requests reject")
    bad = original; bad.shots[0].review = .init(sourceTimes: [0], notes: "Old", sourceFingerprint: "not-a-snapshot"); reject(bad, "malformed snapshot rejects on load")
    bad = original; bad.soundCues = [.init(id: "bed", shotIDs: [], layer: .environment, purpose: "room", at: 0, duration: 15)]; reject(bad, "cue needs referenced shots")
    bad = original; bad.soundCues = [.init(id: "hit", shotIDs: ["b"], layer: .foley, purpose: "contact", at: 6, duration: 0.2, actionID: "arrive")]; reject(bad, "foley cannot replay completed entry action")
    bad.soundCues[0].actionID = "place"; check((try? Graph.decode(bad)) != nil, "new visible action can have planned foley before output")
    bad.soundCues.append(bad.soundCues[0]); reject(bad, "duplicate cue IDs reject")
    bad = original; bad.soundCues = [.init(id: "silence", shotIDs: ["b"], layer: .silence, purpose: "pause", at: 6, duration: 0.2)]; reject(bad, "silence needs reason/recovery")
    bad.soundCues[0].silenceReason = "intentional pause"; bad.soundCues[0].recoveryAt = 6.2
    check((try? Graph.decode(bad)) != nil, "explicit planned silence accepted")
    bad.soundCues[0].alignment = .init(fingerprint: fingerprint, measuredNote: "numerical sample only")
    let measured = try Graph.decode(bad)
    check(measured.count == 3 && bad.soundCues[0].alignment?.listenedNote == nil, "numeric measurement does not invent listening")
}
