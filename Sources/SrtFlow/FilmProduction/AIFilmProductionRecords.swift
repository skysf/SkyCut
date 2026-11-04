import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 工程中的外层制作值同样有边界，不能因为绕过 MCP 作者入口就携带无界/不合法证据。
// 只验持久值形状与引用关系；旧观察/旧锚点可以过期，磁盘当前性和成片观察由相应适配器判断。
enum AIFilmProductionRecords {
    typealias Plan = FilmProductionState

    static func validate(_ production: Plan, graph: [AIFilmProductionGraph.Shot]) throws {
        let ids = Set(graph.map { $0.film.shot.id })
        for shot in production.shots {
            if let binding = shot.boundSourceFingerprint { try fingerprint(binding) }
            if shot.outputClipID == nil, shot.boundSourceFingerprint != nil { throw error("An unbound shot has no output binding.") }
            if let review = shot.review { try validate(review) }
            guard shot.anchors.count <= 2, Set(shot.anchors.map(\.role)).count == shot.anchors.count else {
                throw error("At most one historical source anchor per frame input role is allowed.")
            }
            for anchor in shot.anchors {
                try text(anchor.fromShotID, maximum: 80)
                try fingerprint(anchor.fingerprint)
                try SkyStudioFilmInputs.validate(["image_url": .string(anchor.assetURL.absoluteString)], kind: "image", params: [:])
                guard anchor.sourceFrame.count <= 32_768 else { throw error("Source-frame evidence is too large.") }
                _ = try SourceFrameReader.read(JSONDecoder().decode(JSONValue.self, from: anchor.sourceFrame))
            }
        }
        guard production.soundCues.count <= 400, Set(production.soundCues.map(\.id)).count == production.soundCues.count else {
            throw error("Cue ids must be distinct in a bounded spotting plan.")
        }
        for cue in production.soundCues {
            try text(cue.id, maximum: 80)
            try text(cue.purpose, maximum: 400)
            guard !cue.shotIDs.isEmpty, cue.shotIDs.count <= 100, Set(cue.shotIDs).count == cue.shotIDs.count,
                  Set(cue.shotIDs).isSubset(of: ids) else { throw error("Sound cues must reference distinct existing shots.") }
            try seconds(cue.at)
            try seconds(cue.duration)
            guard cue.duration > 0, cue.at + cue.duration <= 86_400 else { throw error("Cue duration/end is outside the supported timeline.") }
            if let action = cue.actionID { try actionID(action) }
            if cue.layer == .foley {
                guard cue.shotIDs.count == 1, let action = cue.actionID,
                      graph.first(where: { $0.film.shot.id == cue.shotIDs[0] })?.film.shot.actions.contains(action) == true else {
                    throw error("Foley targets one new visible action, not a completed entry action.")
                }
            }
            if let reason = cue.silenceReason { try text(reason, maximum: 400) }
            if let recovery = cue.recoveryAt { try seconds(recovery) }
            if cue.layer == .silence {
                guard cue.silenceReason != nil, let recovery = cue.recoveryAt, abs(recovery - cue.at - cue.duration) < 0.001,
                      cue.audioClipID == nil else { throw error("Silence needs an explicit reason and recovery at its end, without an audio binding.") }
            }
            if let alignment = cue.alignment {
                try fingerprint(alignment.fingerprint)
                if let note = alignment.measuredNote { try text(note, maximum: 400) }
                if let note = alignment.listenedNote { try text(note, maximum: 400) }
            }
        }
    }

    private static func validate(_ review: Plan.OutputReview) throws {
        try times(review.sourceTimes)
        try text(review.notes, maximum: 1000)
        try fingerprint(review.sourceFingerprint)
        guard review.actionSamples.count <= 24, Set(review.actionSamples.map(\.actionID)).count == review.actionSamples.count else {
            throw error("Action sample records must be bounded and distinct.")
        }
        for action in review.actionSamples {
            try actionID(action.actionID)
            try times(action.sourceTimes)
            try text(action.notes, maximum: 400)
        }
        for seam in [review.previous, review.next].compactMap({ $0 }) {
            try times(seam.timelineTimes)
            try text(seam.notes, maximum: 1000)
            try fingerprint(seam.fingerprint)
        }
    }

    static func fingerprint(_ value: String) throws {
        guard value.count == 64, value.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw error("Snapshot fingerprints must be exactly 64 lower-case hexadecimal characters.")
        }
    }

    private static func actionID(_ value: String) throws {
        guard value.range(of: #"\A[a-z0-9_-]{1,48}\z"#, options: .regularExpression) != nil else { throw error("Invalid action id in stored evidence.") }
    }

    private static func times(_ values: [Double]) throws {
        guard values.count <= 128, values == Array(Set(values)).sorted() else { throw error("Stored sample requests must be bounded, distinct and ordered.") }
        try values.forEach(seconds)
    }

    private static func seconds(_ value: Double) throws {
        guard value.isFinite, value >= 0, value <= 86_400 else { throw error("Stored timeline seconds must be finite and bounded.") }
    }

    private static func text(_ value: String, maximum: Int) throws {
        _ = try SkyStudioFilmReader.text(.string(value), at: "production", maximum: maximum)
    }

    private static func error(_ message: String) -> SkyStudioFilmError { SkyStudioFilmReader.error("production", message) }
}
