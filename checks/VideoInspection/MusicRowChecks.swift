import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// MCP-40's remaining second-tier rows through the production preparation (AIDeliverySound.prepare: the real render split by role
// group, each effect or object rendered alone) and their rules as the registry runs them, on synthetic sound only, without a job
// (the binary links the debug build and has a 480 s deadline; the real job runs the registry in SoundTierChecks).
// One picture (no cut) over 6 s. A1 music, −35 dBFS, stopping hard at 2.0 s; A2 a voice, −30 dBFS from 2.0 to 5.0 s, sharing its
// track with a faint bed so the voice check (ESTOI, slow unoptimized) stays out; A3 a 0.2 s burst at 1.0 s, −9 dBFS. The roles are
// saved through the real edit_clip (`sound_role`, one undo step each; edit_clips takes the same field): music, voice, effects,
// and the burst named object on the call. Expected: the roles as saved (the call's `sounds` winning), the music dropping out
// under the voice 2.0–5.0, its hard stop 48 frames from the only picture event, the burst jumping out of the mix; nothing late,
// no stretch without music, no hint.
@MainActor
enum MusicRowChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        MusicRowRuleChecks.run(require: require)
        try await prepared(project, root: root, require: require)
    }

    private static func prepared(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let picture = root.appendingPathComponent("source.mp4")
        guard let info = await project.mediaProbes.probeVideo(picture) else { throw AIToolError("source.mp4 did not probe.") }
        var noise = SoundTierChecks.Noise(seed: 31)
        let music = try SoundTierChecks.wave(root, "row-music.wav", 2) { t in Float(0.0178 * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 660 * t))) }
        let voice = try SoundTierChecks.wave(root, "row-voice.wav", 3) { t in Float(0.0447 * sin(2 * .pi * 300 * t)) }
        let bed = try SoundTierChecks.wave(root, "row-bed.wav", 0.5) { _ in noise.next(0.0005) }
        let burst = try SoundTierChecks.wave(root, "row-burst.wav", 0.2) { t in Float(0.5 * sin(2 * .pi * 1000 * t)) }
        let musicClip = SoundTierChecks.audio(music, at: 0, 2, asset: 2)
        let voiceClip = SoundTierChecks.audio(voice, at: 2, 3, asset: 3)
        let burstClip = SoundTierChecks.audio(burst, at: 1, 0.2, asset: 0.2)
        var built = TimelineState()
        built.frameRate = .fps24
        built.mainClips = [EditClip(sourceURL: picture, sourceDuration: 6, isMuted: true, info: info)]
        built.audioTracks = [EditLane(clips: [musicClip]), EditLane(clips: [voiceClip, SoundTierChecks.audio(bed, at: 5.4, 0.5, asset: 0.5)]),
                             EditLane(clips: [burstClip])]
        project.restoreTimeline(built)
        let undo = project.effectiveUndoManager!
        undo.removeAllActions()
        // One explicit undo group per call, as the router makes them (AIUndoGrouping.step), whatever the run loop does here.
        let byEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = byEvent }
        let ids = AIShortIDs(state: built)
        for (clip, role) in [(musicClip, "music"), (voiceClip, "voice"), (burstClip, "effects")] {
            let plan = try await AIClipTools.plan(AIToolArguments(["clip_id": .string(ids.short(clip.id)), "sound_role": .string(role)]), project)
            let reply = try AIUndoGrouping.step(undo) { try AIClipTools.apply(plan, project) }
            require(reply.payload["sound_role"]?.stringValue == role, "edit_clip sound_role \(role) is saved and in its reply")
        }
        require(project.state.clip(with: musicClip.id)?.soundRole == .music && project.state.clip(with: burstClip.id)?.soundRole == .effects,
                "edit_clip saved the roles on the clips")
        let state = project.state
        undo.undo()
        require(project.state.clip(with: burstClip.id)?.soundRole == nil && project.state.clip(with: voiceClip.id)?.soundRole == .voice,
                "one undo takes back one saved role")
        undo.redo()
        require(project.state == state, "redo saves it again")
        var request = AIDeliverySoundRoles.Request()
        request.clips = [burstClip.id: .object]
        let scope = try AIInspection.scope(state: state, from: nil, to: nil)
        let sound = try await AIDeliverySound.prepare(state, request: request, scope: scope, spoken: [], token: ExportCancellationToken())
        require(sound.roles.role(of: musicClip.id) == .music && sound.roles.role(of: voiceClip.id) == .voice
                && sound.roles.role(of: burstClip.id) == .object,
                "saved roles drive the real preparation; the call's sounds wins over a saved one (\(sound.roles.summary.encodedString()))")
        let drops = AIDeliveryMusic.drops(sound.levels, sounds: sound.sounds, scope: scope)
        require(drops.count == 1 && abs(drops[0].from - 2) < 0.051 && abs(drops[0].to - 5) < 0.051,
                "the music stopping under the voice's 3 s is reported once, 2.0–5.0 (\(drops.map { "\($0.from)–\($0.to) \($0.details)" }))")
        let edges = AIDeliveryMusicEdges.findings(sound.musicClips, events: sound.events, levels: sound.levels,
                                                  duration: sound.duration, scope: scope)
        require(edges.count == 1 && edges[0].details["edge"] == "out" && abs(edges[0].from - 2) < 1e-6
                && edges[0].details["frames_from_event"] == .number(48),
                "the music's hard stop 48 frames from the first picture, its only event, is reported (\(edges.map(\.details)))")
        let pops = AIDeliveryAbrupt.findings(sound.abrupt, levels: sound.levels, events: sound.events, scope: scope)
        require(pops.count == 1 && abs(pops[0].from - 1) < 1e-6 && pops[0].items == [burstClip.id]
                && (pops[0].details["above_db"]?.doubleValue ?? 0) >= 15 && pops[0].reason.contains("thing in the picture"),
                "the burst rendered alone jumps out of the mix at 1.0 s (\(pops.map(\.details)))")
        let timing = AIDeliveryMusic.late(sound.levels, sounds: sound.sounds, firstPicture: sound.firstPicture, lines: sound.lines,
                                          duration: sound.duration, scope: scope)
            + AIDeliveryMusic.noScore(sound.levels, sounds: sound.sounds, scope: scope)
            + AIDeliveryMusic.noMusic(sounds: sound.sounds, duration: sound.duration, scope: scope)
        require(timing.isEmpty && sound.firstPicture == 0, "music from the first frame is neither late nor missing (\(timing.map(\.kind)))")
        require(sound.limitations.contains { $0.contains("Voice clarity was not measured") },
                "a voice sharing its track is left out of the voice check and said so")
    }
}
