import Foundation
import SrtFlowCore

// MARK: - Ducking under speech: where the voice track's lines are (App side: transcript cache and waveform)
//
// Owns (MCP-29): for every clip on the voice track, the sound that speaks (its own, or its linked sound when the sound was
// separated from the picture: AISpeechCutTool.speechClip, as cut_speech) and the lines it speaks, in timeline seconds:
// - a cached transcript (transcribe's cache, the one cut_speech reads): its sentences (SpeechTranscript.sentences, where a
//   pause of 0.6 s also ends one), cut to the clip;
// - otherwise, for a sound file of its own (narration, a voice-over: no picture, no camera metadata), its pauses: the
//   waveform's windows over the clip by VoiceLines' rule (SpeechDuckPlanner.lines(fromPauses:));
// - a camera's sound without a transcript gets no lines (whatever else the camera heard would read as one long line); it is
//   listed so the AI can transcribe it first.
// A waveform still being read is waited for up to AIListenTool.waitSeconds, then the call answers media_loading (retryable).
// Read-only. Not here: the windows and the curves (SpeechDuck, SpeechDuckCurve, SpeechDuckPlanner), the tool (AISpeechDuckTool).

@MainActor
enum SpeechDuckLines {
    static func find(on voice: TrackSlot, in state: TimelineState) async throws -> SpeechDuckPlanner.Speech {
        var found = SpeechDuckPlanner.Speech()
        let deadline = Date().addingTimeInterval(AIListenTool.waitSeconds)
        for clip in state[track: voice] where !clip.isHidden {
            let sound = AISpeechCutTool.speechClip(of: clip, in: state)
            guard sound.hasAudio, !sound.isMuted, !sound.isHidden, !found.clips.contains(sound.id) else { continue }
            found.clips.insert(sound.id)
            if let transcript = await AISpeechCutTool.transcript(of: sound, in: state, language: "auto") {
                found.lines += SpeechTranscript.sentences(words: transcript.words, window: transcript.window).compactMap { sentence in
                    let from = max(sentence.start, sound.timelineStart), to = min(sentence.end, sound.timelineEnd)
                    return to > from ? from...to : nil
                }
                found.fromTranscript.append(sound.id)
            } else if sound.isAudioOnly, sound.info == nil {
                switch await AISpeechCutTool.wholeFile(of: sound, until: deadline) {
                case .ready(let peaks):
                    let windows = AIAudioLevels.windows(peaks, from: sound.sourceStart, to: sound.sourceStart + sound.sourceDuration)
                    let seconds = Double(AIAudioLevels.bucketsPerWindow * WaveformPowerBuilder.bucket) / max(peaks.sampleRate, 1)
                    found.lines += SpeechDuckPlanner.lines(fromPauses: windows, of: sound, windowSeconds: seconds)
                    found.fromPauses.append(sound.id)
                case .reading:
                    throw AIToolError(
                        "SkyCut is still reading the sound of \(sound.name). Call set_track again with the same arguments in a moment.",
                        details: ["status": "media_loading", "retryable": true, "retry_after_ms": 2000]
                    )
                case .unreadable:
                    found.unreadable.append(sound.id)
                }
            } else {
                found.noTranscript.append(sound.id)
            }
        }
        return found
    }
}
