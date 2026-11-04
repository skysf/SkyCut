import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 调用方已看画面的公开证据：旧快照原样保留为过期证据，新证据只能明确引用当前快照。
// 不替调用方看视频、不把 look 的请求时刻冒充解码 actualTime，也不在 save 时静默刷新旧证据。
enum AIFilmProductionReviewReader {
    typealias Plan = FilmProductionState
    typealias Graph = AIFilmProductionGraph
    typealias Reader = AIFilmProductionReader

    static func read(_ input: JSONValue?, index: Int, graph: [Graph.Shot], previous: Plan.OutputReview?,
                     state: TimelineState) throws -> Plan.OutputReview? {
        guard let input, input != .null else { return nil }
        let path = "production.shots[\(index)].output_review"
        let value = try SkyStudioFilmReader.object(input, keys: ["source_times", "action_samples", "notes", "source_snapshot", "previous", "next"], at: path)
        let actions = try Reader.array(value["action_samples"] ?? [], path + ".action_samples", maximum: 24).enumerated().map { offset, raw in
            let p = path + ".action_samples[\(offset)]"
            let action = try SkyStudioFilmReader.object(raw, keys: ["action_id", "source_times", "notes"], at: p)
            return Plan.ActionSamples(actionID: try Reader.text(action["action_id"], p + ".action_id"),
                sourceTimes: try times(action["source_times"], p + ".source_times"), notes: try Reader.text(action["notes"], p + ".notes", maximum: 400))
        }
        guard Set(actions.map(\.actionID)).count == actions.count else {
            throw Reader.error(path + ".action_samples", "Each action needs one distinct turning-point record.")
        }
        let review = Plan.OutputReview(sourceTimes: try times(value["source_times"], path + ".source_times"),
            notes: try Reader.text(value["notes"], path + ".notes", maximum: 1000), actionSamples: actions,
            sourceFingerprint: try fingerprint(value["source_snapshot"], path + ".source_snapshot"),
            previous: try seam(value["previous"], path + ".previous"), next: try seam(value["next"], path + ".next"))
        if review == previous { return review } // 无论素材/计划是否已改，原样回读只能保住原有 fingerprint。
        let shot = graph[index]
        guard let id = shot.record.outputClipID, let clip = state.clip(with: id) else {
            throw Reader.error(path, "New output evidence requires a current bound output clip.")
        }
        let window = AIFilmProductionReadiness.window(clip, state: state)
        guard review.sourceFingerprint == AIFilmProductionSnapshot.fingerprint(try AIFilmProductionSnapshot.authoredSource(shot, state: state)),
              review.sourceTimes.allSatisfy(window.containsSource),
              AIFilmProductionSamples.contains(window.sourceRequests, in: review.sourceTimes, tolerance: clip.speed / Double(state.frameRate.fps) / 2) else {
            throw Reader.error(path, "Use the current source_snapshot and actually inspect the required early/tail used-source samples.")
        }
        guard Set(actions.map(\.actionID)) == Set(shot.film.shot.actions),
              actions.allSatisfy({ window.hasActionSamples($0.sourceTimes) }) else {
            throw Reader.error(path + ".action_samples", "Record at least two usable frame positions, at least one project-frame apart, around every new visible action's turning point.")
        }
        try checkSeam(review.previous, side: "previous", index: index, graph: graph, state: state, path: path)
        try checkSeam(review.next, side: "next", index: index, graph: graph, state: state, path: path)
        return review
    }

    private static func checkSeam(_ review: Plan.SeamReview?, side: String, index: Int, graph: [Graph.Shot],
                                  state: TimelineState, path: String) throws {
        let neighbor = index + (side == "previous" ? -1 : 1)
        guard graph.indices.contains(neighbor) else {
            guard review == nil else { throw Reader.error(path + "." + side, "There is no output cut on this side.") }
            return
        }
        guard let review else { return } // 单镜可先审查；readiness 会明确两侧仍待完成。
        let left = graph[side == "previous" ? neighbor : index], right = graph[side == "previous" ? index : neighbor]
        guard let aID = left.record.outputClipID, let bID = right.record.outputClipID,
              let a = state.clip(with: aID), let b = state.clip(with: bID) else {
            throw Reader.error(path + "." + side, "Both actual adjacent output clips are required.")
        }
        let required = AIFilmProductionSamples.seamRequests(left: AIFilmProductionReadiness.window(a, state: state),
                                                          right: AIFilmProductionReadiness.window(b, state: state))
        guard review.fingerprint == AIFilmProductionSnapshot.fingerprint(try AIFilmProductionSnapshot.authoredSeam(left, right, state: state)),
              review.timelineTimes.allSatisfy({ $0 >= a.timelineStart && $0 < b.timelineEnd }),
              AIFilmProductionSamples.contains(required, in: review.timelineTimes, tolerance: 0.5 / Double(state.frameRate.fps)) else {
            throw Reader.error(path + "." + side, "Inspect both sides of the actual composed cut and use its current expected snapshot.")
        }
    }

    private static func seam(_ input: JSONValue?, _ path: String) throws -> Plan.SeamReview? {
        guard let input, input != .null else { return nil }
        let value = try SkyStudioFilmReader.object(input, keys: ["timeline_times", "notes", "snapshot"], at: path)
        return Plan.SeamReview(timelineTimes: try times(value["timeline_times"], path + ".timeline_times"),
            notes: try Reader.text(value["notes"], path + ".notes", maximum: 1000), fingerprint: try fingerprint(value["snapshot"], path + ".snapshot"))
    }

    static func times(_ input: JSONValue?, _ path: String) throws -> [Double] {
        let values = try Reader.array(input, path, maximum: 128).map { try Reader.number($0, path) }
        guard values == Array(Set(values)).sorted() else { throw Reader.error(path, "Sample requests must be distinct and in time order.") }
        return values
    }

    static func fingerprint(_ input: JSONValue?, _ path: String) throws -> String {
        let text = try Reader.text(input, path, maximum: 64)
        try AIFilmProductionRecords.fingerprint(text)
        return text
    }
}
