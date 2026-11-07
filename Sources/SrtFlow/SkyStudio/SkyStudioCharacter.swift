import Foundation
import SrtFlowMCPKit

// 角色库的公开值合同：保留安全 DTO、服务端 revision 和实际视图选择；不读写图片，不自行计算 revision。
struct SkyStudioCharacter: Equatable, Sendable, Codable {
    static let roles = ["front", "headshot", "side", "back"]
    static let statuses = ["ready", "draft", "generating", "failed", "all"]
    let json: JSONValue
    var id: String { json["id"]!.stringValue! }
    var revision: String { json["revision"]!.stringValue! }
    var images: [String: JSONValue] { json["images"]?.objectValue ?? [:] }

    init(json: JSONValue) throws {
        guard let id = json["id"]?.stringValue, UUID(uuidString: id) != nil,
              let revision = json["revision"]?.stringValue, Self.isRevision(revision),
              json["status"]?.stringValue != nil, json["images"]?.objectValue != nil else {
            throw SkyStudioFailure.badAnswer(status: 200)
        }
        self.json = json
    }

    static func isRevision(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct SkyStudioCharacterPage: Equatable, Sendable {
    var characters: [SkyStudioCharacter]
    var nextCursor: String?
    var json: JSONValue {
        ["characters": .array(characters.map(SkyStudioCharacterSummary.json)), "next_cursor": nextCursor.map(JSONValue.string) ?? .null]
    }
}

/// 请求中的服务器引用。与 SkyStudioReference 的本机 URL 严格分开，永不下载后重新上传。
struct SkyStudioCharacterReference: Equatable, Sendable, Codable {
    var id: String
    var roles: [String]?
    var revision: String?

    static func read(_ args: AIToolArguments) throws -> Self? {
        guard let id = try args.string("character_id") else {
            guard !args.has("character_roles"), !args.has("character_revision") else { throw AIToolError("character_id is required with character_roles/character_revision.") }
            return nil
        }
        guard UUID(uuidString: id) != nil else { throw AIToolError("character_id must be a full UUID, not a file path.") }
        let roles = try args.stringArray("character_roles")
        if let roles, roles.isEmpty || Set(roles).count != roles.count || !roles.allSatisfy(SkyStudioCharacter.roles.contains) {
            throw AIToolError("character_roles must contain unique front/headshot/side/back views; omit it for server selection.")
        }
        let revision = try args.string("character_revision")
        if let revision, !SkyStudioCharacter.isRevision(revision) { throw AIToolError("Use the opaque character_revision returned by Sky Studio.") }
        return Self(id: id.lowercased(), roles: roles, revision: revision)
    }

    func quoted(_ usage: SkyStudioCharacterUsage, localImages: Int) throws -> Self {
        guard usage.id == id, roles == nil || roles == usage.roles,
              usage.referenceImageCount == localImages + usage.roles.count else { throw SkyStudioFailure.badAnswer(status: 200) }
        if let revision, revision != usage.revision { throw SkyStudioCharacterError.changed }
        return Self(id: id, roles: usage.roles, revision: usage.revision)
    }
}

/// reference_image_count 是合并后的图片数；roles 才是这次真正使用的角色视图。mode 由报价给出。
struct SkyStudioCharacterUsage: Equatable, Sendable, Codable {
    var id: String
    var revision: String
    var roles: [String]
    var referenceImageCount: Int
    var mode: String?

    init(json: JSONValue) throws {
        guard let id = json["character_id"]?.stringValue, UUID(uuidString: id) != nil,
              let revision = json["revision"]?.stringValue, SkyStudioCharacter.isRevision(revision),
              let list = json["roles"]?.arrayValue, !list.isEmpty,
              let count = json["reference_image_count"]?.intValue, count >= list.count else { throw SkyStudioFailure.badAnswer(status: 200) }
        let roles = list.compactMap(\.stringValue)
        guard roles.count == list.count, Set(roles).count == roles.count, roles.allSatisfy(SkyStudioCharacter.roles.contains) else { throw SkyStudioFailure.badAnswer(status: 200) }
        let mode = json["mode"]?.stringValue
        guard mode == nil || ["frames", "multimodal"].contains(mode!) else { throw SkyStudioFailure.badAnswer(status: 200) }
        self.id = id.lowercased(); self.revision = revision; self.roles = roles; self.referenceImageCount = count; self.mode = mode
    }

    var json: JSONValue {
        var result: [String: JSONValue] = ["character_id": .string(id), "revision": .string(revision),
            "roles": .array(roles.map(JSONValue.string)), "reference_image_count": .number(Double(referenceImageCount))]
        if let mode { result["mode"] = .string(mode) }
        return .object(result)
    }
}

enum SkyStudioCharacterError {
    static let changed = AIToolError("The character changed. Read get_character and obtain a new quote and approval; nothing new was submitted.",
        details: ["code": "character_changed", "retryable": false])

    static func tool(_ error: Error) -> AIToolError {
        guard case .server(let value)? = error as? SkyStudioFailure else {
            if let tool = error as? AIToolError { return tool }
            if let failure = error as? SkyStudioFailure {
                switch failure {
                case .network(let detail): return AIToolError("Could not reach Sky Studio: \(detail)")
                case .badAnswer(let status): return AIToolError("Sky Studio returned an unexpected answer (HTTP \(status)).")
                case .server(let server): return AIToolError(server.message)
                }
            }
            return AIToolError(error.localizedDescription)
        }
        var fields = value.fields
        fields["code"] = .string(value.code)
        fields["next_step"] = .string(nextStep(value.code))
        return AIToolError(value.message, details: fields)
    }

    static func nextStep(_ code: String) -> String {
        switch code {
        case "character_changed", "price_changed": return "Refresh the character and quote again under a new approval. Do not reuse the old confirmation."
        case "character_not_ready": return "Read get_character or its original get_job; wait for ready. No automatic paid replacement."
        case "not_found": return "Read list_characters for this account; absent and foreign characters are unavailable."
        case "character_checkpoint_failed": return "Preserve job_id and idempotency_key; credits_reserved=0 and submission_state=not_submitted. Read the original job, never create a replacement automatically."
        default: return "Inspect the original operation and billing; do not retry a paid submission automatically."
        }
    }
}
