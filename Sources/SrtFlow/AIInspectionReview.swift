import CryptoKit
import Foundation
import SrtFlowMCPKit

// Stable finding identities and explicit review mutations. Inspection itself only reads these
// decisions. Reports are bounded, session-owned snapshots; a stale report cannot approve new work.
@MainActor
enum AIInspectionReview {
    struct Report {
        var generation: Int
        var session: String?
        var state: TimelineState
        var candidates: [String: DeliveryFindingAnchor]
    }
    static var reports: [String: Report] = [:]
    static var order: [String] = []

    static func anchor(_ finding: AIInspection.Finding, state: TimelineState) -> DeliveryFindingAnchor {
        let items = finding.items.sorted { $0.uuidString < $1.uuidString }
        let reference = items.compactMap(state.clip(with:)).first
        let related = Array(Set(items + finding.contextItems)).sorted { $0.uuidString < $1.uuidString }
        var context: [String] = [finding.kind]
        for id in related {
            if var clip = state.clip(with: id) {
                // Position and trim endpoints belong to the anchor, not the content fingerprint.
                let relative = reference.map { clip.sourceTime(atTimeline: $0.timelineStart) } ?? clip.sourceStart
                clip.timelineStart = 0
                clip.sourceStart = clip.id == reference?.id ? 0 : (relative * 1_000_000).rounded() / 1_000_000
                clip.sourceDuration = 0
                clip.info = nil
                clip.audioAssetDuration = nil
                clip.markers = []
                context.append(encoded(clip))
            } else {
                let cues = state.subtitleCues(of: .original) + state.subtitleCues(of: .translation)
                if let cue = cues.first(where: { $0.id == id }) { context.append(cue.text) }
            }
        }
        context.append(encoded(state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)))
        if finding.kind.hasPrefix("audio_") || finding.kind == "sentence_cut" {
            context += [String(state.masterVolume), String(state.mainVolume), encoded(state.audioTracks.map(\.volume)),
                        encoded(state.overlayTracks.map(\.volume))]
        }
        let from = reference?.sourceTime(atTimeline: finding.from) ?? finding.from
        let to = reference?.sourceTime(atTimeline: finding.to) ?? finding.to
        return DeliveryFindingAnchor(kind: finding.kind, items: items, reference: reference?.id, from: from, to: to,
                                     tolerance: state.frameRate.secondsPerFrame * 2 * (reference?.speed ?? 1),
                                     context: digest(context.joined(separator: "\n")))
    }

    static func partition(_ findings: [AIInspection.Finding], state: TimelineState, job: String, generation: Int,
                          session: String?) -> (findings: [AIInspection.Finding], intentional: [JSONValue]) {
        var pending: [AIInspection.Finding] = [], intentional: [JSONValue] = []
        var candidates: [String: DeliveryFindingAnchor] = [:]
        var matched = Set<String>()
        var seen = Set<String>()
        let ids = AIShortIDs(state: state)
        for var finding in findings {
            let anchor = anchor(finding, state: state)
            guard seen.insert(anchor.key).inserted else { continue }
            finding.details["key"] = .string(anchor.key)
            candidates[anchor.key] = anchor
            if let mark = state.deliveryIntentions.filter({ !matched.contains($0.key) && $0.anchor.matches(anchor) }).min(by: {
                abs($0.anchor.from - anchor.from) + abs($0.anchor.to - anchor.to)
                    < abs($1.anchor.from - anchor.from) + abs($1.anchor.to - anchor.to)
            }) {
                candidates[mark.key] = anchor
                var json = finding.json(ids: ids).objectValue ?? [:]
                json["key"] = .string(mark.key)
                json["intentional_reason"] = .string(mark.reason)
                json["reproduced"] = true
                matched.insert(mark.key)
                intentional.append(.object(json))
            } else { pending.append(finding) }
        }
        for mark in state.deliveryIntentions where !matched.contains(mark.key) {
            let reference = mark.anchor.reference.flatMap(state.clip(with:))
            intentional.append(["key": .string(mark.key), "kind": .string(mark.anchor.kind),
                "from": .number(reference?.timelineTime(atSource: mark.anchor.from) ?? mark.anchor.from),
                "to": .number(reference?.timelineTime(atSource: mark.anchor.to) ?? mark.anchor.to),
                "items": .array(mark.anchor.items.map { .string(ids.short($0)) }),
                "intentional_reason": .string(mark.reason), "reproduced": false,
                "note": "Saved decision not matched in this report's checked range; it did not suppress any finding."])
        }
        // Retain only completed reports from this run, never project files or arbitrary supplied keys.
        reports[job] = Report(generation: generation, session: session, state: state, candidates: candidates)
        order.append(job)
        while order.count > 24 { reports.removeValue(forKey: order.removeFirst()) }
        return (pending, intentional)
    }

    static func change(_ args: AIToolArguments, project: VideoEditProject) throws -> AIToolResult? {
        let mark = args.has("intentional") ? args.raw["intentional"] : nil
        if let mark, mark.objectValue == nil { throw AIToolError("intentional must be an object with job_id, key and reason.") }
        let clear = try args.string("clear_intentional")
        guard mark != nil || clear != nil else { return nil }
        guard mark == nil || clear == nil else { throw AIToolError("Use intentional or clear_intentional, not both.") }
        for field in ["file", "from", "to", "silence_db", "min_silence", "image", "sounds"] where args.has(field) {
            throw AIToolError("Reviewing a finding is separate from inspecting; leave \(field) out.")
        }
        var next = project.state.deliveryIntentions
        if let mark {
            let entry = AIToolArguments(mark)
            let job = try entry.requiredString("job_id"), key = try entry.requiredString("key")
            let reason = try entry.requiredString("reason").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, reason.count <= 240, !reason.contains(where: \.isNewline) else {
                throw AIToolError("reason must be one nonempty line, at most 240 characters.")
            }
            guard AIJobs.shared.job(job)?.status == .done,
                  let report = reports[job], project.isCurrentGeneration(report.generation),
                  report.session == AICallContext.current?.session else {
                throw AIToolError("This report belongs to another project/session or has expired; inspect again.")
            }
            var current = project.state, snapshot = report.state
            current.deliveryIntentions = []; snapshot.deliveryIntentions = []
            guard current == snapshot, let anchor = report.candidates[key] else {
                throw AIToolError("The report or finding is stale; inspect the current timeline again before marking it.")
            }
            next.removeAll { $0.key == key }
            next.append(DeliveryIntentionalMark(anchor: anchor, reason: reason))
        } else if let clear {
            guard next.contains(where: { $0.key == clear }) else { throw AIToolError("No intentional mark has key \(clear).") }
            next.removeAll { $0.key == clear }
        }
        let changed = next != project.state.deliveryIntentions
        if changed {
            if AICallContext.current?.project == project.shortID {
                AISession.shared.round(for: project).beginIfNeeded(project: project)
            }
            _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform(rebuildsPreview: false) { $0.deliveryIntentions = next } }
        }
        return .ok(["changed": .bool(changed), "intentional_marks": .number(Double(next.count)),
                    "next_step": "Inspect again. Matching intentional findings are listed separately for human review."], changed: changed)
    }

    private static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
