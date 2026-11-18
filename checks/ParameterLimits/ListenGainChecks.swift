import AVFoundation
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// Exercises the real listen entry with synthetic PCM and a registered project. No account or external media is used.
@MainActor enum ListenGainChecks {
    static func run(_ fixture: ParameterFixture, root: URL, require: (Bool, String) -> Void) async throws {
        let duration = 1.0 / 24
        for impulse in [true, false] {
            let url = root.appendingPathComponent(impulse ? "listen-impulse.caf" : "listen-constant.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000)!
            buffer.frameLength = 2_000
            for index in 0..<2_000 { buffer.floatChannelData![0][index] = !impulse || index == 0 ? 0.8 : 0 }
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
            try file!.write(from: buffer)
            file = nil
            var state = TimelineState()
            state.frameRate = .fps24
            var clip = EditClip(sourceURL: url, isAudioOnly: true, sourceDuration: duration, timelineStart: 0,
                                audioAssetDuration: duration)
            clip.fadeInDuration = impulse ? duration : 0
            clip.volume = impulse ? 1 : 0.5
            state.audioTracks = [EditLane(clips: [clip], volume: impulse ? 1 : 0.5)]
            fixture.reset(state)
            let before = fixture.project.state
            let rebuild = fixture.rebuild
            let args = AIToolArguments(["clip_id": .string(AIShortIDs(state: state).short(clip.id))])
            let audit = MediaReadAudit()
            let result = try await MediaReadAudit.$current.withValue(audit) { try await AIListenTool.listen(args, fixture.project) }
            require(audit.entries.count == 2, "the clip entry still uses exactly one bounded reader and no whole-file waveform")
            require(!result.isError && result.payload["sound"] == nil, "listen reads the synthetic PCM through the production entry")
            if impulse {
                require(result.payload["peak_db"] == -60, "a first-sample impulse under a full fade-in has silent true peak")
                require(result.payload["level_db"] == "silent", "level and true peak use the same gained samples")
                require(result.payload["peak_at"] == nil && result.payload["loudest_at"] == nil,
                        "an inaudible impulse has no peak_at or loudest_at")
            } else {
                require(abs((result.payload["level_db"]?.doubleValue ?? 0) + 14) < 0.11,
                        "clip volume and track fader are each applied exactly once to RMS")
                require(abs((result.payload["peak_db"]?.doubleValue ?? 0) + 14) < 0.11,
                        "constant gained PCM agrees with the reported true peak")
            }
            require(fixture.project.state == before && !fixture.project.effectiveUndoManager!.canUndo && fixture.rebuild == rebuild,
                    "listen does not edit the project or create undo / preview work")
        }
        let raw = try await AIListenTool.listen(AIToolArguments(["file": .string(root.appendingPathComponent("listen-impulse.caf").path)]), fixture.project)
        require(abs((raw.payload["peak_db"]?.doubleValue ?? 0) + 1.9) < 0.11, "file listen keeps the raw source true peak")
        fixture.reset()
    }
}
