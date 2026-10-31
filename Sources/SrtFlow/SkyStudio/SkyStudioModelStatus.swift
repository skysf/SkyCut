import Foundation
import SrtFlowMCPKit

// MARK: - AI 只读查询模型和完整素材限制；不消费积分。
@MainActor
enum SkyStudioModelStatus {
    static func read(model: String?) async -> JSONValue {
        let key: String
        switch await SkyStudioJobKey.key(.silent) {
        case .success(let value): key = value
        case .failure(let problem): return ["available": false, "message": .string(problem.message)]
        }
        do {
            let catalog = try await SkyStudioCatalogCache.shared.catalog(key: key)
            let entries = catalog.models.filter { model == nil || $0.id == model }
            return ["models": .array(entries.map(\.json)), "selection_guidance": .string(SkyStudioModelPolicy.guidance),
                    "billing_policy": catalog.billingPolicy ?? .null,
                    "billing_note": .string(SkyStudioBilling.policyMessage),
                    "price_note": "Catalog prices are display only; generate_media quotes exact inputs before spending credits."]
        } catch let failure as SkyStudioFailure {
            return ["available": false, "message": .string(SkyStudioJobError.request(failure).message)]
        } catch {
            return ["available": false, "message": .string(error.localizedDescription)]
        }
    }
}
