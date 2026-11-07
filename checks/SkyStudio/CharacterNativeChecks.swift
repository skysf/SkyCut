import Foundation
import SrtFlowMCPKit

// 真正执行生产 Workflow / API，对六种动作的实际 wire body 逐字段对账。
@MainActor
func runCharacterNativeChecks() async {
    let api = SkyStudioAPI(session: SkyStudioStub.session)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("character-native-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let photo = try writeCharacterPhoto(folder)
        let files = try await SkyStudioCharacterWorkflow.measure([("image_url", photo)], creatingPhoto: true)
        let capabilities = try SkyStudioCharacterCapabilities(json: characterCapabilitiesJSON())
        let saved = try SkyStudioCharacter(json: characterJSON())
        SkyStudioStub.reset { request in
            let body = request.body.flatMap { try? JSONValue.decode($0) } ?? .null
            if request.url.contains("/quote") { return .http(200, characterQuoteJSON(body).encodedString()) }
            if request.url.contains("/uploads") {
                return .http(200, JSONValue.object(["upload_url": "https://upload.example/put", "file_url": "https://assets.example/originals/user/skycut/photo.png",
                    "method": "PUT", "headers": ["Content-Type": "image/png", "Cache-Control": "public, max-age=3600"]]).encodedString())
            }
            if request.url.contains("upload.example") { return .data(200, Data()) }
            return .http(202, nativeCharacterStatus(operation: request.url.hasSuffix("/headshot") ? "character_headshot" : "character_create").encodedString())
        }
        let workflow = SkyStudioCharacterWorkflow(api: api, key: "test")
        var text = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "create", "prompt": "Silver-haired pilot", "locale": "en"]), capabilities: capabilities, saved: nil, files: [])
        text = try await workflow.quote(text)
        checkEqual(try JSONValue.decode(SkyStudioStub.log[0].body!), ["kind": "image", "operation": "character_create", "model": "nano2", "source_type": "text", "prompt": "Silver-haired pilot", "params": ["resolution": "2K"], "locale": "en"], "native text quote exactly matches contract")
        checkEqual(SkyStudioStub.log.count, 1, "native quote does not upload, reserve, insert or POST a Character")
        text.job!.idempotencyKey = "native-text"
        _ = try await api.submit(text.job!, key: "test")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["model": "nano2", "source_type": "text", "prompt": "Silver-haired pilot", "params": ["resolution": "2K"], "locale": "en", "max_credits": 29, "idempotency_key": "native-text"], "text create body omits kind/operation and takes one native route")
        check(SkyStudioStub.log.last!.url.hasSuffix("/characters/create"), "creation uses exactly /characters/create")

        var reference = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "create", "image": .string(photo.path), "prompt": "Keep likeness"]), capabilities: capabilities, saved: nil, files: files)
        reference = try await workflow.quote(reference)
        let before = SkyStudioStub.log.count
        reference = try await workflow.upload(reference, approvedFiles: [SkyStudioApproval.file(photo)])
        reference.job!.idempotencyKey = "native-photo"
        _ = try await api.submit(reference.job!, key: "test")
        checkEqual(SkyStudioStub.log.count - before, 3, "photo creation uploads once and submits once")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["model": "nano2", "source_type": "reference_upload", "prompt": "Keep likeness", "params": ["resolution": "2K"],
            "inputs": ["image_url": "https://assets.example/originals/user/skycut/photo.png"], "max_credits": 39, "idempotency_key": "native-photo"], "photo body matches contract with one snapshot input")
        check(!SkyStudioStub.log.contains { $0.url.contains("/jobs") && $0.method == "POST" }, "native create never also posts ordinary /jobs")
        let put = SkyStudioStub.log.first { $0.method == "PUT" }!
        check(put.headers["Authorization"] == nil && put.headers["Cache-Control"] == "public, max-age=3600", "native upload preserves signed headers without API Key")

        var headshot = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "headshot", "character_id": .string(characterID)]), capabilities: capabilities, saved: saved, files: [])
        headshot = try await workflow.quote(headshot)
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["kind": "image", "operation": "character_headshot", "character_id": .string(characterID), "model": "nano2", "params": ["resolution": "2K"]], "headshot quote has no prompt/media/aspect_ratio")
        headshot.job!.idempotencyKey = "native-headshot"
        _ = try await api.submit(headshot.job!, key: "test")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["model": "nano2", "params": ["resolution": "2K"], "character_revision": .string(characterRevision), "max_credits": 39, "idempotency_key": "native-headshot"], "headshot submission uses exact quoted revision")
        check(SkyStudioStub.log.last!.url.hasSuffix("/characters/\(characterID)/headshot"), "headshot uses its one native route")

        await runCharacterFreeMutationChecks(api: api, capabilities: capabilities, files: files, saved: saved)
        runCharacterInputChecks(capabilities: capabilities, saved: saved, files: files)
    } catch { check(false, "native Character workflow: \(error)") }
}

private func runCharacterInputChecks(capabilities: SkyStudioCharacterCapabilities, saved: SkyStudioCharacter, files: [SkyStudioReference]) {
    do {
        let future = try capabilities.select(model: "future-character-model", resolution: "future-tier", saved: nil)
        checkEqual(future.model, "future-character-model", "native capabilities accept future public model ids")
        checkEqual(future.resolution, "future-tier", "native tiers come from capabilities, not hardcoded 2K/4K")
        var old = saved.json.objectValue!; old["default_generation_model"] = "retired"; old["default_generation_resolution"] = "retired"
        let legacy = try capabilities.select(model: nil, resolution: nil, saved: SkyStudioCharacter(json: .object(old)))
        checkEqual(legacy.model, "nano2", "unsupported legacy default falls back to current capability default")
        checkEqual(legacy.resolution, "2K", "legacy resolution falls back to current capability default")
        let long = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "create", "prompt": .string(String(repeating: "p", count: 25000))]), capabilities: capabilities, saved: nil, files: [])
        checkEqual(long.job?.nativeCharacter?.fields["prompt"]?.stringValue?.utf16.count, 25000, "Character prompt is not ordinary 4000-code-point image prompt")
    } catch { check(false, "native capability defaults: \(error)") }
    let invalid: [JSONValue] = [
        ["action": "create", "prompt": .string(String(repeating: "😀", count: 12501))],
        ["action": "create", "source_type": "text", "prompt": "Pilot", "image": "photo.png"],
        ["action": "headshot", "character_id": .string(characterID), "prompt": "Do not accept"],
        ["action": "headshot", "character_id": .string(characterID), "image": "photo.png"],
        ["action": "create", "prompt": "Pilot", "aspect_ratio": "21:9"],
        ["action": "update", "character_id": .string(characterID), "character_revision": .string(characterRevision), "locale": "en"],
        ["action": "import", "roles": ["front": "photo.png"]]
    ]
    for raw in invalid {
        do {
            let paths = try SkyStudioCharacterPlan.paths(AIToolArguments(raw), resolve: { URL(fileURLWithPath: $0) })
            _ = try SkyStudioCharacterPlan.make(AIToolArguments(raw), capabilities: capabilities, saved: saved,
                files: paths.map { pick in var f = files[0]; f.role = pick.role; return f })
            check(false, "invalid native action rejected atomically: \(raw)")
        } catch { check(true, "invalid native action rejected before upload") }
    }
}

@MainActor
private func runCharacterFreeMutationChecks(api: SkyStudioAPI, capabilities: SkyStudioCharacterCapabilities, files: [SkyStudioReference], saved: SkyStudioCharacter) async {
    do {
        SkyStudioStub.reset { request in
            if request.url.hasSuffix("/quote") { return .http(200, "{\"credits\":0,\"typical_seconds\":0}") }
            if request.url.hasSuffix("/uploads") { return .http(200, "{\"upload_url\":\"https://upload.example/role\",\"file_url\":\"https://assets.example/originals/user/character-roles/role.png\",\"headers\":{\"Content-Type\":\"image/png\",\"Cache-Control\":\"public, max-age=3600\"}}") }
            if request.url.contains("upload.example") { return .data(200, Data()) }
            if request.url.hasSuffix("/import") { return .http(202, nativeCharacterStatus(operation: "character_import", charged: 0).encodedString()) }
            if request.method == "DELETE" { return .http(200, JSONValue.object(["deleted": true, "character_id": .string(characterID)]).encodedString()) }
            return .http(200, JSONValue.object(["character": saved.json]).encodedString())
        }
        let workflow = SkyStudioCharacterWorkflow(api: api, key: "test")
        var importedFiles = [SkyStudioReference]()
        for role in ["front", "side", "back"] { var file = files[0]; file.role = role; importedFiles.append(file) }
        var imported = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "import", "name": "Pilot", "voice_description": "Calm", "locale": "en"]), capabilities: capabilities, saved: nil, files: importedFiles)
        imported = try await workflow.quote(imported)
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["operation": "character_import"], "free import quote is exactly its operation, no image model marker")
        let identity = try importedFiles.map { try SkyStudioApproval.file($0.file) }
        imported = try await workflow.upload(imported, approvedFiles: identity)
        imported.job!.idempotencyKey = "native-import"
        let done = try await workflow.run(imported.job!, checkpoint: { _ in })
        check(done.characterID == nativeCharacterJobID && done.result == nil, "free ready import succeeds without a generated source image URL")
        let asset: JSONValue = ["assetKey": "originals/user/character-roles/role.png", "publicUrl": "https://assets.example/originals/user/character-roles/role.png", "mimeType": "image/png", "sizeBytes": .number(files[0].bytes)]
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["idempotency_key": "native-import", "name": "Pilot", "voice_description": "Calm", "locale": "en", "roles": ["front": asset, "side": asset, "back": asset]], "import descriptors and metadata exactly match contract")
        for upload in SkyStudioStub.log.filter({ $0.url.hasSuffix("/uploads") }) {
            checkEqual(try JSONValue.decode(upload.body!), ["purpose": "character_role", "content_type": "image/png", "bytes": .number(files[0].bytes)], "role upload ticket omits photo filename and uses character_role")
        }
        var update = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "update", "character_id": .string(characterID), "character_revision": .string(characterRevision), "name": "Captain", "voice_description": "", "locale": "en"]), capabilities: capabilities, saved: nil, files: [])
        _ = try await api.mutateCharacter(update.mutation!, key: "test")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["character_revision": .string(characterRevision), "name": "Captain", "voice_description": "", "locale": "en"], "PATCH metadata preserves explicit clear and revision")
        checkEqual(SkyStudioStub.log.last!.method, "PATCH", "metadata uses PATCH")
        update = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "replace_view", "character_id": .string(characterID), "character_revision": .string(characterRevision), "image": "photo.png", "role": "front"]), capabilities: capabilities, saved: nil, files: files)
        update = try await workflow.upload(update, approvedFiles: [SkyStudioApproval.file(files[0].file)])
        _ = try await api.mutateCharacter(update.mutation!, key: "test")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["character_revision": .string(characterRevision), "asset": asset], "view replacement PUT body is exact")
        check(SkyStudioStub.log.last!.url.hasSuffix("/images/front"), "view replacement path retains role")
        let deletion = try SkyStudioCharacterPlan.make(AIToolArguments(["action": "delete", "character_id": .string(characterID), "character_revision": .string(characterRevision)]), capabilities: capabilities, saved: nil, files: [])
        _ = try await api.mutateCharacter(deletion.mutation!, key: "test")
        checkEqual(try JSONValue.decode(SkyStudioStub.log.last!.body!), ["character_revision": .string(characterRevision)], "DELETE body carries only expected revision")
        checkEqual(SkyStudioStub.log.last!.method, "DELETE", "deletion uses protected native endpoint")
    } catch { check(false, "free Character writes: \(error)") }
}
