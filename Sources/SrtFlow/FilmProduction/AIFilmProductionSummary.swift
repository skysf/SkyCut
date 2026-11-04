import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// get_timeline 的制作区块：作者计划、当前应引用的快照，以及当前证据的派生待办各自列出。
// 文件属性由快照读，因此调用方放到 MediaReadQueue；不改变存盘值，不在回读时续期任何证据。
enum AIFilmProductionSummary {
    static func make(_ state: TimelineState, allowedImages: Set<URL> = []) -> JSONValue {
        guard let production = state.production else { return .null }
        do {
            let graph = try AIFilmProductionGraph.decode(production)
            let plan = try AIFilmProductionJSON.plan(production, graph: graph, ids: AIShortIDs(state: state))
            var expected: [JSONValue] = []
            for (index, shot) in graph.enumerated() {
                var row: [String: JSONValue] = ["shot_id": .string(shot.film.shot.id)]
                if let source = try? AIFilmProductionSnapshot.authoredSource(shot, state: state) {
                    row["source_snapshot"] = .string(AIFilmProductionSnapshot.fingerprint(source))
                    if let id = shot.record.outputClipID, let actual = try? AIFilmProductionSnapshot.source(id, state: state, picture: true) {
                        row["output_binding"] = .string(AIFilmProductionSnapshot.fingerprint(actual))
                        if let clip = state.clip(with: id) { row["source_geometry"] = sourceGeometry(clip, state: state) }
                    }
                }
                for side in ["previous", "next"] {
                    let neighbor = index + (side == "previous" ? -1 : 1)
                    guard graph.indices.contains(neighbor) else { continue }
                    let left = graph[side == "previous" ? neighbor : index], right = graph[side == "previous" ? index : neighbor]
                    if let seam = try? AIFilmProductionSnapshot.authoredSeam(left, right, state: state) {
                        row[side + "_snapshot"] = .string(AIFilmProductionSnapshot.fingerprint(seam))
                        if let a = left.record.outputClipID.flatMap({ state.clip(with: $0) }),
                           let b = right.record.outputClipID.flatMap({ state.clip(with: $0) }) {
                            let times = AIFilmProductionSamples.seamRequests(left: AIFilmProductionReadiness.window(a, state: state),
                                                                          right: AIFilmProductionReadiness.window(b, state: state))
                            row[side + "_timeline_times"] = .array(times.map(JSONValue.number))
                        }
                    }
                }
                expected.append(.object(row))
            }
            let cues: [JSONValue] = production.soundCues.map { cue in
                var row: [String: JSONValue] = ["id": .string(cue.id)]
                if let snapshot = try? AIFilmProductionSnapshot.cue(cue, shots: graph, state: state) {
                    row["snapshot"] = .string(AIFilmProductionSnapshot.fingerprint(snapshot))
                }
                return .object(row)
            }
            return ["revision": .number(Double(production.revision)), "plan": plan,
                    "expected_snapshots": ["shots": .array(expected), "sound_cues": .array(cues)],
                    "readiness": AIFilmProductionReadiness.inspect(production, shots: graph, state: state, allowedImages: allowedImages),
                    "evidence_kind": "caller_authored_observations", "saving_plan_does_not_generate_media": true,
                    "catalog_status": "not_revalidated_by_get_timeline"]
        } catch {
            return ["revision": .number(Double(production.revision)), "status": "invalid_stored_production",
                    "message": .string(error.localizedDescription), "official_generation_allowed": false]
        }
    }

    // 只回读原始 Double 和共用工程帧格，不 stat/解码；普通时间线的三位小数不能用于重建原生锚点。
    // 首尾仍是请求时刻，actualTime 只能来自随后在自有 scratch 工程执行的 freeze_frame。
    static func sourceGeometry(_ clip: EditClip, state: TimelineState) -> JSONValue {
        guard !clip.isStillImage, !clip.needsStillConversion else { return .null }
        let window = AIFilmProductionReadiness.window(clip, state: state)
        let bounds = window.projectBounds
        return ["source_file": .string(clip.sourceURL.standardizedFileURL.path),
                "source_in": .number(clip.sourceStart), "source_out": .number(clip.sourceStart + clip.sourceDuration),
                "source_duration": .number(clip.sourceDuration), "speed": .number(clip.speed),
                "timeline_start": .number(clip.timelineStart), "fps": .number(Double(state.frameRate.fps)),
                "first_project_time": bounds.map { .number($0.lowerBound) } ?? .null,
                "last_project_time": bounds.map { .number($0.upperBound) } ?? .null]
    }
}
