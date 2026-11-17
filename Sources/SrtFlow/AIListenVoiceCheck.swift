import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - listen voice=…: is each line of the narration covered? (MCP-39; the job and where things come from)
//
// What: the plan (AIListenVoicePlan: which tracks are the voice, every other audible track as a candidate masker, the voice
// clips inside from / to), what each clip is from where it came (`provenance`: our voice-overs and sound effects by the
// folder SkyCut wrote them to, in any interface language; library music and effects by their manifest id; generated audio),
// then the measurement as a listen job (`AIListenMix.queued`: AIJobs, the mix lane, MediaReadQueue.export, 20 s inline) —
// AIListenVoiceMeasure renders and measures, AIListenVoiceReport writes. Read-only: no edit, no undo, never the preview's
// engine (docs/architecture/audio-engine.md section 2 item 11).
// Not here: any of those steps' rules (their files), the lines (VoiceClarity).

@MainActor
enum AIListenVoiceCheck {
    static func listen(_ args: AIToolArguments, _ project: VideoEditProject, spec: String, from: Double?, to: Double?) async throws -> AIToolResult {
        guard try args.string("file") == nil, try args.string("clip_id") == nil else {
            throw AIToolError("voice checks the timeline's voice tracks: leave file and clip_id out (from/to narrow it).")
        }
        guard try !(args.bool("mix") ?? false), try !(args.bool("beats") ?? false), try !(args.bool("cuts") ?? false),
              try !(args.bool("describe") ?? false) else {
            throw AIToolError("voice is its own check: call listen again for mix, describe, beats or cuts.")
        }
        guard try args.stringArray("layers") == nil, try !(args.bool("frames") ?? false) else {
            throw AIToolError("layers and frames go with mix=true; voice takes the voice and every other track as its layers.")
        }
        let state = project.state
        let layout = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        guard layout.hasSound else { throw AIToolError("Nothing on the timeline has sound.") }
        let plan = try AIListenVoicePlan.make(spec, state: state, config: layout, from: from, to: to, provenance: provenance())
        let ids = AIShortIDs(state: state)
        let shortIDs = Dictionary(plan.clips.map { ($0.id, ids.short($0.id)) }) { first, _ in first }
        return try await AIListenMix.queued(state, failure: "Could not check the voice") { config, token, progress in
            let lines = try AIListenVoiceMeasure.measure(plan, config: config, isCancelled: { token.isCancelled }) {
                progress.update(fraction: $0)
            }
            return .object(AIListenVoiceReport.json(lines, plan: plan, shortIDs: shortIDs))
        }
    }

    /// What SkyCut knows about where a clip's sound came from.
    static func provenance() -> AIListenVoicePlan.Provenance {
        var library: [String: AIListenVoicePlan.Kind] = [:]
        for item in AudioLibraryLookup.loadedItems { library[item.id] = item.kind == .sfx ? .effects : .music }
        // The folders AIWorkspace.Output writes to, under every interface language's name (a project made in Chinese keeps 配音).
        var folders: [String: AIListenVoicePlan.Kind] = [:]
        for (key, kind) in [("Voiceovers", AIListenVoicePlan.Kind.voice), ("Sound Effects", .effects), ("Generated", .music)] {
            for language in AppLanguage.allCases {
                folders[language.bundle.localizedString(forKey: key, value: key, table: nil)] = kind
            }
        }
        return AIListenVoicePlan.Provenance(library: library, folders: folders)
    }
}
