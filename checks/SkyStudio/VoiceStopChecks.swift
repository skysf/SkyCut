import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 停下几批的旁白（docs/bugfixes/2026-11-10-voiceover-stop-reports-one-batch.md），纯值：六批停在五种地方 —— 做完、在 Sky Studio 已经开始了、
// 开始之前停下（退了钱）、没交、交了没拿到任务号 —— 结果那句话每一批都说到；结果不明的那几批的句子在 unknown_line_indices 里；
// 只有一批的不另写（用那一批自己的话）。真停一次在 check-voice-recovery 的 StopChecks。
func runVoiceStopSummaryChecks() {
    do {
        let selection: JSONValue = ["model": "index-tts-2", "reference_language": "en"]
        var checkpoint = try stopCheckpoint(lines: [String](repeating: "Hello world.", count: 12), selection: selection)
        checkEqual(checkpoint.batches.count, 6, "twelve lines pack into six batches under a 30-character cap")
        checkpoint.willSubmit(0)
        if let done = SkyStudioJobStatus(json: ["job_id": "original-0", "status": "done", "credits_charged": 2.5,
            "result": ["url": "http://127.0.0.1/voice.wav", "model": "index-tts-2", "voice_plan": ["selection": selection]]]) {
            checkpoint.received(done, at: 0)
        }
        checkpoint.willSubmit(1)
        checkpoint.batches[1].serverID = "original-1"
        checkpoint.batches[1].uncertain = 2.5
        checkpoint.willSubmit(2)
        checkpoint.batches[2].serverID = "original-2"
        checkpoint.batches[2].retryable = true
        checkpoint.willSubmit(5)
        let states = checkpoint.batches.indices.map { SkyStudioVoiceStopSummary.state(of: $0, in: checkpoint) }
        checkEqual(states, [.done, .started, .refunded, .notSent, .notSent, .unknown], "where each batch stopped")
        checkEqual(SkyStudioVoiceStopSummary.message(checkpoint),
                   "Stopped. By batch_index (from 0): 0 finished (resume uses the audio without paying again); 1 had already started on Sky "
                   + "Studio and could not be cancelled (credits may be spent; resume only fetches the result); 2 stopped before Sky Studio "
                   + "started (credits returned); 3, 4 never sent (nothing charged); 5 sent without a job id coming back (outcome unknown; "
                   + "never sent again). Nothing was added to the timeline.",
                   "the stop message says where every batch stopped")
        let detail = checkpoint.detail(recoveryFile: "/r.json")
        checkEqual(detail["unknown_batch_indices"], [1, 5], "the two batches whose outcome is unknown")
        checkEqual(detail["unknown_line_indices"], [2, 3, 10, 11], "their lines are listed per line too (no line is left out of every list)")
        checkEqual(detail["pending_recovery_line_indices"], [0, 1], "the finished batch's lines wait for the local split")
        checkEqual(detail["not_generated_line_indices"], [4, 5, 6, 7, 8, 9], "the refunded and unsent batches' lines")
        // 本机已经切好的那几句不算结果不明（不管它们那一批记成什么）。
        checkpoint.outputs[10] = .init(url: URL(fileURLWithPath: "/tmp/line-10.m4a"), duration: 1, words: [])
        checkEqual(checkpoint.detail(recoveryFile: "/r.json")["unknown_line_indices"], [2, 3, 11], "a line already finished locally is not unknown")

        let single = try stopCheckpoint(lines: ["Hello world."], selection: selection)
        checkEqual(SkyStudioVoiceStopSummary.message(single) == nil, true, "one batch keeps that batch's own message")
    } catch { check(false, "voice stop checks: \(error)") }
}

private func stopCheckpoint(lines: [String], selection: JSONValue) throws -> SkyStudioVoiceCheckpoint {
    let catalog = SkyStudioCatalog(models: [SkyStudioModel(id: "index-tts-2", kind: "voice_clone", title: "Clone",
                                                           limits: ["max_characters_by_language": ["other": 30]])])
    let reading = SkyStudioVoiceReading(model: "auto", packs: true, timing: .aligned, transcribes: true, switchedForTiming: false)
    let draft = try SkyStudioVoicePlan.draft(lines: lines, kind: "voice_clone", voice: sampleVoiceID, reading: reading, language: "en", catalog: catalog)
    let quoted: JSONValue = ["credits": .number(2.5 * Double(draft.speech.count)), "voice_plan": ["selection": selection, "rule": "en_80"],
                             "batches": .array(draft.speech.map { _ in ["credits": 2.5] }), "one_time": []]
    guard let quote = SkyStudioQuote(json: quoted) else { throw CocoaError(.coderReadCorrupt) }
    let plan = try SkyStudioVoicePlan.quoted(draft, quote: quote)
    let input = SkyStudioVoiceCheckpoint.Input(lines: lines.map { .init(text: $0) }, language: "en", voice: sampleVoiceID, speed: 1,
        subtitles: true, folder: URL(fileURLWithPath: "/tmp/stop-checks"), playhead: 0)
    return SkyStudioVoiceCheckpoint(input: input, projectPath: nil, projectToken: "run-p1", plan: plan)
}
