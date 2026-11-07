import Foundation
import SrtFlowMCPKit

// 真过现有确认 / 预算闸，角色、revision、视图、模式、报价任一变化都不能消费旧令牌。
@MainActor
func runCharacterApprovalChecks() {
    let suite = "com.srtflow.character-approval-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults), access = AIAccessStore(defaults: defaults)
    store.setDailyLimit(1000)
    let original = SkyStudioJobRequest(kind: "image_to_video", model: "video", prompt: "Pilot turns", params: ["mode": "multimodal"],
        character: .init(id: characterID, roles: ["front", "side"], revision: characterRevision))
    func gate(_ job: SkyStudioJobRequest, credits: Double = 60, token: String? = nil) throws -> SkyStudioJobGate.Decision {
        try SkyStudioJobGate.decide(credits: credits, summary: "Pilot views", identity: SkyStudioApproval.identity(job: job, credits: credits),
            args: AIToolArguments(.object(token.map { ["confirm_token": .string($0)] } ?? [:])), store: store, access: access,
            reason: "Upgrade specification")
    }
    do {
        guard case .needsConfirmation(let question) = try gate(original), let token = question.payload["confirm_token"]?.stringValue else {
            check(false, "character approval issues a real token"); return
        }
        var changed = original; changed.character?.revision = String(repeating: "b", count: 64)
        var views = original; views.character?.roles = ["front", "back"]
        var mode = original; mode.params["mode"] = "frames"
        var character = original; character.character?.id = "22222222-2222-4222-8222-222222222222"
        for variant in [changed, views, mode, character] {
            if case .needsConfirmation(let refused) = try gate(variant, token: token) {
                check(refused.payload["confirm_token_refused"] != nil, "changed character identity refuses old confirmation")
            } else { check(false, "changed character identity needs fresh approval") }
            checkEqual(store.spentToday(), 0, "stale approval never reserves credits")
        }
        if case .needsConfirmation(let refused) = try gate(original, credits: 61, token: token) {
            check(refused.payload["confirm_token_refused"] != nil, "price change needs fresh approval")
        } else { check(false, "price change needs fresh approval") }
        store.setDailyLimit(0)
        if case .needsConfirmation(let blocked) = try gate(original, token: token) {
            checkEqual(blocked.payload["code"], "daily_budget_exceeded", "character generation keeps the hard budget")
        }
        store.setDailyLimit(1000)
        if case .reserved = try gate(original, token: token) { check(true, "wrong identity did not consume original approval") }
        else { check(false, "original confirmation is still valid") }
        let accountQuestion = AIConfirmations.shared.ask("Character approval", action: "skystudio:character-test")
        let accountToken = accountQuestion.payload["confirm_token"]!.stringValue!
        let stamp = SkyStudioCharacterAccess.stamp("same-key")
        SkyStudioCharacterAccess.invalidate()
        check(stamp != SkyStudioCharacterAccess.stamp("same-key"), "account invalidation advances epoch even for the same Key")
        checkEqual(AIConfirmations.shared.redeem(accountToken, for: "skystudio:character-test"), .refused(.unknown), "account changes clear pending paid approvals")
    } catch { check(false, "Character approval checks: \(error)") }
}
