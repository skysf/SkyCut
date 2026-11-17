import Foundation
import SrtFlowCore

// The registry is the extension point for later delivery checks. Preparation owns media reads;
// each check consumes one frozen context and returns suspects without editing or vetoing export.
@MainActor
enum AIDeliveryChecks {
    struct Context {
        var state: TimelineState
        var scope: AIInspection.Scope
        var style: BurnInStyle
        var config: AudioEngineConfig
        var measurement: AIInspectionMeasurement.Outcome
        var spoken: [AIDeliverySentences.Spoken]
        var picture: [AIInspection.Finding]
        var sourceSpeech: [AIInspection.Finding]
        var attention: String?
        var silenceDB: Double
        var minimum: Double
        var file: Bool
    }
    struct Check {
        var id: String
        var run: (Context) async throws -> [AIInspection.Finding]
    }
    static let registry: [Check] = [
        Check(id: "picture", run: { $0.picture }),
        Check(id: "source_speech", run: { $0.sourceSpeech }),
        Check(id: "subtitles", run: { AIInspection.subtitles($0.state, style: $0.style, scope: $0.scope) }),
        Check(id: "overlaps", run: { AIInspection.overlaps($0.config, scope: $0.scope) }),
        Check(id: "mix", run: {
            var findings = AIDeliveryMix.findings($0.measurement.frames, scope: $0.scope, silenceDB: $0.silenceDB,
                                                minSilence: $0.minimum, file: $0.file)
            if $0.file {
                findings += AIDeliveryMix.findings($0.measurement.timeline, scope: $0.scope, silenceDB: $0.silenceDB,
                                                  minSilence: $0.minimum, file: false).filter { $0.kind == "audio_limiter" }
            }
            return findings
        }),
        Check(id: "sentences", run: { AIDeliverySentences.findings($0.spoken, state: $0.state, scope: $0.scope, config: $0.config) }),
        Check(id: "freshness", run: {
            guard let attention = $0.attention else { return [] }
            return [.init(kind: "stale_export", from: 0, to: $0.state.duration, reason: attention)]
        })
    ]

    static func run(_ context: Context) async throws -> [AIInspection.Finding] {
        var findings: [AIInspection.Finding] = []
        for check in registry { findings += try await check.run(context) }
        return findings.map { raw in
            var finding = raw
            let audio = finding.kind.hasPrefix("audio_") || finding.kind == "sentence_cut"
            if audio {
                let involved = context.config.tracks.flatMap(\.segments).filter {
                    $0.start <= finding.to && $0.end + ($0.scene == nil ? 0 : SceneRecipe.maximumTail) >= finding.from
                }.map(\.clipID)
                finding.contextItems = involved
                if finding.items.isEmpty { finding.items = involved }
            }
            if finding.items.isEmpty {
                if !audio {
                    finding.items = AIInspectionPicture.visiblePictures(context.state, from: finding.from,
                        to: max(finding.to, finding.from + context.state.frameRate.secondsPerFrame)).map(\.id)
                }
            }
            finding.items = Array(Set(finding.items)).sorted { $0.uuidString < $1.uuidString }
            let layers = finding.items.compactMap { id -> String? in
                if let track = context.state.location(of: id)?.track { return AITrackName.name(of: track) }
                return context.state.subtitleTrack(of: id).map { $0 == .original ? "S1" : "S2" }
            }
            finding.details["layers"] = .array(Array(Set(layers)).sorted().map { .string($0) })
            if audio {
                finding.details["loudest_layers"] = AIDeliveryMix.loudest(finding, frames: context.measurement.timeline)
                finding.details["layer_measurement"] = .string(context.file ? "timeline snapshot, not inferred from the export" : "timeline snapshot")
            }
            return finding
        }.sorted { $0.from == $1.from ? $0.kind < $1.kind : $0.from < $1.from }
    }
}
