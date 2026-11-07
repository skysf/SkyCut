import Foundation
import SrtFlowMCPKit

// get_job 共用末端边界：即使完成快照 / 后续刷新重新并入旧阶段，也不能把结局说成还在排队。
func runJobResultChecks() {
    let stale: [String: JSONValue] = ["phase": "processing", "phase_seconds": 500, "queue_position": 1,
        "transfer_percent": 30, "progress": 0.3, "waiting_for_user": "old", "file": "house.png", "credits_charged": 8]
    for status in ["done", "failed", "cancelled"] {
        let result = AIJobResult.json(stale, status: status)
        check(result["phase"] == nil && result["queue_position"] == nil && result["phase_seconds"] == nil,
            "\(status) cannot expose a stale in-progress phase")
        check(result["transfer_percent"] == nil && result["progress"] == nil && result["waiting_for_user"] == nil,
            "\(status) cannot expose stale progress or a resolved user wait")
        checkEqual(result["file"], "house.png", "terminal cleanup preserves the delivered file")
        checkEqual(result["credits_charged"], 8, "terminal cleanup preserves actual billing")
    }
    checkEqual(AIJobResult.json(stale, status: "running"), .object(stale), "active jobs retain the complete live phase")
    checkEqual(AIJobResult.json(stale, status: "queued"), .object(stale), "queued jobs retain their real queue position")
}
