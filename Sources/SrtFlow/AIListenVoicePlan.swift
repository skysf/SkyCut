import Foundation
import SrtFlowMCPKit

// MARK: - listen voice=…: which tracks are the voice, which layers may cover it, which clips to check (pure value)
//
// What: `voice` names the voice: an audio track ("A2"), several ("A2+A3"), or "auto" (every audio track holding only
// SkyCut's voice-overs). A voice has to be on its own track — that is the clean voice ESTOI needs. A video track's sound is
// the clips' own recording (a voice inside a clip's own sound, with whatever else the camera heard): SkyCut can't take the
// voice out of it, so naming one is refused with that reason (MCP-39: "say so").
// Layers: each voice track is a layer; every other audible track is a layer of its own (beyond 12 in all, the last ones are
// joined as "rest") — the candidates for "who covers this line". Each layer knows what its clips are, from where they came
// (`Kind`: our voice-overs, library or generated music, sound effects, a clip's own sound, other): the report names the main
// masker by that, and music is judged on its own line (VoiceClarity).
// Clips: every audible clip on a voice track inside from / to (at most `maxClips`).
// Not here: rendering and measuring (AIListenVoiceCheck), lines inside a clip (VoiceLines), the verdict (VoiceClarity), the
// result (AIListenVoiceReport). Long-term rules: docs/architecture/listening-engine.md section 2.

struct AIListenVoicePlan: Sendable {
    enum Kind: String, Sendable {
        case voice, music, effects
        case clipSound = "clip_sound"
        case other
    }

    struct Piece: Sendable {
        let from: Double
        let to: Double
        let kind: Kind
    }

    struct Layer: Sendable {
        let stem: AudioStemLayer
        let isVoice: Bool
        /// Its clips on the timeline and what each is.
        let pieces: [Piece]

        /// What this layer mostly is over [from, to) (the clip it overlaps most).
        func kind(from: Double, to: Double) -> Kind {
            var best: (overlap: Double, kind: Kind)?
            for piece in pieces {
                let overlap = min(to, piece.to) - max(from, piece.from)
                if overlap > (best?.overlap ?? 0) { best = (overlap, piece.kind) }
            }
            return best?.kind ?? .other
        }
    }

    /// One voice clip's audible part inside from / to (timeline seconds), on voice layer `layer`.
    struct Clip: Sendable {
        let id: UUID
        let name: String
        let layer: Int
        let from: Double
        let to: Double
    }

    let layers: [Layer]
    let clips: [Clip]
    /// Voice clips inside from / to that did not fit under `maxClips`.
    let moreClips: Int
    let duration: Double

    static let maxLayers = AIListenMixPlan.maxLayers
    static let maxClips = 40
    static let auto = "auto"

    // MARK: Entry

    static func make(
        _ spec: String, state: TimelineState, config: AudioEngineConfig, from: Double?, to: Double?, provenance: Provenance
    ) throws -> AIListenVoicePlan {
        let names = AIListenMixPlan.audibleNames(config)
        let voices = try voiceTracks(spec, names: names, state: state, provenance: provenance)
        var layers = voices.map { Layer(stem: AudioStemLayer(name: names[$0], tracks: [$0]), isVoice: true,
                                        pieces: pieces(names[$0], state: state, provenance: provenance)) }
        let others = names.indices.filter { !voices.contains($0) }
        let room = maxLayers - layers.count
        for (position, index) in others.enumerated() {
            if others.count > room, position >= room - 1 {
                let rest = Array(others[(room - 1)...])
                layers.append(Layer(stem: AudioStemLayer(name: AIListenMixPlan.rest, tracks: rest), isVoice: false,
                                    pieces: rest.flatMap { pieces(names[$0], state: state, provenance: provenance) }))
                break
            }
            layers.append(Layer(stem: AudioStemLayer(name: names[index], tracks: [index]), isVoice: false,
                                pieces: pieces(names[index], state: state, provenance: provenance)))
        }
        let start = max(0, from ?? 0), end = min(config.duration, to ?? config.duration)
        guard end > start else { throw AIToolError("Nothing to check between from and to.") }
        var clips: [Clip] = []
        for (layer, track) in voices.enumerated() {
            for clip in audioClips(names[track], state: state) where clip.timelineEnd > start && clip.timelineStart < end {
                clips.append(Clip(id: clip.id, name: clip.name, layer: layer,
                                  from: max(start, clip.timelineStart), to: min(end, clip.timelineEnd)))
            }
        }
        clips.sort { ($0.from, $0.layer) < ($1.from, $1.layer) }
        guard !clips.isEmpty else {
            throw AIToolError("No voice clip plays between \(String(format: "%.2f", start)) and \(String(format: "%.2f", end)) s on \(voices.map { names[$0] }.joined(separator: ", ")).")
        }
        return AIListenVoicePlan(layers: layers, clips: Array(clips.prefix(maxClips)),
                                 moreClips: max(0, clips.count - maxClips), duration: config.duration)
    }

    // MARK: Which tracks

    /// The voice tracks, as indices into the mix's audible tracks.
    static func voiceTracks(_ spec: String, names: [String], state: TimelineState, provenance: Provenance) throws -> [Int] {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == auto {
            let found = names.indices.filter { index in
                let clips = audioClips(names[index], state: state)
                return names[index].hasPrefix("A") && !clips.isEmpty && clips.allSatisfy { provenance.kind(of: $0, onVideoTrack: false) == .voice }
            }
            guard !found.isEmpty else {
                throw AIToolError("No audio track holds only SkyCut voice-overs. Name the narration track: voice=A1 (or A1+A2).")
            }
            return found
        }
        var result: [Int] = []
        for part in trimmed.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) {
            if part == "V1" || part == "MAIN" || part.hasPrefix("V") {
                throw AIToolError("\(part == "MAIN" ? "V1" : part) is the clips' own sound: a voice in it was recorded together with "
                    + "everything around it, and SkyCut can't take the voice out, so it can't be checked. Only a voice on its own "
                    + "audio track (narration, voice-over) can.")
            }
            guard let index = names.firstIndex(of: part) else {
                throw AIToolError("\(part) is not an audio track with sound in the mix. Tracks in the mix: \(names.joined(separator: ", ")).")
            }
            if !result.contains(index) { result.append(index) }
        }
        guard !result.isEmpty else { throw AIToolError("voice takes an audio track (A1), several (A1+A2) or auto.") }
        guard result.count < maxLayers else { throw AIToolError("voice takes at most \(maxLayers - 1) tracks.") }
        return result
    }

    // MARK: Provenance

    /// What SkyCut knows about where a clip's sound came from (built by AIListenVoiceCheck: library ids, its own output folders).
    struct Provenance: Sendable {
        /// Library manifest id → music / effects.
        let library: [String: Kind]
        /// SkyCut's own output folder names (every interface language) → voice / effects / music (generated audio).
        let folders: [String: Kind]

        init(library: [String: Kind] = [:], folders: [String: Kind] = [:]) {
            self.library = library
            self.folders = folders
        }

        func kind(of clip: EditClip, onVideoTrack: Bool) -> Kind {
            if onVideoTrack, !clip.isAudioOnly { return .clipSound }
            if let key = clip.remoteKey, let kind = library[key] { return kind }
            switch folders[clip.sourceURL.deletingLastPathComponent().lastPathComponent] {
            case .voice?: return .voice
            case .effects?: return .effects
            case .music? where clip.isAudioOnly: return .music
            default: return .other
            }
        }
    }

    /// The audible clips with sound on a track (AI name).
    static func audioClips(_ name: String, state: TimelineState) -> [EditClip] {
        let clips: [EditClip]
        if name == "V1" {
            clips = state.mainHidden ? [] : state.mainClips
        } else if let number = Int(name.dropFirst()), name.first == "V", state.overlayTracks.indices.contains(number - 2) {
            clips = state.overlayTracks[number - 2].isHidden ? [] : state.overlayTracks[number - 2].clips
        } else if let number = Int(name.dropFirst()), name.first == "A", state.audioTracks.indices.contains(number - 1) {
            clips = state.audioTracks[number - 1].isHidden ? [] : state.audioTracks[number - 1].clips
        } else {
            clips = []
        }
        return clips.filter { $0.hasAudio && !$0.isMuted && !$0.isHidden }
    }

    private static func pieces(_ name: String, state: TimelineState, provenance: Provenance) -> [Piece] {
        let videoTrack = name.hasPrefix("V")
        return audioClips(name, state: state).map {
            Piece(from: $0.timelineStart, to: $0.timelineEnd, kind: provenance.kind(of: $0, onVideoTrack: videoTrack))
        }
    }
}
