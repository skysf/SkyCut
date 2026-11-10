import Foundation
import SrtFlowMCPKit

// 六个写动作共用的参数计划：按动作先全验，再交给上传 / API；这里不读文件、不花积分。
struct SkyStudioCharacterPlan: Sendable {
    enum Action: String, CaseIterable, Sendable { case create, importViews = "import", update, replaceView = "replace_view", headshot, delete }
    var action: Action
    var job: SkyStudioJobRequest?
    var mutation: SkyStudioCharacterMutation?
    var files: [SkyStudioReference]
    var quote: SkyStudioQuote?
    var isPaid: Bool { action == .create || action == .headshot }
    var title: String

    static func action(_ args: AIToolArguments) throws -> Action {
        guard let value = try args.choice("action", from: Action.allCases.map(\.rawValue)), let action = Action(rawValue: value) else { throw AIToolError("action is required.") }
        var allowed: Set<String> = ["action", "confirm_token", "project", "resume", "idempotency_key"]
        switch action {
        case .create: allowed.formUnion(["source_type", "prompt", "image", "model", "resolution", "locale", "quote_only", "approval_scope", "user_requested_overrides", "user_request"])
        case .importViews: allowed.formUnion(["roles", "name", "voice_description", "notes", "locale", "quote_only"])
        case .update: allowed.formUnion(["character_id", "character_revision", "name", "voice_description", "locale"])
        case .replaceView: allowed.formUnion(["character_id", "character_revision", "image", "role"])
        case .headshot: allowed.formUnion(["character_id", "character_revision", "model", "resolution", "quote_only", "approval_scope", "user_requested_overrides", "user_request"])
        case .delete: allowed.formUnion(["character_id", "character_revision"])
        }
        let extra = Set(args.raw.objectValue?.filter { !$0.value.isNull }.map(\.key) ?? []).subtracting(allowed)
        guard extra.isEmpty else { throw AIToolError("action=\(action.rawValue) does not accept: \(extra.sorted().joined(separator: ", ")). Nothing was changed.") }
        return action
    }

    static func paths(_ args: AIToolArguments, resolve: (String) -> URL) throws -> [(role: String, url: URL)] {
        let action = try self.action(args)
        if action == .importViews {
            guard let roles = args.raw["roles"]?.objectValue else { throw AIToolError("Import requires local front/side/back image paths in roles.") }
            guard Set(roles.keys).isSubset(of: Set(SkyStudioCharacter.roles)) else { throw AIToolError("Import roles are front/side/back and optional headshot.") }
            return try SkyStudioCharacter.roles.compactMap { role in
                guard let value = roles[role] else { return nil }
                guard let path = value.stringValue, !path.isEmpty else { throw AIToolError("roles.\(role) must be a local image path.") }
                return (role, resolve(path))
            }
        }
        if let path = try args.string("image") { return [(action == .replaceView ? try args.requiredString("role") : "image_url", resolve(path))] }
        return []
    }

    static func make(_ args: AIToolArguments, capabilities: SkyStudioCharacterCapabilities, saved: SkyStudioCharacter?, files: [SkyStudioReference]) throws -> Self {
        let action = try self.action(args)
        let name = try limited(args, "name", maximum: 80)
        let voice = try limited(args, "voice_description", maximum: 220)
        let notes = try limited(args, "notes", maximum: capabilities.promptLimit)
        let prompt = try limited(args, "prompt", maximum: capabilities.promptLimit)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var fields: [String: JSONValue] = [:]
        for (key, value) in [("name", name), ("voice_description", voice), ("notes", notes), ("locale", try args.string("locale"))] {
            if let value { fields[key] = .string(value) }
        }
        var plan = Self(action: action, files: files, title: name ?? saved?.json["name"]?.stringValue ?? String(prompt.prefix(60)))
        if action == .create || action == .headshot {
            let selection = try capabilities.select(model: args.string("model"), resolution: args.string("resolution"), saved: action == .headshot ? saved : nil)
            fields["model"] = .string(selection.model); fields["params"] = ["resolution": .string(selection.resolution)]
            var job = SkyStudioJobRequest(kind: "image", model: selection.model, params: ["resolution": .string(selection.resolution)])
            if action == .create {
                let source = try args.choice("source_type", from: ["text", "reference_upload"]) ?? (files.isEmpty ? "text" : "reference_upload")
                guard source != "text" || (!prompt.isEmpty && files.isEmpty), source != "reference_upload" || files.count == 1 else { throw AIToolError("Text creation needs prompt and no photo; reference_upload needs exactly one still photo.") }
                fields["source_type"] = .string(source)
                if !prompt.isEmpty { fields["prompt"] = .string(prompt) }
                job.nativeCharacter = .init(operation: .create, fields: fields)
            } else {
                guard let saved, saved.json["status"] == "ready", saved.images["front"] != nil else { throw AIToolError("character_not_ready: headshot needs a ready front view.") }
                if let revision = try args.string("character_revision"), revision != saved.revision { throw SkyStudioCharacterError.changed }
                fields["character_id"] = .string(saved.id)
                job.character = .init(id: saved.id, roles: ["front"], revision: saved.revision)
                job.nativeCharacter = .init(operation: .headshot, fields: fields)
            }
            plan.job = job
        } else if action == .importViews {
            guard Set(capabilities.requiredRoles).isSubset(of: Set(files.map(\.role))) else { throw AIToolError("Import requires all views in capabilities.required_import_roles; headshot is optional.") }
            var job = SkyStudioJobRequest(kind: "image", model: "")
            job.nativeCharacter = .init(operation: .importViews, fields: fields)
            plan.job = job
        } else {
            let id = try args.requiredString("character_id"), revision = try args.requiredString("character_revision")
            guard UUID(uuidString: id) != nil, SkyStudioCharacter.isRevision(revision) else { throw AIToolError("Use a full character_id and latest opaque character_revision.") }
            if let saved, saved.revision != revision { throw SkyStudioCharacterError.changed }
            fields["character_revision"] = .string(revision)
            if action == .update, name == nil && voice == nil { throw AIToolError("Update needs name or voice_description; locale alone is not an edit.") }
            if action == .replaceView, files.count != 1 { throw AIToolError("replace_view requires exactly one local image.") }
            let role = action == .replaceView ? try args.choice("role", from: SkyStudioCharacter.roles) : nil
            if action == .replaceView, role == nil { throw AIToolError("replace_view requires role.") }
            plan.mutation = .init(id: id.lowercased(), method: action == .delete ? "DELETE" : action == .replaceView ? "PUT" : "PATCH", role: role, body: fields)
        }
        return plan
    }

    mutating func accept(_ quote: SkyStudioQuote) throws {
        guard var job else { return }
        guard quote.credits.isFinite, quote.credits >= 0 else { throw SkyStudioFailure.badAnswer(status: 200) }
        if isPaid {
            guard let model = quote.model, let resolution = quote.effectiveParams["resolution"]?.stringValue else { throw SkyStudioFailure.badAnswer(status: 200) }
            job.model = model; job.params = ["resolution": .string(resolution)]
            job.nativeCharacter?.fields["model"] = .string(model); job.nativeCharacter?.fields["params"] = .object(job.params)
        } else if quote.credits != 0 { throw SkyStudioFailure.badAnswer(status: 200) }
        if let character = job.character {
            guard let usage = quote.characterUsage else { throw SkyStudioFailure.badAnswer(status: 200) }
            job.character = try character.quoted(usage, localImages: 0)
        }
        job.maxCredits = quote.credits
        self.job = job; self.quote = quote
    }

    private static func limited(_ args: AIToolArguments, _ field: String, maximum: Int) throws -> String? {
        guard let text = try args.string(field) else { return nil }
        guard text.utf16.count <= maximum else { throw AIToolError("\(field) exceeds \(maximum) UTF-16 code units.") }
        return text
    }
}
