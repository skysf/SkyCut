import Foundation
import SrtFlowMCPKit

// 源图、角色整理、扣费三份独立事实；成功源图不会因为裁图 / 存储失败而被说成退款或需要重生成。
enum SkyStudioCharacterJobReport {
    static func fields(_ status: SkyStudioJobStatus, freeImport: Bool) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["skystudio_job_id": .string(status.jobID),
            "skystudio_status": status.state.map { .string($0.rawValue) } ?? .null,
            "character_id": status.characterID.map(JSONValue.string) ?? .null,
            "character_operation": status.characterOperation.map(JSONValue.string) ?? .null,
            "character_status": status.characterStatus.map(JSONValue.string) ?? .null,
            "generation_status": status.generationStatus.map(JSONValue.string) ?? (freeImport ? "not_submitted" : .null),
            "delivery_status": status.deliveryStatus.map(JSONValue.string) ?? .null,
            "cancellable": false]
        if let result = status.characterResult {
            if let character = result["character"] { fields["character"] = character }
            if let url = result["url"] { fields["source_result_url"] = url }
        }
        if let usage = status.characterUsage { fields["character_usage"] = usage.json }
        if let billing = status.billing { fields["billing"] = billing.json }
        if freeImport {
            fields["credits_charged"] = 0; fields["credits_unknown"] = false
            fields["billing_note"] = "Free library import; no provider image or wallet mutation. Recover this same import key/job, never create another copy."
        } else {
            fields["credits_unknown"] = .bool(status.billing?.netCharged == nil)
            if let charged = status.billing?.netCharged { fields["credits_charged"] = .number(charged) }
            fields["billing_note"] = .string(status.billing?.message ?? SkyStudioBilling.policyMessage)
        }
        fields["failure"] = status.failure?.json ?? .null
        if status.characterStatus == "ready" {
            fields["next_step"] = "Reuse character_id with generate_media. No role images were inserted on the timeline; no further generation is needed."
        } else if status.generationStatus == "succeeded" {
            fields["next_step"] = "The source image succeeded; Character finalization is unfinished. Query this original get_job to retry only finalization (server interval at least 60 seconds). The source remains charged according to billing. Never generate another source, re-upload or create another Character."
        } else {
            fields["next_step"] = "Keep this original job and idempotency_key. Query get_job for generation, Character finalization and billing separately; do not generate or charge again."
        }
        return fields
    }
}
