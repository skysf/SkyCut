import Foundation
import SrtFlowMCPKit

// MARK: - Tool: set_track duck_others_db (duck the other tracks under this track's speech, MCP-29, 2026-11-18)
//
// Owns: the arguments (track = the voice; duck_others_db = the dip, −30…0 dB; duck_tracks = only these tracks), `plan` (await:
// the voice's lines from the transcript cache or the waveform, SpeechDuckLines) and `apply` (sync: one call = one undo step,
// as cut_speech and set_transition sound). `apply` opens the AIUndoGrouping.step itself and only when the duck changes a
// curve: a call that finds every dip already in place commits nothing and leaves no empty step behind (an empty group stays
// on the undo stack and ⌘Z would do nothing; docs/architecture/mcp-edit-parameters.md: the group opens only after a change).
// If the timeline changed in between nothing lands and the AI is asked to call again. Only curves change, so `perform` takes
// the audio-only fast path (no picture rebuild) and neither the magnet nor linkage moves anything.
// Not here: the rule and the curves (SpeechDuck, SpeechDuckCurve, SpeechDuckPlanner), the result (SpeechDuckReport), the wording
// (SrtFlowMCPKit: set_track in MCPTimelineTools, its guide topic in MCPGuideTimelineEditTopics).
// Rules: docs/architecture/audio-volume-curve.md section 5.

@MainActor
enum AISpeechDuckTool {
    struct Plan {
        var voice: TrackSlot
        var depth: Double
        var only: Set<TrackSlot>?
        var speech: SpeechDuckPlanner.Speech
        var state: TimelineState
        var generation: Int
    }

    static func plan(_ args: AIToolArguments, _ project: VideoEditProject) async throws -> Plan {
        let state = project.state
        guard !args.has("volume_db"), !args.has("hidden") else {
            throw AIToolError("Give duck_others_db in a set_track call of its own, without volume_db or hidden.")
        }
        let name = try args.requiredString("track")
        guard case .track(let voice) = try AITrackSettings.target(name, in: state) else {
            throw AIToolError("duck_others_db takes the track that speaks (A1, V1…), not master.")
        }
        guard !state.isLaneHidden(voice) else {
            throw AIToolError("\(AITrackName.name(of: voice)) is hidden, so nothing on it is heard: show it first (set_track hidden=false).")
        }
        guard let depth = try args.double("duck_others_db") else {
            throw AIToolError("duck_tracks goes with duck_others_db (the dip in dB, \(SpeechDuck.depthRange.lowerBound) to 0).")
        }
        try AIEditLimits.require("duck_others_db", depth, in: SpeechDuck.depthRange)
        let only = try tracks(args, voice: voice, state)
        let speech = try await SpeechDuckLines.find(on: voice, in: state)
        guard !speech.lines.isEmpty else { throw noLines(speech, on: voice, state) }
        return Plan(voice: voice, depth: depth, only: only, speech: speech, state: state, generation: project.documentGeneration)
    }

    static func apply(_ plan: Plan, _ project: VideoEditProject) throws -> AIToolResult {
        guard project.isCurrentGeneration(plan.generation), project.state == plan.state else {
            throw AIToolError("The timeline changed while SkyCut was finding the lines. Call set_track again.")
        }
        let windows = SpeechDuck.windows(plan.speech.lines)
        var next = plan.state
        let targets = SpeechDuckPlanner.targets(in: next, voice: plan.voice, speech: plan.speech.clips, only: plan.only)
        let outcomes = SpeechDuckPlanner.run(windows, depth: plan.depth, targets: targets, in: &next)
        let changed = next != plan.state
        if changed { _ = AIUndoGrouping.step(project.effectiveUndoManager) { project.perform { $0 = next } } }
        let ids = AIShortIDs(state: project.state)
        let result = SpeechDuckReport.json(voice: plan.voice, depth: plan.depth, speech: plan.speech, windows: windows,
                                           outcomes: outcomes, ids: ids)
        if changed {
            let clips = Set(outcomes.filter(\.changed).map(\.id))
            AIEditorPresenter.reveal(.init(clips: clips, time: windows.first.map { max(0, $0.from) }), project: project)
        }
        return .ok(result, changed: changed)
    }

    /// duck_tracks: "A2+V1" (or with commas) → those tracks; nil = every other track.
    private static func tracks(_ args: AIToolArguments, voice: TrackSlot, _ state: TimelineState) throws -> Set<TrackSlot>? {
        guard let text = try args.string("duck_tracks") else { return nil }
        let parts = text.split(whereSeparator: { $0 == "+" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        var slots: Set<TrackSlot> = []
        for part in parts where !part.isEmpty {
            guard case .track(let slot) = try AITrackSettings.target(part, in: state) else {
                throw AIToolError("duck_tracks names tracks (A2, V1…); master is not a track.")
            }
            guard slot != voice else { throw AIToolError("duck_tracks lists \(part.uppercased()), the track that speaks.") }
            slots.insert(slot)
        }
        guard !slots.isEmpty else { throw AIToolError("duck_tracks is empty: name tracks like A2+V1, or leave it out for every other track.") }
        return slots
    }

    /// Why the voice track gave no lines, and what to do.
    private static func noLines(_ speech: SpeechDuckPlanner.Speech, on voice: TrackSlot, _ state: TimelineState) -> AIToolError {
        let track = AITrackName.name(of: voice)
        let ids = AIShortIDs(state: state)
        if !speech.noTranscript.isEmpty {
            let names = speech.noTranscript.map { ids.short($0) }.joined(separator: ", ")
            return AIToolError("No lines on \(track): \(names) carry a camera's sound with no transcript yet. Call transcribe on "
                + "them first (wait with get_job), then set_track again.")
        }
        if speech.clips.isEmpty { return AIToolError("Nothing on \(track) is heard (no sound, muted or hidden), so there are no lines.") }
        if !speech.unreadable.isEmpty, speech.fromPauses.isEmpty, speech.fromTranscript.isEmpty {
            return AIToolError("SkyCut could not read the sound on \(track), so it found no lines.")
        }
        return AIToolError("No speech found on \(track): its sound stays quiet.")
    }
}
