import Foundation
import SrtFlowMCPKit

// 图片操作必须真正过共享预算 / 确认闸；换角度、倍率、文件、模型或精确报价都不能复用旧令牌。
@MainActor
func runImageApprovalChecks() {
    let suite = "com.srtflow.image-approval-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkyStudioSpendStore(defaults: defaults), access = AIAccessStore(defaults: defaults)
    store.setDailyLimit(1_000)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("image-approval-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        try Data("source image".utf8).write(to: file)
        let originalFile = try SkyStudioApproval.file(file)
        try Data("changed source image".utf8).write(to: file)
        let changedFile = try SkyStudioApproval.file(file)
        for operation in ["camera_angle", "upscale"] {
            let request = SkyStudioJobRequest(kind: "image", model: operation == "upscale" ? "image-upscale" : "qwen-angles",
                params: operation == "upscale" ? ["upscale_factor": "x2"] : ["resolution": "2K", "aspect_ratio": "16:9", "camera_angle": ["rotate": 135, "tilt": 0, "zoom": 0]], operation: operation)
            func identity(_ job: SkyStudioJobRequest, credits: Double = 60, source: JSONValue? = nil) -> String {
                SkyStudioApproval.identity(job: job, credits: credits, context: ["references": .array([source ?? originalFile]), "folder": "/tmp/generated"])
            }
            func gate(_ value: String, token: String? = nil, credits: Double = 60) throws -> SkyStudioJobGate.Decision {
                try SkyStudioJobGate.decide(credits: credits, summary: "Image operation", identity: value,
                    args: AIToolArguments(.object(token.map { ["confirm_token": .string($0)] } ?? [:])), store: store, access: access, reason: "Paid image specification upgrade")
            }
            func question(_ decision: SkyStudioJobGate.Decision?) -> AIToolResult? {
                if case .needsConfirmation(let result) = decision { return result }; return nil
            }
            let original = identity(request)
            let token = question(try gate(original))?.payload["confirm_token"]?.stringValue ?? ""
            check(!token.isEmpty, "image operation receives a real approval token: \(operation)")
            checkEqual(question(try gate(original))?.payload["confirm_token"]?.stringValue, token, "unchanged operation reuses waiting token")
            var variants: [(SkyStudioJobRequest, Double, JSONValue)] = []
            var model = request; model.model = "another-model"; variants.append((model, 60, originalFile))
            var route = request; route.operation = "generate"; variants.append((route, 60, originalFile))
            variants.append((request, 60.01, originalFile)); variants.append((request, 60, changedFile))
            if operation == "camera_angle" {
                for (axis, value) in [("rotate", -135), ("tilt", 45), ("zoom", 2)] {
                    var changed = request; var angle = changed.params["camera_angle"]!.objectValue!
                    angle[axis] = .number(Double(value)); changed.params["camera_angle"] = .object(angle)
                    variants.append((changed, 60, originalFile))
                }
            } else {
                for factor in ["x3", "x4"] { var changed = request; changed.params["upscale_factor"] = .string(factor); variants.append((changed, 60, originalFile)) }
            }
            let spent = store.spentToday()
            for (changed, price, source) in variants {
                let refused = question(try gate(identity(changed, credits: price, source: source), token: token, credits: price))
                check(refused?.payload["confirm_token_refused"]?.stringValue?.contains("different request") == true, "old token refuses changed operation identity: \(operation)")
                checkEqual(store.spentToday(), spent, "changed identity never reserves credits")
            }
            // 硬预算在令牌消费之前：即使手持原码、全部权限，也不能越过。
            store.setDailyLimit(0)
            for mode in [AIAccessMode.ask, .full] {
                access.setMode(mode)
                let blocked = question(try gate(original, token: token))
                checkEqual(blocked?.payload["code"], "daily_budget_exceeded", "image operation keeps hard daily budget: \(operation)")
                check(blocked?.payload["confirm_token"] == nil, "budget cannot issue bypass token")
            }
            store.setDailyLimit(1_000); access.setMode(.ask)
            if case .reserved = try gate(original, token: token) { check(true, "wrong requests/budget block left original token untouched") }
            else { check(false, "original approval remains redeemable") }
            checkEqual(store.spentToday(), spent + 60, "only original approved operation reserves credits")
        }
    } catch { check(false, "image approval checks: \(error)") }
}
