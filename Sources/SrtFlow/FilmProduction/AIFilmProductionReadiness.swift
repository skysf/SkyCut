import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 制作计划的派生待办；所有通过项只表示调用方在当前快照上声明了证据，不宣称机器看懂/听过。
enum AIFilmProductionReadiness {
    static func window(_ clip: EditClip, state: TimelineState) -> AIFilmProductionSamples.UsedWindow {
        .init(sourceStart: clip.sourceStart, sourceDuration: clip.sourceDuration, speed: clip.speed,
              timelineStart: clip.timelineStart, fps: state.frameRate.fps)
    }

    static func inspect(_ production: FilmProductionState, shots: [AIFilmProductionGraph.Shot], state: TimelineState, allowedImages: Set<URL> = []) -> JSONValue {
        var findings: [JSONValue] = []
        for (index, shot) in shots.enumerated() {
            var reasons: [String] = []
            var required: [Double] = []
            if let id = shot.record.outputClipID, let clip = state.clip(with: id),
               let source = try? AIFilmProductionSnapshot.authoredSource(shot, state: state) {
                let fingerprint = AIFilmProductionSnapshot.fingerprint(source)
                required = window(clip, state: state).sourceRequests
                if required.isEmpty { reasons.append("no_used_project_frame") }
                let actualBinding = try? AIFilmProductionSnapshot.fingerprint(AIFilmProductionSnapshot.source(id, state: state, picture: true))
                if shot.record.boundSourceFingerprint != actualBinding { reasons.append("output_binding_changed") }
                if let review = shot.record.review, review.sourceFingerprint == fingerprint {
                    if !review.sourceTimes.allSatisfy(window(clip, state: state).containsSource)
                        || !AIFilmProductionSamples.contains(required, in: review.sourceTimes, tolerance: clip.speed / Double(state.frameRate.fps) / 2) {
                        reasons.append("early_or_tail_samples_missing")
                    }
                    for action in shot.film.shot.actions {
                        guard let samples = review.actionSamples.first(where: { $0.actionID == action }),
                              window(clip, state: state).hasActionSamples(samples.sourceTimes) else {
                            reasons.append("action_turning_samples_missing:" + action)
                            continue
                        }
                    }
                } else { reasons.append("source_review_missing_or_stale") }
                for side in ["previous", "next"] {
                    let neighborIndex = index + (side == "previous" ? -1 : 1)
                    guard shots.indices.contains(neighborIndex) else { continue }
                    let review = side == "previous" ? shot.record.review?.previous : shot.record.review?.next
                    guard let seam = try? AIFilmProductionSnapshot.authoredSeam(
                              side == "previous" ? shots[neighborIndex] : shot,
                              side == "previous" ? shot : shots[neighborIndex], state: state),
                          review?.fingerprint == AIFilmProductionSnapshot.fingerprint(seam) else {
                        reasons.append(side + "_output_seam_needs_review")
                        continue
                    }
                    let left = side == "previous" ? shots[neighborIndex] : shot
                    let right = side == "previous" ? shot : shots[neighborIndex]
                    guard let leftID = left.record.outputClipID, let rightID = right.record.outputClipID,
                          let a = state.clip(with: leftID), let b = state.clip(with: rightID), let review,
                          review.timelineTimes.allSatisfy({ $0 >= a.timelineStart && $0 < b.timelineEnd }),
                          AIFilmProductionSamples.contains(AIFilmProductionSamples.seamRequests(left: window(a, state: state), right: window(b, state: state)),
                              in: review.timelineTimes, tolerance: 0.5 / Double(state.frameRate.fps)) else {
                        reasons.append(side + "_output_seam_samples_missing")
                        continue
                    }
                }
            } else { reasons.append("output_missing_or_unusable") }
            let roles = [FilmProductionState.SourceAnchor.Role.first, .last].filter {
                shot.render.kind == .imageToVideo && shot.render.inputs[$0 == .first ? "image_url" : "last_frame_url"]?.stringValue != nil
            }
            let active = shot.record.anchors.filter { roles.contains($0.role) }
            let anchorsValid = (try? AIFilmProductionAnchorReader.validate(active, shot: shot, graph: shots, state: state, allowedImages: allowedImages)) != nil
            var requiredRoles: [String] = []
            var refreshReasons: [String] = anchorsValid ? [] : ["active_input_anchor_stale_or_invalid"]
            for role in roles {
                let hasSource = shots.contains { candidate in
                    candidate.record.outputClipID != nil && [FilmProductionState.SourceAnchor.SourceEdge.firstUsed, .lastUsed].contains {
                        AIFilmProductionAnchorReader.allowed(role: role, edge: $0, from: candidate.film.shot.id, for: shot)
                    }
                }
                if hasSource {
                    requiredRoles.append(role.rawValue)
                    if !active.contains(where: { $0.role == role }) { refreshReasons.append(role.rawValue + "_source_anchor_missing") }
                }
            }
            let anchorsCurrent = !roles.isEmpty && anchorsValid && roles.allSatisfy { role in active.contains(where: { $0.role == role }) }
            let spotting = production.soundCues.contains { $0.shotIDs.contains(shot.film.shot.id) }
            findings.append(["shot_id": .string(shot.film.shot.id), "output_observations_current": .bool(reasons.isEmpty),
                             "input_anchor_current": roles.isEmpty ? .null : .bool(anchorsCurrent),
                             "needs_refresh_for_regeneration": .bool(!refreshReasons.isEmpty),
                             "regeneration_findings": .array(refreshReasons.map(JSONValue.string)),
                             "required_input_anchor_roles": .array(requiredRoles.map(JSONValue.string)),
                             "historical_anchors_recorded": .number(Double(shot.record.anchors.count)),
                             "sound_spotting_recorded": .bool(spotting), "findings": .array(reasons.map(JSONValue.string)), "required_source_times": .array(required.map(JSONValue.number)),
                             "required_action_samples": .array(shot.film.shot.actions.map(JSONValue.string))])
        }
        var cues: [JSONValue] = []
        for cue in production.soundCues {
            let snapshot = try? AIFilmProductionSnapshot.cue(cue, shots: shots, state: state)
            let aligned = snapshot.map { AIFilmProductionSnapshot.fingerprint($0) == cue.alignment?.fingerprint } ?? false
            cues.append(["id": .string(cue.id), "needs_realign": .bool(!aligned),
                         "measured_recorded": .bool(cue.alignment?.measuredNote != nil), "listened_recorded": .bool(cue.alignment?.listenedNote != nil),
                         "measured_current": .bool(aligned && cue.alignment?.measuredNote != nil),
                         "listened_current": .bool(aligned && cue.alignment?.listenedNote != nil)])
        }
        return ["shots": .array(findings), "sound_cues": .array(cues), "evidence": "declared_by_caller",
                "preflight_is_output_review": false, "numeric_measurement_is_listening": false, "requested_sample_times_are_actual_decoded_times": false]
    }
}
