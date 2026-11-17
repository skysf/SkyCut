import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Synthetic production-path delivery reports and project-persistent review decisions. No cloud,
// installed App, microphone or real media is used.
@MainActor
enum DeliveryChecks {
    static func run(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void, rulesOnly: Bool = false, screen: Bool = true) async throws {
        let context = AICallContext(session: "delivery-check", client: "Check", project: project.shortID, stopsWith: project.shortID)
        try await AICallContext.$current.withValue(context) {
            AIWorkspace.shared.register(root)
            try await verify(project, root: root, require: require, rulesOnly: rulesOnly, screen: screen)
        }
    }

    private static func verify(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void, rulesOnly: Bool, screen: Bool) async throws {
        continuityRules(root: root, require: require)
        let sound = root.appendingPathComponent("delivery.wav")
        try writeSound(sound)
        let bed = root.appendingPathComponent("quiet-bed.wav")
        try writeSound(bed, constant: 0.001)
        let picture = root.appendingPathComponent("source.mp4")
        let info = await project.mediaProbes.probeVideo(picture)!
        var state = TimelineState()
        state.frameRate = .fps24
        state.mainClips = [EditClip(sourceURL: picture, sourceDuration: 4, isMuted: true, info: info),
                           EditClip(sourceURL: picture, sourceStart: 4, sourceDuration: 2, timelineStart: 4, isMuted: true, info: info)]
        let voice = EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 4.8, audioAssetDuration: 6)
        state.audioTracks = [EditLane(clips: [voice]), EditLane(clips: [
            EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 1.5, audioAssetDuration: 6)
        ])]
        state.audioTracks.append(EditLane(clips: [EditClip(sourceURL: bed, isAudioOnly: true, sourceDuration: 6, audioAssetDuration: 6)]))
        let cue = SubtitleCue(id: UUID(), start: 3.6, end: 5.5, text: "This sentence continues past the cut")
        state.subtitle = SubtitleDocumentModel(cues: [cue], format: .srt)
        var companion = SubtitleCompanion(origin: .generated)
        companion.cueMeta[cue.id] = CueMeta(provenance: .init(clipID: voice.id, sourceStart: 3.6, sourceEnd: 5.5))
        state.subtitleCompanion = companion
        project.restoreTimeline(state)
        project.effectiveUndoManager!.removeAllActions()
        let before = project.state, clock = project.clock.time
        let first = try await inspect(project)
        let findings = first["findings"]!.arrayValue!
        let kinds = Set(findings.compactMap { $0["kind"]?.stringValue })
        for kind in ["audio_overload", "audio_limiter", "audio_thin", "audio_hole", "audio_silence", "sentence_cut"] {
            require(kinds.contains(kind), "delivery registry detects synthetic \(kind) through the real tool")
        }
        require(first["checks"]?.arrayValue?.count == AIDeliveryChecks.registry.count, "the report names the actual check registry")
        require(project.state == before && project.clock.time == clock && !project.effectiveUndoManager!.canUndo,
                "a complete delivery report never edits or vetoes the project")
        for finding in findings {
            require(finding["key"]?.stringValue?.isEmpty == false && finding["layers"]?.arrayValue != nil,
                    "every finding has a stable key and layer context")
            if finding["kind"]?.stringValue?.hasPrefix("audio_") == true {
                require(finding["loudest_layers"]?.arrayValue != nil, "sound findings show the loudest measured layers, including an empty silent mix")
            }
        }
        let overload = findings.first { $0["kind"] == "audio_overload" }
        require((overload?["peak_dbtp"]?.doubleValue ?? -100) > 0 && (overload?["output_peak_dbtp"]?.doubleValue ?? 0) < 0,
                "overload distinguishes the bus before limiting from the actual limited output")
        require(findings.contains { $0["kind"] == "sentence_cut" && abs(($0["at"]?.doubleValue ?? -1) - 4) < 0.01 },
                "a picture cut between spoken words is checked against the continuing sentence")
        require(findings.contains { $0["kind"] == "sentence_cut" && abs(($0["at"]?.doubleValue ?? -1) - 4.8) < 0.01 },
                "a trimmed sound is checked against the sentence's untrimmed source bounds")
        let speechCut = findings.first { $0["reason"]?.stringValue?.hasPrefix("Source cut on speech") == true }
        require(speechCut?["items"]?.arrayValue == [.string(AIShortIDs(state: before).short(voice.id))],
                "speech-cut items identify the cut voice, while other sounding layers stay in contributor evidence")
        try await limitedMixHasNoHole(project, root: root, require: require)
        project.restoreTimeline(before)
        project.effectiveUndoManager!.removeAllActions()
        if rulesOnly { return }
        guard let thin = findings.first(where: { $0["kind"] == "audio_thin" }), let key = thin["key"]?.stringValue else {
            require(false, "thin finding needed for the intentional-mark production check"); return
        }
        let marked = try await AIInspectionTool.start(AIToolArguments(["intentional": [
            "job_id": first["job_id"]!, "key": .string(key), "reason": "Intentional sparse pause"
        ]]), project)
        require(marked.changedProject && project.state.deliveryIntentions.count == 1, "explicit review writes one project mark")
        require(AISession.shared.round(for: project).phase == .working, "an explicit MCP review joins the project's normal AI undo round")
        project.effectiveUndoManager!.undo()
        require(project.state == before, "one undo removes only the intentional decision")
        project.effectiveUndoManager!.redo()
        require(project.state.deliveryIntentions.count == 1, "redo restores the review decision")
        let again = try await inspect(project, ["from": 1.5, "to": 2.5])
        require(!(again["findings"]?.arrayValue ?? []).contains { $0["kind"] == "audio_thin" }, "marked finding is not reported again")
        require((again["intentional"]?.arrayValue ?? []).contains { $0["key"] == .string(key) && $0["intentional_reason"] == "Intentional sparse pause" },
                "marked finding remains separately visible with the human-readable reason")
        let saved = root.appendingPathComponent("delivery-marks.skycut")
        require(project.saveDocument(as: saved), "reviewed project saves normally")
        let loaded = try VideoEditProjectIO.load(from: saved)
        require(loaded.timeline.deliveryIntentions == project.state.deliveryIntentions, "review reasons and anchors survive a real project-file round trip")
        let legacy = try JSONDecoder().decode(TimelineState.self, from: Data("{}".utf8))
        require(legacy.deliveryIntentions.isEmpty, "old projects decode without review data")
        let oldMark = project.state.deliveryIntentions[0]
        let originalFinding = AIInspection.Finding(kind: "audio_thin", from: thin["from"]!.doubleValue!, to: thin["to"]!.doubleValue!,
                                                   reason: "same event", items: oldMark.anchor.items)
        var nearby = originalFinding
        nearby.from += state.frameRate.secondsPerFrame
        nearby.to += state.frameRate.secondsPerFrame
        let separate = AIInspectionReview.partition([originalFinding, originalFinding, nearby], state: project.state,
            job: "identity-collision-check", generation: project.documentGeneration, session: nil)
        require(separate.findings.count == 1 && separate.intentional.count == 1,
                "one mark suppresses only one nearby event, while exact duplicate findings are coalesced")

        var moved = before
        for lane in moved.audioTracks.indices {
            for clip in moved.audioTracks[lane].clips.indices { moved.audioTracks[lane].clips[clip].timelineStart += 0.5 }
        }
        let movedFinding = AIInspection.Finding(kind: "audio_thin", from: thin["from"]!.doubleValue! + 0.5,
            to: thin["to"]!.doubleValue! + 0.5, reason: "same source event", items: oldMark.anchor.items)
        require(oldMark.anchor.matches(AIInspectionReview.anchor(movedFinding, state: moved)), "source anchoring retains a review when the contributing clips move together")
        moved.audioTracks[0].clips[0].sourceURL = root.appendingPathComponent("another-source.wav")
        require(!oldMark.anchor.matches(AIInspectionReview.anchor(movedFinding, state: moved)), "replacing a contributing source invalidates its mark")

        var small = oldMark.anchor
        small.from += state.frameRate.secondsPerFrame
        small.to += state.frameRate.secondsPerFrame
        require(oldMark.anchor.matches(small), "one-frame source timing adjustment retains an intentional mark")
        small.from += state.frameRate.secondsPerFrame * 3
        require(!oldMark.anchor.matches(small), "a material source timing edit invalidates the mark")
        var other = oldMark.anchor
        other.items = [UUID()]
        require(!oldMark.anchor.matches(other), "an identical kind at a different clip never inherits a decision")
        project.perform(rebuildsPreview: false) { $0.audioTracks[0].clips[0].volume = 0.5 }
        let edited = try await inspect(project, ["from": 1.5, "to": 2.5])
        require((edited["findings"]?.arrayValue ?? []).contains { $0["kind"] == "audio_thin" },
                "changing the contributing mix invalidates the identity and reports the suspect again")
        require((edited["intentional"]?.arrayValue ?? []).contains { $0["key"] == .string(key) && $0["reproduced"] == false },
                "an unmatched saved decision stays visible without suppressing the edited finding")
        let staleBefore = project.state
        do {
            _ = try await AIInspectionTool.start(AIToolArguments(["intentional": [
                "job_id": first["job_id"]!, "key": .string(key), "reason": "Old report"
            ]]), project)
            require(false, "stale report must reject review")
        } catch { require(project.state == staleBefore, "stale review is atomic and changes nothing") }
        for reason in ["", "first\nsecond", String(repeating: "x", count: 241)] {
            do {
                _ = try await AIInspectionTool.start(AIToolArguments(["intentional": [
                    "job_id": edited["job_id"]!, "key": .string(key), "reason": .string(reason)
                ]]), project)
                require(false, "invalid reason must reject")
            } catch { require(project.state == staleBefore, "invalid one-line reason leaves all state untouched") }
        }
        _ = try await AIInspectionTool.start(AIToolArguments(["clear_intentional": .string(key)]), project)
        require(project.state.deliveryIntentions.isEmpty, "clear_intentional removes exactly the saved decision")
        if screen { try await frozenScreen(project, root: root, require: require) }
    }

    private static func continuityRules(root: URL, require: (Bool, String) -> Void) {
        let url = root.appendingPathComponent("sentence-continuity.wav")
        let first = EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: 3, audioAssetDuration: 6)
        let next = EditClip(sourceURL: url, isAudioOnly: true, sourceStart: 3, sourceDuration: 3, timelineStart: 3, audioAssetDuration: 6)
        var state = TimelineState()
        state.audioTracks = [EditLane(clips: [first]), EditLane(clips: [next])]
        state.audioTracks[1].isHidden = true
        let spoken = [AIDeliverySentences.Spoken(clip: first, from: 2.5, to: 3.5, text: "a continuing sentence")]
        let scope = AIInspection.Scope(ranges: [0...6], duration: 6)
        func findings() -> [AIInspection.Finding] {
            AIDeliverySentences.findings(spoken, state: state, scope: scope,
                config: AudioEngineConfig.make(from: state, measuringSceneCompensation: false))
        }
        require(findings().contains { $0.kind == "sentence_cut" }, "a hidden continuation cannot conceal a truncated sentence")
        state.audioTracks[1].isHidden = false
        require(findings().isEmpty, "an audible contiguous source split does not truncate a sentence")
        state.audioTracks[1].isHidden = true
        state.audioTracks[0].volume = 0
        require(findings().isEmpty, "an inaudible voice does not produce a sentence-cut suspect")
    }

    private static func limitedMixHasNoHole(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let sound = root.appendingPathComponent("limited-steady.wav")
        try writeSound(sound, constant: 0.8)
        var state = TimelineState()
        state.frameRate = .fps24
        state.masterVolume = 2
        let full = EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 6, volume: 2, audioAssetDuration: 6)
        state.audioTracks = [EditLane(clips: [full])]
        for _ in 0..<3 {
            state.audioTracks.append(EditLane(clips: [EditClip(sourceURL: sound, isAudioOnly: true, sourceDuration: 1.5, volume: 2, audioAssetDuration: 6)]))
        }
        for i in state.audioTracks.indices { state.audioTracks[i].volume = 2 }
        let folder = root.appendingPathComponent("limited-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = ExportCancellationToken()
        let audio = try await AIInspectionAudio.mix(state, into: folder, cancellation: token)
        let measured = try await AIInspectionMeasurement.measure(state,
            config: AudioEngineConfig.make(from: state, measuringSceneCompensation: false), file: nil, audio: audio, token: token)
        let findings = AIDeliveryMix.findings(measured.frames, scope: try AIInspection.scope(state: state, from: nil, to: nil),
                                             silenceDB: -45, minSilence: 0.5, file: false)
        require(!findings.contains { $0.kind == "audio_hole" },
                "a large bus-level drop with steady limited output is not a hole in the delivered mix")
    }

    static func frozenScreen(_ project: VideoEditProject, root: URL, require: (Bool, String) -> Void) async throws {
        let file = root.appendingPathComponent("scan-film.mp4")
        let info = await project.mediaProbes.probeVideo(file)!
        var state = TimelineState()
        state.frameRate = .fps24
        var screen = EditClip(sourceURL: file, sourceDuration: info.duration, info: info)
        screen.isScreenRecording = true
        state.mainClips = [screen]
        project.restoreTimeline(state)
        let earlier = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.creationDate: earlier, .modificationDate: earlier], ofItemAtPath: file.path)
        require(project.saveDocument(as: root.appendingPathComponent("screen-review.skycut")), "screen review snapshot saves")
        let decoded = try JSONDecoder().decode(TimelineState.self, from: JSONEncoder().encode(state))
        require(decoded.mainClips[0].isScreenRecording, "screen-capture provenance survives saving and copying")
        let copied = ClipboardIdentity.renewed(screen)
        require(copied?.isScreenRecording == true && copied?.id != screen.id, "copying preserves capture provenance with a new clip identity")
        let pieces = TimelineClipSplit.make(screen, at: 3)
        require(pieces?.right.isScreenRecording == true, "splitting preserves capture provenance on the right piece")
        var replaced = screen
        let replacement = ClipFileReplacement(url: root.appendingPathComponent("source.mp4"), kind: .video,
                                               duration: info.duration, info: info, hasAudio: true)
        try ClipFileReplacement.apply(replacement, to: &replaced, sourceStart: 0, stillDuration: 60)
        require(!replaced.isScreenRecording, "replacing the source clears the old screen-recording provenance")

        let result = try await inspect(project, ["file": .string(file.path)])
        require(!(result["findings"]?.arrayValue ?? []).contains { $0["kind"] == "frozen_picture" },
                "static native screen recording is exempt from frozen-picture suspicions in the real frame scan")
        require((result["findings"]?.arrayValue ?? []).contains { $0["kind"] == "stale_export" }, "stale export participates in the common finding registry")
        require((result["findings"]?.arrayValue ?? []).contains { $0["kind"] == "source_cut_crossing" }, "a retained source cut participates in the common finding registry")
        require((result["findings"]?.arrayValue ?? []).contains { $0["kind"] == "flash" },
                "screen recordings still receive the other frame checks")
    }

    private static func inspect(_ project: VideoEditProject, _ extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        var args = extra; args["image"] = false
        let started = try await AIInspectionTool.start(AIToolArguments(.object(args)), project)
        guard let id = started.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("Inspection did not start") }
        for _ in 0..<4 where job.status == .running { await AIJobs.shared.wait(for: job, seconds: 30) }
        guard job.status == .done else { throw AIToolError(job.message ?? "Inspection did not finish") }
        let result = AIJobs.shared.json(job)
        if let path = result["auditions"]?.arrayValue?.first?["path"]?.stringValue {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        return result
    }

    private static func writeSound(_ url: URL, constant: Double? = nil) throws {
        let rate = 48_000.0, count = Int(rate * 6)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let t = Double(i) / rate
            let gain = constant ?? (t < 1.5 ? 0.8 : t < 2.5 ? 0.02 : t < 3.5 ? 0 : 0.1)
            buffer.floatChannelData![0][i] = Float(gain * sin(2 * .pi * 440 * t))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
