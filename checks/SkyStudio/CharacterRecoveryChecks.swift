import Foundation
import SrtFlowMCPKit

// 真写回执 / 真跑原生 Workflow。新实例模拟重启，原图已删除也只 GET 旧单，不上传或扣第二次。
@MainActor
final class CharacterReceiptProbe {
    var value: SkyStudioCharacterReceipt
    let directory: URL
    init(_ value: SkyStudioCharacterReceipt, directory: URL) { self.value = value; self.directory = directory }
    func prepared(_ plan: SkyStudioCharacterPlan) throws {
        value.request = plan.job!
        try SkyStudioCharacterReceiptStore.write(value, directory: directory)
    }
    func beforeSubmit() throws {
        value.submissionAttempted = true
        try SkyStudioCharacterReceiptStore.write(value, directory: directory)
    }
    func received(_ status: SkyStudioJobStatus) throws {
        try value.received(status)
        try SkyStudioCharacterReceiptStore.write(value, directory: directory)
    }
}

@MainActor
func runCharacterRecoveryChecks() async {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("character-recovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let api = SkyStudioAPI(session: SkyStudioStub.session)
    do {
        let photo = try writeCharacterPhoto(folder)
        let files = try await SkyStudioCharacterWorkflow.measure([("image_url", photo)], creatingPhoto: true)
        let capabilities = try SkyStudioCharacterCapabilities(json: characterCapabilitiesJSON())
        var completed = false, creates = 0
        SkyStudioStub.reset { request in
            if request.url.hasSuffix("/quote") { return .http(200, characterQuoteJSON(try! JSONValue.decode(request.body!)).encodedString()) }
            if request.url.hasSuffix("/uploads") { return .http(200, "{\"upload_url\":\"https://upload.example/photo\",\"file_url\":\"https://assets.example/originals/user/skycut/photo.png\",\"headers\":{\"Content-Type\":\"image/png\"}}") }
            if request.url.contains("upload.example") { return .data(200, Data()) }
            if request.method == "POST" {
                creates += 1
                return .http(202, JSONValue.object(["job_id": .string(nativeCharacterJobID), "status": "queued", "character_id": .string(nativeCharacterJobID), "character_operation": "character_create", "character_status": "generating", "poll_after_seconds": 2]).encodedString())
            }
            var result = nativeCharacterStatus(state: completed ? "done" : "failed", characterStatus: completed ? "ready" : "finalizing", charged: 39).objectValue!
            if !completed { result["error"] = ["code": "character_finalization_failed", "message": "Original image is charged; recover only its finalization."] }
            return .http(200, JSONValue.object(result).encodedString())
        }
        var workflow = SkyStudioCharacterWorkflow(api: api, key: "test"); workflow.sleep = { _ in }
        let args = AIToolArguments(["action": "create", "image": .string(photo.path), "prompt": "Pilot", "idempotency_key": "recover-photo"])
        var plan = try SkyStudioCharacterPlan.make(args, capabilities: capabilities, saved: nil, files: files)
        plan = try await workflow.quote(plan); plan.job!.idempotencyKey = "recover-photo"
        let record = SkyStudioCharacterReceipt(accountID: "owner", idempotencyKey: "recover-photo", argumentsDigest: SkyStudioCharacterReceipt.arguments(args),
            approvalIdentity: String(repeating: "a", count: 64), request: plan.job!, reservedCredits: 39, reservedDay: Date())
        let directory = folder.appendingPathComponent("receipts")
        try SkyStudioCharacterReceiptStore.write(record, directory: directory, creating: true)
        let probe = CharacterReceiptProbe(record, directory: directory)
        plan = try await workflow.upload(plan, approvedFiles: [SkyStudioApproval.file(photo)], checkpoint: { plan in try await probe.prepared(plan) })
        do {
            _ = try await workflow.run(plan.job!, checkpoint: { status in try await probe.received(status) }, beforeSubmit: { try await probe.beforeSubmit() })
            check(false, "unfinished finalization does not claim Character success")
        } catch let error as SkyStudioJobError {
            check(!error.canRefund(beforeAccepted: false), "successful source image is not refunded for finalization failure")
        }
        let restart = try SkyStudioCharacterReceiptStore.read(record.localID, directory: directory)!
        checkEqual(restart.jobID, nativeCharacterJobID, "receipt retains original job_id")
        checkEqual(restart.characterID, nativeCharacterJobID, "receipt retains admitted Character identity")
        checkEqual(restart.idempotencyKey, "recover-photo", "receipt retains original key")
        checkEqual(restart.approvalIdentity, record.approvalIdentity, "receipt retains approved identity")
        checkEqual(restart.latest["generation_status"], "succeeded", "source success remains independent")
        checkEqual(restart.latest["character_status"], "finalizing", "unfinished Character finalization remains independent")
        checkEqual(restart.latest["credits_charged"], 39, "billing remains charged independently of job failure")
        check(restart.latest["next_step"]?.stringValue?.contains("retry only finalization") == true, "next step never generates another source image")
        checkEqual(restart.recovery(), .originalJob(nativeCharacterJobID), "known original wins before any current character/file resolution")
        let file = try SkyStudioCharacterReceiptStore.url(record.localID, directory: directory)
        checkEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "recovery receipt is private from creation")
        checkEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700, "recovery directory is private")
        try FileManager.default.removeItem(at: photo)
        completed = true
        let before = SkyStudioStub.log.count
        let freshWorkflow = SkyStudioCharacterWorkflow(api: api, key: "replacement-owner-key")
        let resumed = try await freshWorkflow.run(restart.request, resuming: restart.jobID, checkpoint: { _ in })
        checkEqual(resumed.characterStatus, "ready", "new process can recover original Character finalization")
        check(SkyStudioStub.log.dropFirst(before).allSatisfy { $0.method == "GET" }, "restart recovery performs GET only, even with missing local input")
        checkEqual(creates, 1, "restart never creates another Character or charges another source")
        var different = restart; different.jobID = "another-job"
        do { try SkyStudioCharacterReceiptStore.write(different, directory: directory); check(false, "receipt refuses original job overwrite") }
        catch { check(true, "receipt refuses original job overwrite") }
        different = restart; different.request.model = "another-model"
        do { try SkyStudioCharacterReceiptStore.write(different, directory: directory); check(false, "submitted request cannot change") }
        catch { check(true, "submitted request cannot change") }
        await runCharacterUnknownImportChecks(api: api, directory: directory)
        await runCharacterRoleRecoveryChecks(api: api, directory: directory)
        await runCharacterCancellationChecks(api: api, request: restart.request)
    } catch { check(false, "Character restart recovery: \(error)") }
}

@MainActor
private func runCharacterRoleRecoveryChecks(api: SkyStudioAPI, directory: URL) async {
    do {
        let request = SkyStudioJobRequest(kind: "image", model: "", idempotencyKey: "recover-role")
        let asset: JSONValue = ["assetKey": "originals/user/character-roles/once.png", "mimeType": "image/png", "sizeBytes": 100]
        let mutation = SkyStudioCharacterMutation(id: characterID, method: "PUT", role: "front", body: ["character_revision": .string(characterRevision), "asset": asset])
        let receipt = SkyStudioCharacterReceipt(accountID: "owner", idempotencyKey: request.idempotencyKey, argumentsDigest: String(repeating: "a", count: 64),
            approvalIdentity: String(repeating: "b", count: 64), request: request, mutation: mutation, reservedCredits: 0, reservedDay: Date(), submissionAttempted: true, characterID: characterID)
        try SkyStudioCharacterReceiptStore.write(receipt, directory: directory, creating: true)
        let restored = try SkyStudioCharacterReceiptStore.read(receipt.localID, directory: directory)!
        checkEqual(restored.recovery(explicitFreeImport: true), .libraryRead(characterID), "role replacement recovery can only read the library, never replay even for free")
        checkEqual(restored.mutation?.body["asset"], asset, "role receipt preserves already-uploaded asset descriptor")
        checkEqual(restored.operation, "character_replace_view", "role receipt retains exact mutation kind")
        SkyStudioStub.reset { _ in .http(200, JSONValue.object(["character": characterJSON()]).encodedString()) }
        _ = try await api.character(characterID, key: "test")
        check(SkyStudioStub.log.allSatisfy { $0.method == "GET" }, "role outcome inspection does not repeat upload or PUT")
    } catch { check(false, "free role replacement recovery: \(error)") }
}

@MainActor
private func runCharacterUnknownImportChecks(api: SkyStudioAPI, directory: URL) async {
    do {
        var posts = 0
        SkyStudioStub.reset { _ in
            posts += 1
            if posts == 1 { return .failure(.networkConnectionLost) }
            return .http(202, nativeCharacterStatus(operation: "character_import", charged: 0).encodedString())
        }
        let asset: JSONValue = ["assetKey": "originals/user/character-roles/input.png", "mimeType": "image/png", "sizeBytes": 128]
        var request = SkyStudioJobRequest(kind: "image", model: "", idempotencyKey: "lost-free-import")
        request.nativeCharacter = .init(operation: .importViews, fields: ["name": "Pilot", "roles": ["front": asset, "side": asset, "back": asset]])
        let record = SkyStudioCharacterReceipt(accountID: "owner", idempotencyKey: request.idempotencyKey, argumentsDigest: String(repeating: "a", count: 64),
            approvalIdentity: String(repeating: "b", count: 64), request: request, reservedCredits: 0, reservedDay: Date())
        try SkyStudioCharacterReceiptStore.write(record, directory: directory, creating: true)
        let probe = CharacterReceiptProbe(record, directory: directory)
        let workflow = SkyStudioCharacterWorkflow(api: api, key: "test")
        do { _ = try await workflow.run(request, checkpoint: { status in try await probe.received(status) }, beforeSubmit: { try await probe.beforeSubmit() }); check(false, "lost import reply surfaces") }
        catch { checkEqual(posts, 1, "unknown import is not automatically POSTed again") }
        let restored = try SkyStudioCharacterReceiptStore.read(record.localID, directory: directory)!
        checkEqual(restored.recovery(), .unknown, "read-only get_job cannot replay even a free import")
        checkEqual(restored.recovery(explicitFreeImport: true), .freeImport, "explicit free resume can recover original saved import body/key")
        let result = try await workflow.run(restored.request, checkpoint: { status in try await probe.received(status) })
        checkEqual(result.characterID, nativeCharacterJobID, "same import key recovers durable Character")
        checkEqual(try JSONValue.decode(SkyStudioStub.log[0].body!), try JSONValue.decode(SkyStudioStub.log[1].body!), "explicit import recovery reuses exactly the original descriptors/key")
        check(SkyStudioStub.log.allSatisfy { $0.url.hasSuffix("/characters/import") }, "free recovery never uploads again or calls a provider route")
        let fields = SkyStudioCharacterJobReport.fields(result, freeImport: true)
        checkEqual(fields["credits_charged"], 0, "free import recovery stays zero-cost")
        checkEqual(fields["credits_unknown"], false, "free import never invents paid-provider billing uncertainty")
        var paid = restored
        paid.request.nativeCharacter?.operation = .create
        checkEqual(paid.recovery(explicitFreeImport: true), .unknown, "unknown paid submission cannot borrow free import replay")
        paid.submissionAttempted = false
        checkEqual(paid.recovery(), .notSubmitted, "pre-upload interruption reports no admitted job")
        paid.submissionAttempted = true
        try paid.receivedFailure(SkyStudioJobFailure(message: "Checkpoint failed", fields: ["code": "character_checkpoint_failed", "job_id": .string(nativeCharacterJobID)]))
        checkEqual(paid.jobID, nativeCharacterJobID, "an HTTP error's original job_id remains recoverable")
        checkEqual(paid.recovery(), .originalJob(nativeCharacterJobID), "checkpoint failure recovery reads the original job instead of replaying")
        do {
            try paid.receivedFailure(SkyStudioJobFailure(message: "Wrong operation", jobID: "another-job"))
            check(false, "failure evidence cannot replace the original job")
        } catch { check(true, "failure evidence cannot replace the original job") }
    } catch { check(false, "free import recovery: \(error)") }
}

private func runCharacterCancellationChecks(api: SkyStudioAPI, request: SkyStudioJobRequest) async {
    SkyStudioStub.reset { _ in .http(202, JSONValue.object(["job_id": .string(nativeCharacterJobID), "status": "queued"]).encodedString()) }
    var workflow = SkyStudioCharacterWorkflow(api: api, key: "test")
    workflow.sleep = { _ in throw CancellationError() }
    do {
        _ = try await workflow.run(request, checkpoint: { _ in }, onUnstoppable: { _ in })
        check(false, "Character local waiting can stop")
    } catch let error as SkyStudioJobError {
        checkEqual(error, .stopped(.characterContinuing), "Character cancellation accurately reports continuing original job")
        check(!SkyStudioStub.log.contains { $0.url.hasSuffix("/cancel") }, "Character jobs never call forbidden cancel endpoint")
    } catch { check(false, "Character cancellation: \(error)") }
}
