import Foundation
import SrtFlowMCPKit

// 真正过 SkyStudioJobGate：同价同摘要的两种视频不能共用确认码；不是自己的码也不能消费或记账。
@MainActor
func runApprovalChecks() {
    let suite = "com.srtflow.approval-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults)
    store.setDailyLimit(0)
    let text = SkyStudioJobRequest(kind: "text_to_video", model: "minimax-h3", prompt: "waves",
                                   params: ["duration": 5, "resolution": "480p"])
    var image = text
    image.kind = "image_to_video"
    let a = SkyStudioApproval.identity(job: text, credits: 50)
    let b = SkyStudioApproval.identity(job: image, credits: 50)
    func decide(_ identity: String, token: String? = nil) throws -> SkyStudioJobGate.Decision {
        try SkyStudioJobGate.decide(credits: 50, summary: "MiniMax H3 · 5 s · 480p", identity: identity,
                                   args: AIToolArguments(.object(token.map { ["confirm_token": .string($0)] } ?? [:])), store: store)
    }
    func asked(_ decision: SkyStudioJobGate.Decision?) -> AIToolResult? {
        if case .needsConfirmation(let ask) = decision { return ask }
        return nil
    }
    let first = asked(try? decide(a))
    let second = asked(try? decide(b))
    let tokenA = first?.payload["confirm_token"]?.stringValue ?? ""
    let tokenB = second?.payload["confirm_token"]?.stringValue ?? ""
    check(!tokenA.isEmpty && !tokenB.isEmpty && tokenA != tokenB, "same quote and summary, different kind: distinct codes")
    checkEqual(asked(try? decide(a))?.payload["confirm_token"]?.stringValue, tokenA, "same request still waiting: same code")
    let wrong = asked(try? decide(b, token: tokenA))
    check(wrong?.payload["confirm_token_refused"]?.stringValue?.contains("different request") == true, "another generation's code is refused")
    checkEqual(store.spentToday(), 0, "wrong code does not reserve credits")
    if case .reserved = try? decide(a, token: tokenA) { check(true, "original code was left untouched") }
    else { check(false, "original code was left untouched") }
    checkEqual(store.spentToday(), 50, "only the accepted request was recorded")
    check(asked(try? decide(a, token: tokenA))?.payload["confirm_token_refused"]?.stringValue?.contains("already used") == true,
          "accepted code remains single use")

    var changed = text
    changed.prompt = "a different shot"
    check(a != SkyStudioApproval.identity(job: changed, credits: 50), "prompt binds the code")
    changed = text; changed.params["aspect_ratio"] = "9:16"
    check(a != SkyStudioApproval.identity(job: changed, credits: 50), "every parameter binds the code")
    changed = text; changed.model = "new-model"
    check(a != SkyStudioApproval.identity(job: changed, credits: 50), "model id binds the code")
    changed = text; changed.idempotencyKey = "another-random-key"; changed.maxCredits = 50
    checkEqual(a, SkyStudioApproval.identity(job: changed, credits: 50), "new submission nonce does not make a different approval")
    check(SkyStudioApproval.identity(job: text, credits: 1.31) != SkyStudioApproval.identity(job: text, credits: 1.32), "exact credits, not rounded display")
    check(SkyStudioApproval.identity(job: text, credits: 50, context: ["frame": "a.png"]) !=
          SkyStudioApproval.identity(job: text, credits: 50, context: ["frame": "b.png"]), "local input binds the code")
    checkEqual(SkyStudioApproval.identity(job: text, credits: 50, context: ["a": 1, "b": 2]),
               SkyStudioApproval.identity(job: text, credits: 50, context: ["b": 2, "a": 1]), "dictionary order is irrelevant")

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-approval-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        try Data("original".utf8).write(to: file)
        let before = try SkyStudioApproval.file(file)
        try Data("changed content".utf8).write(to: file)
        let after = try SkyStudioApproval.file(file)
        check(before != after, "same path overwritten: the input identity changes")
        checkEqual(after, try SkyStudioApproval.file(file), "unchanged input: stable identity")
    } catch { check(false, "input identity check: \(error)") }
}
