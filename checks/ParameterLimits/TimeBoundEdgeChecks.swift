import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Two edges of the time bound, through the real router on TimeBoundChecks' background project
// (docs/bugfixes/2026-11-19-time-bound-refuses-relative-keyframes-and-timeline-end.md):
// - a timeline the tools themselves ran past the day (a 2 s text at 86,400 s) keeps every time inside it usable: a seek to its
//   end lands there, a look inside it answers, the text moves inside it; a time past its end is refused with that end as the
//   maximum;
// - set_keyframes with relative: true takes fractions a hair outside 0–1 (-0.0005, 1.0005; also relative written as "true"),
//   which AIKeyframes clamps to the clip's edges, and refuses one outside -0.001…1.001 with that range, changing nothing.
// Before the fix the router refused the first group (the day bound for every time) and the fractions below 0 (the seconds
// bound), and left the fractions above 1.001 to the tool's plain-text refusal.
@MainActor enum TimeBoundEdgeChecks {
    typealias Check = TimeBoundChecks.Check

    static func run(_ f: TimeBoundFixture) async -> [Check] {
        let past = await pastTheDay(f)
        return past + (await relativeFractions(f))
    }

    private static func pastTheDay(_ f: TimeBoundFixture) async -> [Check] {
        let before = f.project.state
        let day = MCPTimeArguments.maximumSeconds
        let added = await f.call(.setText, ["text": "Late", "start": .number(day), "duration": 2])
        let end = f.project.state.duration
        var checks: [Check] = [(added["isError"] != true && abs(end - (day + 2)) < 0.001,
                                "a 2 s text at 86400 s runs the timeline to 86402 s: \(end) \(text(added).prefix(160))")]
        let seek = await f.call(.seek, ["time": .number(end)])
        checks.append((seek["isError"] != true && abs(f.project.clock.time - end) < 0.001,
                       "a seek to the end the tools made lands there: \(text(seek).prefix(200))"))
        let look = await f.call(.look, ["time": .number(day + 1), "size": "small", "image": false])
        checks.append((look["isError"] != true, "a look at 86401 s, inside the timeline, answers: \(text(look).prefix(200))"))
        if let late = f.project.state.textOverlays.first(where: { abs($0.timelineStart - day) < 0.001 }) {
            let id = AIShortIDs(state: f.project.state).short(late.id)
            let moved = await f.call(.setText, ["text_id": .string(id), "start": .number(day + 0.5)])
            let start = f.project.state.textOverlays.first { $0.id == late.id }?.timelineStart ?? -1
            checks.append((moved["isError"] != true && abs(start - (day + 0.5)) < 0.001,
                           "the text moves to 86400.5 s, inside the timeline: \(start) \(text(moved).prefix(200))"))
        } else {
            checks.append((false, "the 86400 s text is on the timeline"))
        }
        let farEnd = f.project.state.duration
        let past = await f.call(.seek, ["time": .number(farEnd + 0.5)])
        let payload = decoded(past)
        checks.append((past["isError"] == true && payload?["allowed"]?["maximum"]?.doubleValue == farEnd,
                       "a time past the project's own end is refused with that end as the maximum: \(text(past).prefix(240))"))
        f.reset(before)
        return checks
    }

    private static func relativeFractions(_ f: TimeBoundFixture) async -> [Check] {
        let before = f.project.state
        let clip = JSONValue.string(AIShortIDs(state: before).short(before.mainClips[0].id))
        var checks: [Check] = []
        for relative: JSONValue in [true, "true"] {
            let reply = await f.call(.setKeyframes, ["clip_id": clip, "relative": relative,
                                                     "scale": [["time": -0.0005, "value": 1], ["time": 1.0005, "value": 1.1]]])
            let edited = f.project.state.mainClips[0]
            let keys = edited.animation?.width.keys ?? []
            let onEdges = keys.count == 2 && abs((keys.first?.time ?? -1) - edited.sourceRange.lowerBound) < 1e-6
                && abs((keys.last?.time ?? -1) - edited.sourceRange.upperBound) < 1e-6
            checks.append((reply["isError"] != true && onEdges && f.undo.canUndo,
                           "relative \(relative.encodedString()): fractions -0.0005 and 1.0005 land on the clip's edges: \(text(reply).prefix(200))"))
            f.reset(before)
        }
        for fraction in [-0.002, 1.002, 1e20] {
            let reply = await f.call(.setKeyframes, ["clip_id": clip, "relative": true, "scale": [["time": .number(fraction), "value": 1]]])
            let payload = decoded(reply)
            checks.append((reply["isError"] == true && payload?["status"] == "invalid_parameter" && payload?["parameter"] == "scale[0].time"
                            && payload?["allowed"]?["minimum"]?.doubleValue == -0.001 && payload?["allowed"]?["maximum"]?.doubleValue == 1.001
                            && f.project.state == before && !f.undo.canUndo,
                           "relative fraction \(fraction) is refused with -0.001…1.001 and changes nothing: \(text(reply).prefix(200))"))
            if f.project.state != before { f.reset(before) }
        }
        return checks
    }

    private static func text(_ reply: JSONValue) -> String {
        reply["content"]?.arrayValue?.first?["text"]?.stringValue ?? "\(reply)"
    }

    private static func decoded(_ reply: JSONValue) -> JSONValue? {
        try? JSONValue.decode(Data(text(reply).utf8))
    }
}
