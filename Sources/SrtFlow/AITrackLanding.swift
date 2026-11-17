import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - Where add_clips puts a clip that names a track (pure values)
//
// What it does, for one add_clips call (add_voiceover's lines take the same path: AITimelineEdits.place runs the loop):
// - reads the AI's track name (A1…, V1…, new_audio, new_video). An A-number past the last audio track names a track this call
//   creates, so one call can fill A1–A7 (MCP-4). Tracks are numbered without gaps: A5 with no audio tracks becomes A1 and says so.
// - puts an audio clip on the track it asked for when that track has room at that time (`AudioTracks`). Otherwise the clip opens
//   another new track (one chain per asked-for track, shared by later clips that do not fit either). It never lands on a track that
//   already had content. Before, the drop rule fell back to the first free track: two of 13 new_audio effects landed on the music
//   and voice tracks (MCP-2).
// - notes a video clip that the drop rule lifted off the track it asked for (`lifted`; video keeps that rule: stacking order), and
//   turns every note into a `track` entry for the reply's adjustments (`adjustment`).
// What it does not: the loop and the drop rule (AITimelineEdits.place, VideoEditMediaImport), audio that names no track (the first
// free audio track, as a dropped file), separated sound (ClipSoundSeparation), the other clip fields (AITimelineTools.addClips).
// Rules: docs/architecture/ai-control-mcp.md section 4 item 2; case:
// docs/bugfixes/2026-11-17-new-audio-effects-land-on-voice-and-music-tracks.md.

enum AITrackLanding {
    /// A track by identity: names shift when tracks come and go.
    enum Identity: Hashable {
        case main
        case lane(UUID)
    }

    /// Why a clip is not on the track it asked for.
    enum Reason: Equatable {
        /// Another clip sits there at that time (its id).
        case busy(UUID)
        /// The track is hidden: nothing placed there would be seen or heard.
        case hidden
    }

    struct Note: Equatable {
        var wanted: Identity
        var reason: Reason
    }

    /// The AI's track name as add_clips reads it.
    struct Request: Equatable {
        var target: TrackDropTarget
        /// A<n> past the last audio track: a track this call creates.
        var audioNumber: Int?
        /// As written, normalized: A3, V2, new_audio, new_video.
        var name: String
    }

    static func request(_ text: String, in state: TimelineState) throws -> Request {
        let written = text.trimmingCharacters(in: .whitespaces).lowercased()
        if written.first == "a", let number = Int(written.dropFirst()), number > state.audioTracks.count {
            return Request(target: .newAudioBottom, audioNumber: number, name: "A\(number)")
        }
        let target = try AITrackName.target(text, in: state)
        switch target {
        case .newAudioBottom where written.hasPrefix("new"): return Request(target: target, audioNumber: nil, name: "new_audio")
        case .newOverlayTop where written.hasPrefix("new"): return Request(target: target, audioNumber: nil, name: "new_video")
        case .main: return Request(target: target, audioNumber: nil, name: "V1")
        default: return Request(target: target, audioNumber: nil, name: written.uppercased())
        }
    }

    /// The `track` entry for the reply's adjustments when a clip is not on the track it asked for. `slot`: where it is after the
    /// whole call settled (magnet, linkage).
    static func adjustment(requested: Request, note: Note?, slot: TrackSlot, in state: TimelineState, ids: AIShortIDs) -> JSONValue? {
        let applied = AITrackName.name(of: slot)
        var entry: [String: JSONValue] = ["parameter": "track", "requested": .string(requested.name), "applied": .string(applied)]
        if let note {
            switch note.reason {
            case .busy(let other):
                entry["reason"] = "track_busy"
                if state.clip(with: other) != nil { entry["overlaps"] = .string(ids.short(other)) }
            case .hidden:
                entry["reason"] = "track_hidden"
            }
            // new_audio / new_video: name the call's new track it did not fit on.
            if let wanted = name(of: note.wanted, in: state), wanted != requested.name { entry["wanted_track"] = .string(wanted) }
            return .object(entry)
        }
        guard requested.name != applied, requested.name.hasPrefix("A") || requested.name.hasPrefix("V") else { return nil }
        entry["reason"] = .string(requested.audioNumber != nil ? "tracks_numbered_without_gaps" : "final_timeline_settlement")
        return .object(entry)
    }

    static func name(of identity: Identity, in state: TimelineState) -> String? {
        switch identity {
        case .main: return "V1"
        case .lane(let id):
            if let index = state.overlayTracks.firstIndex(where: { $0.id == id }) { return AITrackName.name(of: .overlay(index)) }
            if let index = state.audioTracks.firstIndex(where: { $0.id == id }) { return AITrackName.name(of: .audio(index)) }
            return nil
        }
    }

    /// A video clip the drop rule lifted off the track it asked for (`landing`: where the rule put it): what was in the way there.
    /// Called before the clip is inserted.
    static func lifted(from target: TrackDropTarget, to landing: MediaImportLanding?, in state: TimelineState) -> Note? {
        guard let landing, landing.target != target else { return nil }
        let span = TimelineSpan(start: landing.start, end: landing.end)
        switch target {
        case .main:
            if state.mainHidden { return Note(wanted: .main, reason: .hidden) }
            return blocker(of: span, among: state.mainClips).map { Note(wanted: .main, reason: .busy($0)) }
        case .overlay(let index) where state.overlayTracks.indices.contains(index):
            let lane = state.overlayTracks[index]
            if lane.isHidden { return Note(wanted: .lane(lane.id), reason: .hidden) }
            return blocker(of: span, among: lane.clips).map { Note(wanted: .lane(lane.id), reason: .busy($0)) }
        default:
            return nil
        }
    }

    /// The first clip overlapping `span` (the same 1 ms tolerance as `TimelineState.fits`).
    static func blocker(of span: TimelineSpan, among clips: [EditClip]) -> UUID? {
        clips.first { $0.timelineStart < span.end - 0.001 && span.start < $0.timelineEnd - 0.001 }?.id
    }

    static func fits(_ clip: EditClip, _ lane: EditLane) -> Bool {
        blocker(of: TimelineSpan(start: clip.timelineStart, end: clip.timelineEnd), among: lane.clips) == nil
    }

    /// One call's audio tracks: the track each request lands on, and the new tracks opened for clips that did not fit there.
    struct AudioTracks {
        enum Key: Hashable {
            /// An audio track that existed when the call started.
            case existing(UUID)
            /// A<n> past the last audio track: created by this call.
            case numbered(Int)
            /// new_audio: one new track for the whole call. Only a clip that asked for it lands there: a clip that named no
            /// track and opened A1 because there was none is not it (docs/bugfixes/2026-09-28-new-audio-lands-on-a1.md).
            case fresh
        }

        /// Audio tracks when the call started, A1 first.
        private let existing: [UUID]
        private var homes: [Key: UUID] = [:]
        private var numbers: [Int] = []
        private var spills: [Key: [UUID]] = [:]

        init(_ state: TimelineState) { existing = state.audioTracks.map(\.id) }

        /// nil: the clip names no audio track (it takes the first free one, as a dropped file does).
        func key(for plan: AITimelineEdits.PlannedClip) -> Key? {
            if let number = plan.audioNumber { return .numbered(number) }
            switch plan.target {
            case .audio(let index)? where existing.indices.contains(index): return .existing(existing[index])
            case .newAudioBottom?: return .fresh
            default: return nil
            }
        }

        /// Without start: right after the last clip on the track it asked for (0 on a track not made yet).
        func defaultStart(for key: Key, in state: TimelineState) -> Double {
            guard let id = home(of: key), let lane = state.audioTracks.first(where: { $0.id == id }) else { return 0 }
            return lane.clips.map(\.timelineEnd).max() ?? 0
        }

        /// Puts the clip on its track (without start: after the last clip there), or on a new one when that track is taken there
        /// or hidden (and says why).
        mutating func land(_ plan: AITimelineEdits.PlannedClip, as key: Key, in state: inout TimelineState) -> Note? {
            var clip = plan.clip
            clip.timelineStart = plan.start ?? defaultStart(for: key, in: state)
            let id = homeLane(for: key, in: &state)
            var note: Note?
            if let lane = state.audioTracks.first(where: { $0.id == id }) {
                if !lane.isHidden, AITrackLanding.fits(clip, lane) {
                    state.appendImported(clip, toLane: id, audio: true)
                    return nil
                }
                let span = TimelineSpan(start: clip.timelineStart, end: clip.timelineEnd)
                let other = AITrackLanding.blocker(of: span, among: lane.clips) ?? clip.id
                note = Note(wanted: .lane(id), reason: lane.isHidden ? .hidden : .busy(other))
            }
            let free = spills[key, default: []].first { spill in
                state.audioTracks.first { $0.id == spill }.map { AITrackLanding.fits(clip, $0) } ?? false
            }
            if let free {
                state.appendImported(clip, toLane: free, audio: true)
            } else {
                spills[key, default: []].append(state.insertLane(audio: true, at: state.audioTracks.count, clips: [clip]))
            }
            return note
        }

        private func home(of key: Key) -> UUID? {
            if case .existing(let id) = key { return id }
            return homes[key]
        }

        /// The track a key lands on, made on first use: new named tracks right after the old ones in number order (A2 and A3 keep
        /// their names whatever order their clips come in), new_audio's at the bottom.
        private mutating func homeLane(for key: Key, in state: inout TimelineState) -> UUID {
            if let id = home(of: key) { return id }
            var index = state.audioTracks.count
            if case .numbered(let number) = key {
                index = existing.count + numbers.filter { $0 < number }.count
                numbers.append(number)
            }
            let id = state.insertLane(audio: true, at: index, clips: [])
            homes[key] = id
            return id
        }
    }
}
