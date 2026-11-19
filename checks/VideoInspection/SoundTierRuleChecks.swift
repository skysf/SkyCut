import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// The second-tier delivery rules on controlled numbers (no media): the jump at a cut and every way it can be covered
// (AIDeliveryCutJumps), where the picture changes, a sound past its picture (AIDeliveryLinger.frames), music swelling under a
// line (AIDeliveryMusicSwell.rise), listen's voice verdicts and grey hint as report entries (AIDeliveryVoice.findings), the AI's
// `sounds` and the roles (AIDeliverySoundRoles), and the stem split adding up to the whole mix (DeliveryStemSplit).
// The production path (real renders through inspect_video) is SoundTierChecks.
@MainActor
enum SoundTierRuleChecks {
    typealias Group = AIDeliverySoundLevels.Group

    static func run(require: (Bool, String) -> Void) {
        musicAccents(require: require)
        highPass(require: require)
        cutJumps(require: require)
        pictureCuts(require: require)
        lingers(require: require)
        swell(require: require)
        voiceEntries(require: require)
        roles(require: require)
        split(require: require)
        marks(require: require)
    }

    // MARK: Intentional marks apply to second-tier findings (the real tool's marking path is DeliveryChecks')

    private static func marks(require: (Bool, String) -> Void) {
        let info = MediaInfo(duration: 20, displaySize: CGSize(width: 320, height: 180), frameRate: 24, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
        var state = TimelineState()
        state.frameRate = .fps24
        let a = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"), sourceDuration: 3, info: info)
        let b = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/b.mp4"), sourceDuration: 3, timelineStart: 3, info: info)
        state.mainClips = [a, b]
        let jump = AIInspection.Finding(kind: "audio_cut_jump", from: 3, to: 3, reason: "jump", items: [a.id, b.id])
        let hint = AIInspection.Finding(kind: "audio_voice_loud", from: 1, to: 2, reason: "hint", items: [a.id])
        let first = AIInspectionReview.partition([jump, hint], state: state, job: "sound-tier-marks-1", generation: 0, session: nil)
        let keys = first.findings.compactMap { $0.details["key"]?.stringValue }
        let anchors = keys.compactMap { AIInspectionReview.reports["sound-tier-marks-1"]?.candidates[$0] }
        require(keys.count == 2 && anchors.count == 2, "second-tier findings and hints get keys like any finding")
        state.deliveryIntentions = anchors.map { DeliveryIntentionalMark(anchor: $0, reason: "held breath") }
        let second = AIInspectionReview.partition([jump, hint], state: state, job: "sound-tier-marks-2", generation: 0, session: nil)
        require(second.findings.isEmpty && second.intentional.count == 2
                && second.intentional.allSatisfy { $0["intentional_reason"] == "held breath" && $0["reproduced"] == true },
                "a marked cut jump and a marked grey hint move to the intentional list with their reason")
    }

    // MARK: Levels made to order

    /// 144 frames (6 s at 24 fps); each group gives (full, above-300 Hz) dBFS per frame.
    static func levels(_ groups: [Group: (Int) -> (Double, Double)], accents: [AIDeliverySoundLevels.Accent] = []) -> AIDeliverySoundLevels {
        var frames: [Group: [MixFrameLevel]] = [:]
        for (group, level) in groups {
            frames[group] = (0 ..< 144).map { index in
                let (full, high) = level(index)
                let power = pow(10, full / 10), upper = min(power, pow(10, high / 10))
                return MixFrameLevel(meanSquare: power, peak: 0, bands: SIMD4(power - upper, upper / 3, upper / 3, upper / 3))
            }
        }
        return AIDeliverySoundLevels(grid: MixFrameGrid(fps: 24), first: 0, frames: frames, accents: accents)
    }

    static func step(_ before: Double, _ after: Double, at frame: Int = 72) -> (Int) -> (Double, Double) {
        { $0 < frame ? (before, before) : (after, after) }
    }

    static func sound(_ role: DeliverySoundRole, _ start: Double, _ end: Double) -> AIDeliveryCutJumps.Sound {
        .init(id: UUID(), role: role, start: start, end: end, fadeOutStart: end)
    }

    // MARK: Music accents

    private static func musicAccents(require: (Bool, String) -> Void) {
        // A quiet 440 Hz tone with a 60 Hz thump every 0.5 s from 0.25 s: one accent at each thump, none anywhere else.
        let rate = 24_000.0
        let samples = (0 ..< Int(rate * 3)).map { index -> Float in
            let t = Double(index) / rate, since = (t - 0.25).truncatingRemainder(dividingBy: 0.5)
            let thump = t >= 0.25 && since < 0.08 ? 0.6 * sin(2 * .pi * 60 * t) * exp(-since / 0.03) : 0
            return Float(0.05 * sin(2 * .pi * 440 * t) + thump)
        }
        let found = MusicAccents.find(samples, sampleRate: rate, startsAtSilence: false)
        let expected = stride(from: 0.25, to: 3, by: 0.5)
        require(found.count == 6 && zip(found, expected).allSatisfy { abs($0.time - $1) < 0.05 && $0.strength > 3 },
                "a low thump every 0.5 s is one accent each, within 50 ms (\(found.map { String(format: "%.3f/%.1f", $0.time, $0.strength) }))")
        require(MusicAccents.find([Float](repeating: 0, count: 48_000), sampleRate: rate, startsAtSilence: false).isEmpty, "silence has no accents")
    }

    // MARK: The place above 200 Hz in a cut window

    private static func highPass(require: (Bool, String) -> Void) {
        // 0.3 s at 48 kHz holds whole periods of 100 Hz and 1 kHz: the reading above 200 Hz is exactly the 1 kHz part's power.
        let rate = 48_000.0, window = 0.0 ... 0.3
        func signal(_ index: Int) -> Float { Float(0.5 * sin(2 * .pi * 100 * Double(index) / rate) + 0.1 * sin(2 * .pi * 1000 * Double(index) / rate)) }
        let collector = DeliveryWindowCollector(windows: [window, 0.4 ... 0.7], sampleRate: rate, cutoff: AIDeliverySoundLevels.highCutoff)
        for start in stride(from: 0, to: 14_400, by: 4096) {
            let frames = min(4096, 14_400 - start)
            let block = (0 ..< frames).flatMap { [signal(start + $0), signal(start + $0)] }
            block.withUnsafeBufferPointer { collector.add($0, at: Int64(start), frames: frames) }
        }
        let powers = collector.powers
        require(powers[window].map { abs($0 - 0.005) < 1e-6 } == true,
                "above 200 Hz keeps only the 1 kHz part of a 100 Hz + 1 kHz window (\(String(describing: powers[window])))")
        require(powers[0.4 ... 0.7] == nil, "a window the render never reached is left out, not read as silence")
        var made = Self.levels([.place: { _ in (-20, -20) }])
        made.placeHigh = [window: 0.005]
        require(abs(made.placeHighDB(window) - 10 * log10(0.005)) < 1e-9 && abs(made.placeHighDB(1 ... 1.3) + 20) < 1e-9,
                "a rendered window reads its own power; another falls back to the band meter")
    }

    // MARK: MCP-37

    private static func cutJumps(require: (Bool, String) -> Void) {
        let cut = [AIDeliveryCutJumps.Cut(time: 3, outgoing: UUID(), incoming: UUID())]
        let scope = AIInspection.Scope(ranges: [0 ... 6], duration: 6)
        let f = 1.0 / 24
        func found(_ levels: AIDeliverySoundLevels, _ sounds: [AIDeliveryCutJumps.Sound] = [], speech: [Double] = [],
                   scope: AIInspection.Scope = scope) -> [AIInspection.Finding] {
            AIDeliveryCutJumps.findings(cut, levels: levels, sounds: sounds, speech: speech, duration: 6, scope: scope)
        }
        let bare = found(levels([.place: step(-20, -40)]))
        require(bare.count == 1 && bare[0].kind == "audio_cut_jump" && bare[0].details["jump_db"] == .number(-20)
                && bare[0].details["band"] == "full" && bare[0].items.count == 2,
                "a 20 dB drop of the place's sound at a cut with nothing over it is a cut jump (\(bare.map(\.details)))")
        require(found(levels([.place: step(-20, -40), .music: { _ in (-22, -22) }]), [sound(.music, 0, 6)]).isEmpty,
                "music sounding across the cut within 6 dB of the louder side covers it (a bed)")
        require(found(levels([.place: step(-20, -40), .music: { _ in (-30, -30) }]), [sound(.music, 0, 6)]).count == 1,
                "a bed more than 6 dB under the louder side does not cover the jump")
        require(found(levels([.place: step(-20, -40), .music: { _ in (-22, -22) }]), [sound(.music, 2.8, 6)]).count == 1,
                "music that starts only 0.2 s before the cut is not a bed (it must sound 0.3 s on both sides)")
        let rumble = found(levels([.place: { $0 < 72 ? (-20, -22) : (-24, -40) }]))
        require(rumble.first?.details["band"] == "above_200_hz" && rumble.first?.details["jump_db"] == .number(-18),
                "a 4 dB change in the full band hides an 18 dB jump above 300 Hz; the larger one is reported (\(rumble.map(\.details)))")
        require(found(levels([.place: step(-20, -40)], accents: [.init(time: 3 + 2 * f, strength: 4)])).isEmpty,
                "a music accent 2 frames after the cut covers it")
        require(found(levels([.place: step(-20, -40)], accents: [.init(time: 3 + 5 * f, strength: 4)])).count == 1,
                "an accent 5 frames away does not")
        require(found(levels([.place: step(-20, -40), .music: step(-120, -30)]), [sound(.music, 3 + f, 6)]).isEmpty,
                "music entering one frame after the cut covers it")
        require(found(levels([.place: step(-40, -20), .music: step(-30, -120)]), [sound(.music, 0, 3 - f)]).isEmpty,
                "music stopping one frame before the cut covers it")
        let hit = { (level: Double) in levels([.place: step(-20, -40), .effects: { (72 ..< 80).contains($0) ? (level, level) : (-120, -120) }]) }
        require(found(hit(-18), [sound(.effects, 3, 3.33)]).isEmpty, "an effect starting at the cut about as loud as the jump covers it (a hit)")
        require(found(hit(-35), [sound(.effects, 3, 3.33)]).count == 1, "a quiet effect at the cut does not")
        let riser = levels([.place: step(-40, -20), .effects: { (60 ..< 72).contains($0) ? (-22, -22) : (-120, -120) }])
        require(found(riser, [sound(.effects, 2.5, 3)]).isEmpty, "an effect ending at the cut near the louder level covers it (a riser's top)")
        require(found(levels([.place: step(-20, -40)]), speech: [1, 2.8]).isEmpty,
                "a line in a picture's own sound ending 0.2 s before the cut covers it")
        require(found(levels([.place: step(-20, -40)]), speech: [1, 2.5]).count == 1, "a line ending 0.5 s before the cut does not")
        let head = found(levels([.place: step(-20, -40), .voice: { (74 ..< 90).contains($0) ? (-25, -25) : (-120, -120) }]),
                         [sound(.voice, 3 + 2 * f, 4)])
        require(head.count == 1 && head[0].details["voice_head_frames"] == .number(2),
                "a narration line starting 2 frames after the cut is noted but does not cover the jump")
        require(found(levels([.place: step(-50, -70)])).isEmpty, "a jump between two quiet sides (under -45 dBFS) is not reported")
        require(found(levels([.place: step(-20, -40)]), scope: .init(ranges: [4 ... 6], duration: 6)).isEmpty,
                "a cut outside the checked range is not reported")
        require(found(levels([.place: step(-20, -25)])).isEmpty, "a 5 dB jump is under the 6 dB line")
    }

    // MARK: Where the picture changes

    private static func pictureCuts(require: (Bool, String) -> Void) {
        let info = MediaInfo(duration: 20, displaySize: CGSize(width: 320, height: 180), frameRate: 24, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
        let a = URL(fileURLWithPath: "/tmp/a.mp4"), b = URL(fileURLWithPath: "/tmp/b.mp4")
        var state = TimelineState()
        state.frameRate = .fps24
        state.canvasRatio = .wide16x9
        let first = EditClip(sourceURL: a, sourceDuration: 2, info: info)
        let carryOn = EditClip(sourceURL: a, sourceStart: 2, sourceDuration: 2, timelineStart: 2, info: info)
        let other = EditClip(sourceURL: b, sourceDuration: 2, timelineStart: 4, info: info)
        let afterBlack = EditClip(sourceURL: a, sourceStart: 9, sourceDuration: 2, timelineStart: 7, info: info)
        state.mainClips = [first, carryOn, other, afterBlack]
        var times = AIDeliveryCutJumps.pictureCuts(state).map(\.time)
        require(times == [4, 6, 7], "a split of one take is not a cut; a change of file, into black and out of black are (\(times))")
        let small = EditClip(sourceURL: b, sourceDuration: 1, timelineStart: 0.5, placement: .init(centerX: 0.8, centerY: 0.2, width: 0.2, height: 0.2), info: info)
        let full = EditClip(sourceURL: b, sourceStart: 5, sourceDuration: 1, timelineStart: 2.5, info: info)
        state.overlayTracks = [EditLane(clips: [small, full])]
        times = AIDeliveryCutJumps.pictureCuts(state).map(\.time)
        require(times == [2.5, 3.5, 4, 6, 7], "a full-frame upper clip cuts in and out; a small one does not (\(times))")
    }

    // MARK: MCP-38

    private static func lingers(require: (Bool, String) -> Void) {
        func measured(_ kind: AIDeliveryLinger.Kind, _ sound: [Double], bed: [Double] = []) -> AIDeliveryLinger.Measured {
            .init(candidate: .init(kind: kind, sound: UUID(), picture: UUID(), cut: 3, end: 4, leftOut: []), firstFrame: 72, sound: sound, bed: bed)
        }
        let ringing = measured(.object, [-28, -30, -33, -36, -39, -41, -55, -40])
        require(AIDeliveryLinger.frames(ringing) == 6, "an object counts frames from the cut while it stays above -50 dBFS (the metal clang: 6)")
        let found = AIDeliveryLinger.findings([ringing], grid: MixFrameGrid(fps: 24), scope: .init(ranges: [0 ... 6], duration: 6))
        require(found.count == 1 && found[0].kind == "audio_linger" && abs(found[0].to - 3.25) < 1e-9
                && found[0].details["linger_frames"] == .number(6), "6 frames past the picture is reported from the cut on")
        require(AIDeliveryLinger.findings([measured(.object, [-30, -40, -52, -30])], grid: MixFrameGrid(fps: 24),
                                          scope: .init(ranges: [0 ... 6], duration: 6)).isEmpty,
                "an object that falls under -50 dBFS within 2 frames is not reported")
        let camera = measured(.camera, [-20, -20, -20, -20, -60], bed: [-30, -30, -24, -27, -30])
        require(AIDeliveryLinger.frames(camera) == 3, "a picture's own sound counts only frames 6 dB over the far side's bed")
        require(AIDeliveryLinger.frames(measured(.camera, [-20, -20, -20], bed: [-30, -10, -10])) == 1,
                "a camera sound under the next shot's bed does not count")
        candidates(require: require)
    }

    /// Which sounds are checked: an object belongs to the shot it sounds under longest; a lead belongs to the next shot.
    private static func candidates(require: (Bool, String) -> Void) {
        let info = MediaInfo(duration: 20, displaySize: CGSize(width: 320, height: 180), frameRate: 24, videoCodec: "h264",
                             audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
        let sound = URL(fileURLWithPath: "/tmp/clang.wav"), video = URL(fileURLWithPath: "/tmp/a.mp4")
        var state = TimelineState()
        state.frameRate = .fps24
        state.canvasRatio = .wide16x9
        let first = EditClip(sourceURL: video, sourceDuration: 3, isMuted: true, info: info)
        state.mainClips = [first, EditClip(sourceURL: URL(fileURLWithPath: "/tmp/b.mp4"), sourceDuration: 3, timelineStart: 3, isMuted: true, info: info)]
        let tail = EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 1.4, timelineStart: 2, audioAssetDuration: 5)
        let lead = EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 2.5, timelineStart: 2.5, audioAssetDuration: 5)
        let detached = EditClip(sourceURL: video, isAudioOnly: true, sourceDuration: 3.5, linkGroup: nil, info: info, audioAssetDuration: 20)
        state.audioTracks = [EditLane(clips: [tail]), EditLane(clips: [lead]), EditLane(clips: [detached])]
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let roles = AIDeliverySoundRoles.assign(.init(clips: [tail.id: .object, lead.id: .object]), state: state, config: config, provenance: .init())
        let found = AIDeliveryLinger.candidates(state, config: config, roles: roles, cuts: AIDeliveryCutJumps.pictureCuts(state),
                                                scope: .init(ranges: [0 ... state.duration], duration: state.duration)).found
        require(found.map(\.sound) == [tail.id, detached.id] && found.allSatisfy { $0.cut == 3 && $0.picture == first.id },
                "an object mostly under the first shot and the first shot's detached sound are checked at its cut; a lead is not")
        require(found.last?.kind == .camera && found.first?.kind == .object, "detached camera sound is the camera kind")
    }

    // MARK: Music swelling under a line

    private static func swell(require: (Bool, String) -> Void) {
        let rising = levels([.music: { $0 < 84 ? (-40, -40) : (-25, -25) }])
        let rise = AIDeliveryMusicSwell.rise(levels: rising, from: 3, to: 5)
        require(rise.map { abs($0.db - 15) < 0.01 } == true, "the running 1 s median climbs 15 dB above the line's start (\(String(describing: rise)))")
        require(AIDeliveryMusicSwell.rise(levels: levels([.music: { _ in (-30, -30) }]), from: 3, to: 5)?.db == 0, "steady music does not rise")
        require(AIDeliveryMusicSwell.rise(levels: levels([.music: { $0 < 110 ? (-120, -120) : (-20, -20) }]), from: 3, to: 5) == nil,
                "music heard under less than 30% of the line is not judged")
    }

    // MARK: listen's verdicts as report entries

    private static func voiceEntries(require: (Bool, String) -> Void) {
        let clip = AIListenVoicePlan.Clip(id: UUID(), name: "line", layer: 0, from: 1, to: 5)
        let plan = AIListenVoicePlan(layers: [], clips: [clip], moreClips: 0, duration: 6)
        let masker: JSONValue = ["layer": "A2", "kind": "other", "removed": 0.42, "lowered": 0.2, "level_db": -12]
        let entries: [JSONValue] = [
            ["verdict": "probably_unintelligible", "estoi": 0.22, "maskers": [masker], "low_150_db": -40, "voice_db": -20],
            ["verdict": "two_voices", "estoi": 0.5, "maskers": [masker]],
            ["verdict": "clear", "estoi": 0.46, "hint": "clear, but A2 may be loud — try 3–6 dB lower", "maskers": [masker]],
            ["verdict": "clear", "estoi": 0.8], ["verdict": "too_short"]
        ]
        let lines = (0 ..< entries.count).map { AIListenVoiceMeasure.Line(clip: clip, from: Double($0), to: Double($0) + 0.9, result: nil) }
        let found = AIDeliveryVoice.findings(.init(plan: plan, lines: lines, entries: entries), scope: .init(ranges: [0 ... 6], duration: 6))
        require(found.map(\.kind) == ["audio_voice_masked", "audio_two_voices", "audio_voice_loud"],
                "listen's verdicts become masked / two voices / a grey hint; clear and too short lines add nothing (\(found.map(\.kind)))")
        require(found.first?.details["maskers"]?.arrayValue?.first?["layer"] == "A2" && found.first?.items == [clip.id]
                && found.first?.reason.contains("A2 (other)") == true, "the masked entry names the main masker and the voice clip")
        require(AIDeliveryChecks.hintKinds.contains(found.last?.kind ?? ""), "the hint kind is listed apart from the suspects")
    }

    // MARK: The AI's sounds and the roles

    private static func roles(require: (Bool, String) -> Void) {
        let file = URL(fileURLWithPath: "/tmp/x.wav")
        let voice = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 2, audioAssetDuration: 2)
        let music = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 2, timelineStart: 2, audioAssetDuration: 4)
        let mixed = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 1, timelineStart: 5, audioAssetDuration: 1)
        var state = TimelineState()
        state.frameRate = .fps24
        state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [music]), EditLane(clips: [mixed, EditClip(sourceURL: file,
            isAudioOnly: true, sourceDuration: 1, timelineStart: 7, audioAssetDuration: 1)])]
        let short = AIShortIDs(state: state).short(mixed.id)
        func request(_ sounds: JSONValue) -> AIDeliverySoundRoles.Request? {
            try? AIDeliverySoundRoles.request(AIToolArguments(["sounds": sounds]), state: state)
        }
        let given = request(["A1": "voice", "a2+A3": "music", short: "Voice"])
        require(given?.tracks == ["A1": .voice, "A2": .music, "A3": .music] && given?.clips == [mixed.id: .voice],
                "tracks, tracks joined with +, and a clip id map to roles (case-insensitive)")
        for wrong: JSONValue in [["A9": "music"], ["A1": "drums"], ["A1+A9": "music"], "music"] {
            require(request(wrong) == nil, "\(wrong.encodedString()) is refused with the reason")
        }
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let roles = AIDeliverySoundRoles.assign(given!, state: state, config: config, provenance: .init())
        require(roles.role(of: voice.id) == .voice && roles.role(of: music.id) == .music && roles.role(of: mixed.id) == .voice,
                "a clip id wins over its track's role")
        require(roles.voiceTracks == ["A1"] && roles.unmeasurableVoice == [mixed.id],
                "only a track holding nothing but voice is checked; a voice sharing a track is listed as unmeasurable")
        let plain = AIDeliverySoundRoles.assign(.init(), state: state, config: config, provenance: .init())
        require(plain.role(of: voice.id) == .other && plain.voiceTracks.isEmpty && plain.summary["A2"] == "other",
                "without sounds an imported file is other (the place) and the summary says so")
    }

    // MARK: The stem split

    private static func split(require: (Bool, String) -> Void) {
        let file = URL(fileURLWithPath: "/tmp/x.wav")
        var state = TimelineState()
        let a = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 1, audioAssetDuration: 3)
        let b = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 1, timelineStart: 1, audioAssetDuration: 3)
        let c = EditClip(sourceURL: file, isAudioOnly: true, sourceDuration: 1, timelineStart: 2, audioAssetDuration: 3)
        state.audioTracks = [EditLane(clips: [a, b, c])]
        state.audioTracks[0].volume = 0.5
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        let split = DeliveryStemSplit.split(config, wanted: ["x"], name: { $0 }) { $0.clipID == b.id ? "x" : "y" }
        let kept = split.config.tracks.flatMap(\.segments).map(\.clipID)
        require(Set(kept) == [a.id, b.id, c.id] && split.config.tracks.allSatisfy { $0.fader == 0.5 },
                "the split keeps every segment with its track's fader (the mix stays the export's)")
        require(split.layers.count == 1 && split.layers[0].layer.tracks.count == 1
                && split.config.tracks[split.layers[0].layer.tracks[0]].segments.map(\.clipID) == [b.id],
                "a wanted key is one layer of only its clips")
    }
}
