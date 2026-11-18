import Foundation
import SrtFlowMCPKit

// MARK: - What each sound on the timeline is, for the second-tier delivery checks (MCP-37 / 38 / 39 / 40)
//
// Owns: one role per clip with sound — voice, music, effects (added accents: hits, risers, whooshes, library and SkyCut effects),
// ambience and object (the sound of a place: a bed of wind, a thing in the picture), camera (a picture's own recording, also
// when detached to an audio track) and other (an imported file SkyCut can't name). Where a role comes from, first match wins:
// 1. inspect_video `sounds`: a clip id, then a track ("A2") or tracks joined with + ("A2+A3") → role. The AI built the timeline
//    or can listen; SkyCut can't tell an imported music file from an imported wind bed (listening-engine.md section 3: the
//    trait words describe, they don't classify).
// 2. Otherwise where the clip came from (AIListenVoicePlan.Provenance, the same reading as listen voice=…): our voice-overs and
//    effects by folder, library music / effects by manifest id, generated audio as music, a video clip's sound as camera.
// Measuring groups: the place (camera, ambience, object, other) is what jumps at a cut (MCP-37); voice, music and effects may
// cover a jump. Also: the audio tracks the voice check can take (every clip with sound on it is voice), and a per-track summary
// for the report so the AI sees what SkyCut assumed and can correct it with `sounds`.
// Not here: measuring (AIDeliverySoundLevels), the rules (AIDeliveryCutJumps, AIDeliveryLinger, AIDeliveryVoice).
// Rules: docs/architecture/finished-video-inspection.md, "Second-tier sound checks".

enum DeliverySoundRole: String, CaseIterable, Sendable {
    case voice, music, effects, ambience, object, camera, other

    /// The values `sounds` takes (camera and other are what SkyCut itself knows or doesn't).
    static let named: [DeliverySoundRole] = [.voice, .music, .effects, .ambience, .object]

    /// The sound of the place: a picture's own recording and whatever was added to sound like that place.
    var isPlace: Bool { self == .camera || self == .ambience || self == .object || self == .other }

    init(_ kind: AIListenVoicePlan.Kind) {
        switch kind {
        case .voice: self = .voice
        case .music: self = .music
        case .effects: self = .effects
        case .clipSound: self = .camera
        case .other: self = .other
        }
    }
}

struct AIDeliverySoundRoles: Sendable {
    /// What the AI said in `sounds`.
    struct Request: Sendable, Equatable {
        var tracks: [String: DeliverySoundRole] = [:]
        var clips: [UUID: DeliverySoundRole] = [:]
        var isEmpty: Bool { tracks.isEmpty && clips.isEmpty }
    }

    let roles: [UUID: DeliverySoundRole]
    /// Audio tracks (AI names) where every clip with sound is voice: the clean voice the voice check needs.
    let voiceTracks: [String]
    /// Voice clips the voice check can't take: they share a track with other sounds, or sit on a video track.
    let unmeasurableVoice: [UUID]
    /// Per track with sound: the roles on it, for the report.
    let summary: JSONValue

    func role(of id: UUID) -> DeliverySoundRole { roles[id] ?? .other }

    static let empty = AIDeliverySoundRoles(roles: [:], voiceTracks: [], unmeasurableVoice: [], summary: .object([:]))

    // MARK: The AI's words

    static func request(_ args: AIToolArguments, state: TimelineState) throws -> Request {
        guard let value = args.raw["sounds"], !value.isNull else { return Request() }
        guard case .object(let entries) = value else {
            throw AIToolError("sounds must be an object: {\"A2\":\"music\",\"c4\":\"object\"} (tracks or clip ids → role).")
        }
        let ids = AIShortIDs(state: state)
        var request = Request()
        for (key, raw) in entries.sorted(by: { $0.key < $1.key }) {
            guard let text = raw.stringValue,
                  let role = DeliverySoundRole.named.first(where: { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame }) else {
                throw AIToolError("sounds[\"\(key)\"] must be one of: \(DeliverySoundRole.named.map(\.rawValue).joined(separator: ", ")).")
            }
            let parts = key.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            if !parts.isEmpty, parts.allSatisfy({ trackName($0, in: state) != nil }) {
                for part in parts { request.tracks[part.uppercased()] = role }
            } else if parts.count > 1 {
                let wrong = parts.first { trackName($0, in: state) == nil } ?? key
                throw AIToolError("sounds: \"\(wrong)\" in \"\(key)\" is not a track here (V1, V2…, A1…).")
            } else {
                let id = try ids.resolve(key)
                guard state.clip(with: id) != nil else { throw AIToolError("sounds: \"\(key)\" is not a clip or a track.") }
                request.clips[id] = role
            }
        }
        return request
    }

    /// An existing track's slot from its AI name, or nil.
    static func trackName(_ text: String, in state: TimelineState) -> TrackSlot? {
        let name = text.uppercased()
        guard let letter = name.first, let number = Int(name.dropFirst()), number >= 1 else { return nil }
        if letter == "V" {
            if number == 1 { return .main }
            return state.overlayTracks.indices.contains(number - 2) ? .overlay(number - 2) : nil
        }
        if letter == "A" { return state.audioTracks.indices.contains(number - 1) ? .audio(number - 1) : nil }
        return nil
    }

    // MARK: Assigning

    @MainActor
    static func assign(_ request: Request, state: TimelineState, config: AudioEngineConfig) -> AIDeliverySoundRoles {
        assign(request, state: state, config: config, provenance: AIListenVoiceCheck.provenance())
    }

    static func assign(_ request: Request, state: TimelineState, config: AudioEngineConfig,
                       provenance: AIListenVoicePlan.Provenance) -> AIDeliverySoundRoles {
        var roles: [UUID: DeliverySoundRole] = [:]
        var perTrack: [(name: String, clips: [EditClip])] = []
        for name in AIListenMixPlan.audibleNames(config) {
            let clips = AIListenVoicePlan.audioClips(name, state: state)
            perTrack.append((name, clips))
            for clip in clips {
                roles[clip.id] = request.clips[clip.id] ?? request.tracks[name] ?? DeliverySoundRole(provenance.kind(of: clip))
            }
        }
        var voiceTracks: [String] = []
        var unmeasurable: [UUID] = []
        var summary: [String: JSONValue] = [:]
        for (name, clips) in perTrack where !clips.isEmpty {
            let present = DeliverySoundRole.allCases.filter { role in clips.contains { roles[$0.id] == role } }
            summary[name] = .string(present.map(\.rawValue).joined(separator: "+"))
            let voices = clips.filter { roles[$0.id] == .voice }
            if name.hasPrefix("A"), voices.count == clips.count, voiceTracks.count < AIListenVoicePlan.maxLayers - 1 {
                voiceTracks.append(name)
            } else {
                unmeasurable += voices.map(\.id)
            }
        }
        return AIDeliverySoundRoles(roles: roles, voiceTracks: voiceTracks, unmeasurableVoice: unmeasurable, summary: .object(summary))
    }
}
