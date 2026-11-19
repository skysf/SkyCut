import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// MCP-40's remaining second-tier rows on controlled numbers (no media): music dropping out under a line (AIDeliveryMusic.drops),
// music late and a long stretch without any (late, noScore), the grey hint when there is none (noMusic), music starting or
// stopping hard off the picture (AIDeliveryMusicEdges), a sound jumping out of the mix (AIDeliveryAbrupt), the 0.1 s cells
// (DeliveryCells), and a saved sound role between `sounds` and provenance (AIDeliverySoundRoles). Each rule is checked on both
// sides of its line. The production path (real renders through AIDeliverySound.prepare and the registry) is MusicRowChecks.
@MainActor
enum MusicRowRuleChecks {
    typealias Group = AIDeliverySoundLevels.Group

    static func run(require: (Bool, String) -> Void) {
        cells(require: require)
        drops(require: require)
        late(require: require)
        noScore(require: require)
        edges(require: require)
        abrupt(require: require)
        savedRoles(require: require)
    }

    // MARK: Levels made to order

    /// `seconds` of frames at 24 fps (from frame `first`); each group's level (dBFS) as a function of the frame's start time.
    static func levels(_ seconds: Double, first: Int = 0, _ groups: [Group: (Double) -> Double]) -> AIDeliverySoundLevels {
        let count = Int((seconds * 24).rounded())
        var frames: [Group: [MixFrameLevel]] = [:]
        for (group, level) in groups {
            frames[group] = (0 ..< count).map { index in
                let power = pow(10, level(Double(first + index) / 24) / 10)
                return MixFrameLevel(meanSquare: power, peak: 0, bands: SIMD4(0, power / 2, power / 2, 0))
            }
        }
        return AIDeliverySoundLevels(grid: MixFrameGrid(fps: 24), first: first, frames: frames, accents: [])
    }

    static func sound(_ role: DeliverySoundRole, _ start: Double, _ end: Double, id: UUID = UUID()) -> AIDeliveryCutJumps.Sound {
        .init(id: id, role: role, start: start, end: end, fadeOutStart: end)
    }

    static func scope(_ duration: Double) -> AIInspection.Scope { .init(ranges: [0 ... duration], duration: duration) }

    // MARK: Cells

    private static func cells(require: (Bool, String) -> Void) {
        let made = levels(6, [.music: { _ in -20 }])
        require(DeliveryCells(made).range == 0 ..< 60, "6 s measured are cells 0..<60")
        require(DeliveryCells(levels(3, first: 30, [.music: { _ in -20 }])).range == 13 ..< 42,
                "a cell is only read where it lies wholly inside the measured frames (1.25–4.25 s: cells 13..<42)")
        require(DeliveryCells.runs([true, true, false, true, true, true], minimum: 3) == [3 ..< 6]
                && DeliveryCells.runs([true, true, true], minimum: 3) == [0 ..< 3], "runs keep only the long enough ones, to the end too")
        require(abs(made.db(.music, from: 1, to: 1.1) + 20) < 1e-9 && abs(made.meanPower(from: 1, to: 1.1) - 0.01) < 1e-12,
                "a cell reads the frames' mean power; every group together is the mix")
    }

    // MARK: Music dropping out under a line (rule 11)

    private static func drops(require: (Bool, String) -> Void) {
        let voice = sound(.voice, 2, 5), music = sound(.music, 0, 6)
        func found(_ musicLevel: @escaping (Double) -> Double, voiceTo: Double = 5) -> [AIInspection.Finding] {
            let made = levels(6, [.voice: { $0 >= 2 && $0 < voiceTo ? -20 : -120 }, .music: musicLevel])
            return AIDeliveryMusic.drops(made, sounds: [voice, music], scope: scope(6))
        }
        let gone = found { $0 < 2 ? -25 : -50 }
        require(gone.count == 1 && gone[0].kind == "audio_music_drops" && abs(gone[0].from - 2) < 1e-9 && abs(gone[0].to - 5) < 1e-9
                && gone[0].items.contains(voice.id) && gone[0].items.contains(music.id),
                "music heard until the line and 30 dB under it for 3 s drops out (\(gone.map { "\($0.from)–\($0.to) \($0.details)" }))")
        require(found { $0 < 2 ? -25 : -30 }.isEmpty, "music 10 dB under the line (the shared rules' dip) is fine")
        require(found({ $0 < 2 ? -25 : -50 }, voiceTo: 3.8).isEmpty, "a drop shorter than 2 s is not reported")
        let late = found { $0 < 1 ? -25 : -120 }
        require(late.count == 1 && abs(late[0].from - 2) < 1e-9 && abs(late[0].to - 4) < 1e-9,
                "music last heard 1 s before the line counts for 3 s after it: 2.0–4.0, not to the line's end (\(late.map { "\($0.from)–\($0.to)" }))")
        require(found { $0 < 0.5 ? -25 : -120 }.isEmpty, "…so music last heard 1.5 s before leaves only 1.5 s, under the 2 s line")
        require(found { $0 < 0.5 ? -120 : -120 }.isEmpty, "music never heard does not drop out (that is music missing, not dropping)")
        let none = levels(6, [.voice: { _ in -20 }])
        require(AIDeliveryMusic.drops(none, sounds: [voice], scope: scope(6)).isEmpty, "no music group, nothing to drop")
    }

    // MARK: Music late (rule 5)

    private static func late(require: (Bool, String) -> Void) {
        let music = sound(.music, 4, 8)
        func found(_ at: Double, lines: [ClosedRange<Double>] = [], first: Int = 0, picture: Double? = 0) -> [AIInspection.Finding] {
            let made = levels(8 - Double(first) / 24, first: first, [.music: { $0 >= at ? -20 : -120 }])
            return AIDeliveryMusic.late(made, sounds: [music], firstPicture: picture, lines: lines, duration: 8, scope: scope(8))
        }
        let late = found(4)
        require(late.count == 1 && late[0].kind == "audio_music_late" && late[0].from == 0 && abs(late[0].to - 4) < 1e-9
                && late[0].details["music_at"] == .number(4) && late[0].items == [music.id],
                "the picture starts at 0 and music is first heard at 4.0: late (\(late.map(\.details)))")
        require(found(3).isEmpty, "music heard at 3.0 is in time")
        require(found(4, lines: [0.5 ... 2.5]).isEmpty, "an opening line ending at 2.5 lets it wait until 5.5")
        require(found(6, lines: [0.5 ... 2.5]).count == 1, "…but not until 6.0")
        require(found(4, lines: [3.5 ... 6]).count == 1, "a line starting after the first 3 s does not move the deadline")
        require(found(4, picture: 2).isEmpty, "counted from the first picture (2.0 + 3 s)")
        require(found(4, picture: nil).isEmpty, "no picture, nothing to be late for")
        require(found(4, first: 48).isEmpty, "a range that misses the opening says nothing")
        let never = AIDeliveryMusic.late(levels(8, [.music: { _ in -60 }]), sounds: [music], firstPicture: 0, lines: [], duration: 8, scope: scope(8))
        require(never.count == 1 && never[0].details["music_at"] == .null && abs(never[0].to - 8) < 1e-9,
                "music too quiet to be heard anywhere: late to the end of what was checked")
        require(AIDeliveryMusic.late(levels(8, [.music: { _ in -120 }]), sounds: [], firstPicture: 0, lines: [], duration: 8, scope: scope(8)).isEmpty,
                "a video without music is not late (the shared rules make music optional)")
    }

    // MARK: A long stretch without music, and none at all (rule 5, a reminder)

    private static func noScore(require: (Bool, String) -> Void) {
        let music = sound(.music, 0, 2)
        func found(_ effects: [AIDeliveryCutJumps.Sound]) -> [AIInspection.Finding] {
            let made = levels(24, [.music: { $0 < 2 ? -20 : -120 }, .effects: { t in effects.contains { $0.start <= t && $0.end > t } ? -30 : -120 }])
            return AIDeliveryMusic.noScore(made, sounds: [music] + effects, scope: scope(24))
        }
        let gap = found([])
        require(gap.count == 1 && gap[0].kind == "audio_no_score" && abs(gap[0].from - 2) < 1e-9 && abs(gap[0].to - 24) < 1e-9,
                "22 s without music after it stops is a stretch with no score (\(gap.map { "\($0.from)–\($0.to)" }))")
        require(found([sound(.effects, 9, 14)]).isEmpty, "a long effect (5 s: a tone or a riser) splits it into two short stretches")
        require(found([sound(.effects, 9, 10)]).count == 1, "a short effect (1 s: a hit) does not")
        let quiet = levels(24, [.music: { $0 < 2 ? -20 : -120 }, .effects: { _ in -70 }])
        require(AIDeliveryMusic.noScore(quiet, sounds: [music, sound(.effects, 9, 14)], scope: scope(24)).count == 1,
                "a long effect too quiet to hear (-70 dBFS) does not carry it")
        require(AIDeliveryMusic.noScore(levels(24, [:]), sounds: [sound(.voice, 0, 24)], scope: scope(24)).isEmpty,
                "a video with no music at all gets no suspect for it…")
        let hint = AIDeliveryMusic.noMusic(sounds: [sound(.voice, 0, 24)], duration: 24, scope: scope(24))
        require(hint.count == 1 && AIDeliveryChecks.hintKinds.contains(hint[0].kind) && AIDeliveryChecks.wholeFilmKinds.contains(hint[0].kind),
                "…only the grey hint (listed in hints, attached to no clip)")
        require(AIDeliveryMusic.noMusic(sounds: [sound(.voice, 0, 10)], duration: 10, scope: scope(10)).isEmpty
                && AIDeliveryMusic.noMusic(sounds: [music], duration: 24, scope: scope(24)).isEmpty
                && AIDeliveryMusic.noMusic(sounds: [], duration: 24, scope: scope(24)).isEmpty,
                "no hint for a short video, a video with music, or one with no sound at all")
    }

    // MARK: Music starting or stopping hard off the picture (rule 6)

    private static func edges(require: (Bool, String) -> Void) {
        let file = URL(fileURLWithPath: "/tmp/music.wav")
        let clip = AIDeliveryMusicEdges.Clip(id: UUID(), url: file, start: 2, end: 5, fadeIn: 0, fadeOut: 0)
        func found(_ clips: [AIDeliveryMusicEdges.Clip], events: [Double] = [0, 3], level: Double = -20,
                   music: ((Double) -> Double)? = nil) -> [AIInspection.Finding] {
            let made = levels(8, [.music: music ?? { t in clips.contains { $0.start <= t && $0.end > t } ? level : -120 }])
            return AIDeliveryMusicEdges.findings(clips, events: events, levels: made, duration: 8, scope: scope(8))
        }
        let hard = found([clip])
        require(hard.map { $0.details["edge"]?.stringValue ?? "" } == ["in", "out"]
                && hard[0].details["frames_from_event"] == .number(-24) && hard[1].details["frames_from_event"] == .number(48),
                "music entering 24 frames before a cut and stopping 48 after it, both hard (\(hard.map(\.details)))")
        require(found([clip], events: [2.1, 5]).isEmpty, "within 6 frames of a cut or a title it is fine")
        require(found([clip], events: [2.3, 5]).count == 1, "7 frames away it is not")
        require(found([AIDeliveryMusicEdges.Clip(id: clip.id, url: file, start: 2, end: 5, fadeIn: 0.5, fadeOut: 0.3)]).isEmpty,
                "a fade of 0.3 s or more is not a hard edge")
        require(found([clip], level: -45).isEmpty, "music under -40 dBFS at its edge is not a hard edge")
        func accented(_ at: Double) -> [AIInspection.Finding] {
            var made = levels(8, [.music: { t in clip.start <= t && clip.end > t ? -20 : -120 }])
            made = AIDeliverySoundLevels(grid: made.grid, first: made.first, frames: made.frames, accents: [.init(time: at, strength: 8)])
            return AIDeliveryMusicEdges.findings([clip], events: [0, 3], levels: made, duration: 8, scope: scope(8))
        }
        require(accented(2 + 2.0 / 24).map { $0.details["edge"]?.stringValue ?? "" } == ["out"],
                "music entering on its own hit (an accent 2 frames in) was placed there: only its stop is hard")
        require(accented(2 + 5.0 / 24).count == 2, "a hit 5 frames in is not the entry's")
        require(accented(5 - 1.0 / 24).map { $0.details["edge"]?.stringValue ?? "" } == ["in"], "a stop on the music's hit was placed there too")
        let next = AIDeliveryMusicEdges.Clip(id: UUID(), url: file, start: 5, end: 7, fadeIn: 0, fadeOut: 0.5)
        require(found([clip, next]).count == 1 && found([clip, next])[0].details["edge"] == "in",
                "the same file carrying on in the next clip is one piece split in two: only its first entry")
        let bed = AIDeliveryMusicEdges.Clip(id: UUID(), url: URL(fileURLWithPath: "/tmp/bed.wav"), start: 0, end: 8, fadeIn: 0, fadeOut: 0)
        require(found([clip, bed], music: { _ in -20 }).isEmpty, "a layer added or taken away over a music bed heard there is fine")
        require(found([bed]).isEmpty, "music from the film's first moment to its end has no edge to judge")
        require(found([clip], events: []).count == 2 && found([clip], events: [])[0].details["frames_from_event"] == nil,
                "with no cut or title anywhere every hard edge is reported")
        var spoken = AIDeliverySound()
        spoken.events = [0, 3]
        spoken.cameraSpeech = [2.05, 4.5]
        require(AIDeliveryMusicEdges.musicEvents(spoken) == [0, 2.05, 3, 4.5] && found([clip], events: AIDeliveryMusicEdges.musicEvents(spoken))
                    .map { $0.details["edge"]?.stringValue ?? "" } == ["out"],
                "a line in the picture's own sound starting at 2.05 is something to enter on; the stop is still hard")
    }

    // MARK: A sound jumping out of the mix (rule 12, a reminder)

    private static func abrupt(require: (Bool, String) -> Void) {
        let made = levels(8, [.place: { _ in -40 }, .effects: { $0 >= 3 && $0 < 3.3 ? -10 : -120 }])
        func measured(_ db: Double, at start: Double = 3, role: DeliverySoundRole = .effects) -> AIDeliveryAbrupt.Measured {
            let first = Int(start * 24)
            return .init(id: UUID(), role: role, start: start, end: start + 0.3, firstFrame: first,
                         power: (0 ..< 8).map { $0 < 7 ? pow(10, db / 10) : 0 })
        }
        let pop = AIDeliveryAbrupt.findings([measured(-10)], levels: made, events: [0], scope: scope(8))
        require(pop.count == 1 && pop[0].kind == "audio_abrupt" && abs(pop[0].from - 3) < 1e-9
                && (pop[0].details["above_db"]?.doubleValue ?? 0) >= 29,
                "an effect 30 dB over everything around it, a second from any cut, jumps out (\(pop.map(\.details)))")
        require(AIDeliveryAbrupt.findings([measured(-10)], levels: made, events: [3.1], scope: scope(8)).isEmpty,
                "on a cut or a title (within 6 frames) it is deliberate")
        require(AIDeliveryAbrupt.findings([measured(-35)], levels: made, events: [0], scope: scope(8)).isEmpty,
                "a peak under -30 dBFS is never abrupt")
        let busy = levels(8, [.place: { _ in -22 }, .effects: { $0 >= 3 && $0 < 3.3 ? -10 : -120 }])
        require(AIDeliveryAbrupt.findings([measured(-10)], levels: busy, events: [0], scope: scope(8)).isEmpty,
                "12 dB over a busy mix is under the 15 dB line")
        require(AIDeliveryAbrupt.findings([measured(-10, role: .object)], levels: made, events: [0], scope: scope(8))
                    .first?.reason.contains("thing in the picture") == true, "an object says so")
    }

    // MARK: Saved sound roles (EditClip.soundRole) between `sounds` and provenance

    private static func savedRoles(require: (Bool, String) -> Void) {
        let file = URL(fileURLWithPath: "/tmp/y.wav")
        var clang = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 2, audioAssetDuration: 2)
        clang.soundRole = .object
        var bed = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 2, timelineStart: 2, audioAssetDuration: 4)
        bed.soundRole = .music
        let plain = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 1, timelineStart: 5, audioAssetDuration: 1)
        var state = TimelineState()
        state.frameRate = .fps24
        state.audioTracks = [EditLane(clips: [clang]), EditLane(clips: [bed]), EditLane(clips: [plain])]
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let saved = AIDeliverySoundRoles.assign(.init(), state: state, config: config, provenance: .init())
        require(saved.role(of: clang.id) == .object && saved.role(of: bed.id) == .music && saved.role(of: plain.id) == .other,
                "a saved role wins over provenance; a clip with nothing saved is still inferred")
        require(saved.summary["A1"] == "object" && saved.summary["A2"] == "music", "sound_roles shows the saved roles")
        var said = AIDeliverySoundRoles.Request()
        said.tracks = ["A2": .effects]
        said.clips = [clang.id: .ambience]
        let overridden = AIDeliverySoundRoles.assign(said, state: state, config: config, provenance: .init())
        require(overridden.role(of: clang.id) == .ambience && overridden.role(of: bed.id) == .effects,
                "sounds on the call wins over a saved role (clip id and track alike)")
        require(DeliverySoundRole.named.map(\.rawValue) == ClipSoundRole.allCases.map(\.rawValue),
                "what sounds takes and what a clip can be saved as are one list")
    }
}
