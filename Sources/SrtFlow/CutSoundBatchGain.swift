import Foundation
import SrtFlowMCPKit

// Solves all automatic gain joins together. Each sound receives one whole-clip attenuation, so a later cut cannot undo
// an earlier match. Reuses single-cut validation / measurement; owns neither media reads nor explicit gain requests.
enum CutSoundBatchGain {
    private struct Edge {
        let other: UUID
        let difference: Double
    }

    static func run(
        _ request: CutSoundRequest, cuts: [CutSoundCut], inputs: [CutSoundPlanner.Inputs], skipsSilent: Bool,
        in state: inout TimelineState
    ) throws -> (outcomes: [CutSoundOutcome], skipped: [UUID]) {
        let collected = try collect(request, cuts: cuts, inputs: inputs, skipsSilent: skipsSilent, original: state)
        let shifts = try attenuations(collected.graph)
        var next = state
        for (id, shift) in shifts where abs(shift) > 1e-9 { next.update(id) { $0.shiftWholeVolume(byDecibels: shift) } }
        let outcomes = collected.outcomes.map { report($0, shifts: shifts, original: state, next: next) }
        state = next
        return (outcomes, collected.skipped)
    }

    private static func collect(
        _ request: CutSoundRequest, cuts: [CutSoundCut], inputs: [CutSoundPlanner.Inputs], skipsSilent: Bool, original: TimelineState
    ) throws -> (outcomes: [CutSoundOutcome], skipped: [UUID], graph: [UUID: [Edge]]) {
        var outcomes: [CutSoundOutcome] = []
        var skipped: [UUID] = []
        var graph: [UUID: [Edge]] = [:]
        for (index, cut) in cuts.enumerated() {
            let input = inputs.indices.contains(index) ? inputs[index] : CutSoundPlanner.Inputs()
            var scratch = original
            do {
                let outcome = try CutSoundPlanner.apply(request, at: cut, layer: input.layer, material: input.material,
                                                       beats: input.beats, original: original, in: &scratch)
                guard let out = outcome.outgoing, let into = outcome.incoming,
                      let outLevel = outcome.levels?.outgoing, let inLevel = outcome.levels?.incoming else {
                    throw AIToolError("Both sides need measured sound levels. Nothing was changed.")
                }
                graph[out, default: []].append(Edge(other: into, difference: outLevel - inLevel))
                graph[into, default: []].append(Edge(other: out, difference: inLevel - outLevel))
                outcomes.append(outcome)
            } catch let error as AIToolError where skipsSilent && error.details["status"]?.stringValue == CutSoundPlanner.noSoundStatus {
                skipped.append(cut.outgoing.id)
            } catch let error as AIToolError {
                throw AIToolError("Cut after \(cut.outgoing.name) (\(index + 1) of \(cuts.count)): \(error.message)", details: error.details)
            }
        }
        guard !outcomes.isEmpty else {
            throw AIToolError("None of these cuts has sound on the side this join needs. Nothing was changed.")
        }
        return (outcomes, skipped, graph)
    }

    private static func report(
        _ initial: CutSoundOutcome, shifts: [UUID: Double], original: TimelineState, next: TimelineState
    ) -> CutSoundOutcome {
        var outcome = initial
        outcome.gains = []
        var finalLevels: [Double] = []
        var reported: Set<UUID> = []
        for (id, time, level) in [
            (outcome.outgoing, outcome.cut.time - CutSoundWindows.middle, outcome.levels?.outgoing),
            (outcome.incoming, outcome.cut.time + CutSoundWindows.middle, outcome.levels?.incoming)
        ] {
            guard let id, let before = original.clip(with: id), let after = next.clip(with: id), let level else { continue }
            let applied = after.volumeLineDecibels(atTimeline: time) - before.volumeLineDecibels(atTimeline: time)
            let requested = shifts[id] ?? 0
            if abs(requested) > 1e-9, reported.insert(id).inserted { outcome.gains.append(.init(clip: id, requested: requested, applied: applied)) }
            finalLevels.append(level + applied)
        }
        if finalLevels.count == 2, abs(finalLevels[0] - finalLevels[1]) > 0.05 {
            outcome.notes.append("The volume limit leaves a \(String(format: "%.2f", abs(finalLevels[0] - finalLevels[1]))) dB difference at this cut; the sides are not fully matched.")
        }
        return outcome
    }

    private static func attenuations(_ graph: [UUID: [Edge]]) throws -> [UUID: Double] {
        var shifts: [UUID: Double] = [:]
        for start in graph.keys.sorted(by: { $0.uuidString < $1.uuidString }) where shifts[start] == nil {
            var offsets = [start: 0.0]
            var queue = [start]
            var cursor = 0
            while cursor < queue.count {
                let id = queue[cursor]
                cursor += 1
                for edge in graph[id] ?? [] {
                    let offset = offsets[id]! + edge.difference
                    if let known = offsets[edge.other] {
                        guard abs(known - offset) <= 1e-6 else {
                            throw AIToolError("These cuts require conflicting whole-clip gains for shared sound. Match them separately with gain_db or a volume curve. Nothing was changed.")
                        }
                    } else {
                        offsets[edge.other] = offset
                        queue.append(edge.other)
                    }
                }
            }
            let highest = offsets.values.max() ?? 0
            for (id, offset) in offsets { shifts[id] = offset - highest }
        }
        return shifts
    }
}
