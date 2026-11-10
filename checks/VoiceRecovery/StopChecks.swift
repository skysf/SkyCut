import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 停下几批的旁白（docs/bugfixes/2026-11-10-voiceover-stop-reports-one-batch.md），真 App 对象 + 假协议：五句五批、声音池 2 个；
// 第 0 批一问就做完，第 1 批在 Sky Studio 已经开始（取消回 409），第 2 批还排着（取消回 200、之后问回 cancelled + 全退），第 3、4 批在等空位。
// 这时停：结果那句话逐批说清（以前只有最先出事的那一批的话），结果不明的第 1 批的那句在 unknown_line_indices 里（以前哪个句子列表都没有）；
// 放开之后普通恢复只 GET 那一单、把它的那句收好、什么都不交。顺带看 AI 的任务跑着时领着不降速的那一份、停了就还（AIKeepAwake）。

/// 假服务停下时的样子：哪几批（按规矩的序号）已经开始了，取消了哪几单（按交的顺序）。
private final class StopServer: @unchecked Sendable {
    let started: Set<Int> = [1]
    var cancelled: Set<Int> = []

    /// 调用时已经拿着 VoiceRecoveryHTTP.lock。
    func answer(_ method: String, _ path: String) -> (Int, JSONValue)? {
        guard path.contains("/jobs/voice-"), let tail = path.components(separatedBy: "/jobs/voice-").last,
              let index = Int(tail.replacingOccurrences(of: "/cancel", with: "")), index < VoiceRecoveryHTTP.ruleOf.count else { return nil }
        if method == "POST", path.hasSuffix("/cancel") {
            if started.contains(VoiceRecoveryHTTP.ruleOf[index]) {
                return (409, ["error": ["code": "not_cancellable", "message": "Sky Studio already started this job.", "status": "running"]])
            }
            cancelled.insert(index)
            VoiceRecoveryHTTP.open.remove(index)
            return (200, ["status": "cancelled", "credits_refunded": 2.5])
        }
        if method == "GET", cancelled.contains(index) {
            return (200, ["job_id": .string("voice-\(index)"), "status": "cancelled", "billing": ["status": "refunded", "credits_charged": 0]])
        }
        return nil
    }
}

@MainActor
func runVoiceStopChecks(_ root: URL) async throws {
    let lines = ["Welcome to the harbour.", "The boats leave at six.", "Bring a warm jacket.", "Tickets are on board.", "Enjoy the ride home."]
    let fixture = try VoiceRecoveryFixture(folder: root.appendingPathComponent("stop"), audioSlots: 2)
    fixture.failSplitOnce = false
    VoiceRecoveryHTTP.deferred = true
    VoiceRecoveryHTTP.promptIndex = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($0.element, $0.offset) })
    // 第 0 批一问就做完；别的批一直不回结局（99 号永远不会回），直到放开。
    VoiceRecoveryHTTP.holdUntil = [1: 99, 2: 99, 3: 99, 4: 99]
    let server = StopServer()
    VoiceRecoveryHTTP.override = { method, path in server.answer(method, path) }
    let awakeBefore = AIKeepAwake.shared.holders

    let result = try fixture.started(await fixture.narrate(lines))
    guard let id = result.payload["job_id"]?.stringValue, let job = AIJobs.shared.job(id) else { throw AIToolError("No stop-check job: \(result.payload)") }
    require(AIKeepAwake.shared.holders == awakeBefore + 1 && AIKeepAwake.shared.isHolding,
            "a running AI job holds the keep-awake assertion (holders \(AIKeepAwake.shared.holders), before \(awakeBefore))")
    var live: JSONValue = [:]
    for _ in 0..<1_000 {
        live = AIJobs.shared.json(job)
        if live["batches_done"] == 1 && live["batches_running"] == 2 && live["batches_waiting"] == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    require(live["batches_done"] == 1 && live["batches_running"] == 2 && live["batches_waiting"] == 2,
            "before the stop: one batch done, two on Sky Studio, two waiting for a slot (got \(live["batches_done"] ?? .null) / "
            + "\(live["batches_running"] ?? .null) / \(live["batches_waiting"] ?? .null))")

    AIJobs.shared.cancel(job)
    let stopped = try await fixture.wait(result)
    let message = stopped["message"]?.stringValue ?? ""
    require(stopped["status"] == "cancelled", "stopping ends the job as cancelled (got \(stopped["status"] ?? .null))")
    require(message.hasPrefix("Stopped. By batch_index (from 0): ") && message.contains("0 finished")
            && message.contains("1 had already started on Sky Studio and could not be cancelled")
            && message.contains("2 stopped before Sky Studio started (credits returned)") && message.contains("3, 4 never sent (nothing charged)"),
            "the stop message says where each batch stopped (got \(message))")
    require(stopped["recovery_issue"]?.stringValue == message, "the recovery record keeps the same per-batch account")
    require(stopped["unknown_batch_indices"] == [1] && stopped["unknown_line_indices"] == [1],
            "the line of the batch whose outcome is unknown is listed per line too (got \(stopped["unknown_line_indices"] ?? .null))")
    require(stopped["pending_recovery_line_indices"] == [0] && stopped["not_generated_line_indices"] == [2, 3, 4]
            && stopped["completed_line_indices"] == [], "every line is in exactly the list its batch is in")
    require(VoiceRecoveryHTTP.posts == 3, "the two batches waiting for a slot were never sent (\(VoiceRecoveryHTTP.posts) POSTs)")
    require(AIKeepAwake.shared.holders == awakeBefore, "the stopped job gave its keep-awake lease back")

    // 放开：第 1 批在 Sky Studio 做完（停的时候在后台接着查到底）；普通恢复只 GET 它、两句都收好，不交新的。
    VoiceRecoveryHTTP.release()
    let posts = VoiceRecoveryHTTP.posts
    let recovered = try await fixture.resume(stopped["recovery_file"]?.stringValue ?? "")
    require(recovered["completed_line_indices"] == [0, 1] && recovered["unknown_line_indices"] == [] && VoiceRecoveryHTTP.posts == posts,
            "a plain resume fetches the started batch, finishes its line and sends nothing new (got \(recovered["completed_line_indices"] ?? .null))")
    require(AIKeepAwake.shared.holders == awakeBefore, "the resume job gave its keep-awake lease back")
}
