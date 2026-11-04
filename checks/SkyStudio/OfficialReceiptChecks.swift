import Foundation
import SrtFlowMCPKit

// 私有临时目录的真实读写；只验证恢复回执，不碰网络、素材、钱包或钥匙串。
func runOfficialReceiptChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("official-receipts-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let receipt = officialReceiptFixture(root)
        let file = SkyStudioOfficialReceiptStore.url(accountID: receipt.accountID, key: receipt.idempotencyKey, directory: root)
        checkEqual(try SkyStudioOfficialReceiptStore.readIfPresent(at: file), nil, "only missing receipt is absent")
        try SkyStudioOfficialReceiptStore.create(receipt, at: file)
        let restored = try SkyStudioOfficialReceiptStore.readIfPresent(at: file)
        checkEqual(restored, receipt, "unknown submission survives restart without prompt, pin or film")
        check(restored?.submitted == true && restored?.jobID == nil, "unknown accepted outcome remains a tombstone, not permission to POST")
        receiptRefuses("unknown no-ID receipt cannot be recreated") { try SkyStudioOfficialReceiptStore.create(receipt, at: file) }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        checkEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "receipt permissions600")
        checkEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "receipt directory permissions700")
        let unusual = SkyStudioOfficialReceiptStore.url(accountID: "account-a", key: "../../other/file", directory: root)
        checkEqual(unusual.deletingLastPathComponent(), root, "idempotency text cannot escape receipt directory")
        check(unusual.lastPathComponent.range(of: #"\A[a-f0-9]{64}\.json\z"#, options: .regularExpression) != nil, "filename is a SHA256 digest")
        check(file != SkyStudioOfficialReceiptStore.url(accountID: "another-account", key: receipt.idempotencyKey, directory: root), "receipt namespace includes account")
        check(SkyStudioOfficialReceiptStore.url(accountID: "a\u{0}b", key: "c", directory: root) !=
              SkyStudioOfficialReceiptStore.url(accountID: "a", key: "b\u{0}c", directory: root), "namespace separators cannot alias distinct account/key pairs")
        try runReceiptEvidenceChecks(receipt, file: file, root: root)
        try runReceiptCorruptionChecks(receipt, file: file)
        try runReceiptConcurrentCreateChecks(root)
        try runReceiptRejectionChecks(root)
    } catch { check(false, "official receipt checks: \(error)") }
}

private func runReceiptRejectionChecks(_ root: URL) throws {
    var receipt = officialReceiptFixture(root, key: "confirmed-no-admission")
    let file = SkyStudioOfficialReceiptStore.url(accountID: receipt.accountID, key: receipt.idempotencyKey, directory: root)
    try SkyStudioOfficialReceiptStore.create(receipt, at: file)
    try receipt.rejectedBeforeAdmission("recipe_unavailable")
    try SkyStudioOfficialReceiptStore.write(receipt, at: file)
    let restored = try SkyStudioOfficialReceiptStore.readIfPresent(at: file)
    check(restored?.submissionRejection == "recipe_unavailable" && restored?.submitted == true && restored?.jobID == nil,
          "explicit no-admission evidence survives restart without reopening POST")
    receiptRefuses("known no-admission receipt cannot be recreated") { try SkyStudioOfficialReceiptStore.create(receipt, at: file) }
    var next = receipt; next.submissionRejection = nil
    receiptRefuses("known no-admission evidence cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = receipt
    receiptRefuses("known no-admission code cannot change") { try next.rejectedBeforeAdmission("local_not_sent") }
    receiptRefuses("known no-admission cannot become an accepted job") { try next.received(.init(jobID: "late-replacement", state: .queued)) }
    next = officialReceiptFixture(root, key: "unknown-outcome")
    receiptRefuses("transport failure does not prove no admission") { try next.rejectedBeforeAdmission("network_error") }
    try next.received(.init(jobID: "accepted-original", state: .queued))
    receiptRefuses("accepted job cannot be recorded as not submitted") { try next.rejectedBeforeAdmission("local_not_sent") }
    for code in SkyStudioJobAdmission.rejectedCodes.union(["local_not_sent"]) {
        var untouched = officialReceiptFixture(root)
        try untouched.rejectedBeforeAdmission(code)
        checkEqual(untouched.submissionRejection, code, "canonical admission rejection is preserved: " + code)
    }
}

private func officialReceiptFixture(_ root: URL, key: String = "original-operation") -> SkyStudioOfficialReceipt {
    .init(accountID: "account-a", projectPath: "/private/tmp/test-film.skycut", idempotencyKey: key,
          argumentsDigest: String(repeating: "a", count: 64), renderDigest: String(repeating: "b", count: 64),
          kind: "image_to_video", modelID: "synthetic-video", modelTitle: "Synthetic video", params: ["duration": 5, "mode": "frames"],
          folder: root, stem: "original-shot", reservedCredits: 10, reservedDay: Date(timeIntervalSince1970: 1_800_000_000))
}

private func receiptRefuses(_ label: String, _ body: () throws -> Void) {
    do { try body(); check(false, label) } catch { check(true, label) }
}

private func runReceiptEvidenceChecks(_ receipt: SkyStudioOfficialReceipt, file: URL, root: URL) throws {
    var current = receipt
    var done = SkyStudioJobStatus(jobID: "server-original", state: .done)
    done.billing = .init(["status": "charged", "credits_charged": 10, "review_required": false,
                         "prompt": "must not persist", "recipe_pin": "must not persist"])
    done.result = .init(json: ["url": "https://assets.example/generated/original.mp4", "generation_id": "generation-original",
                              "width": 1280, "height": 720, "duration": 5, "content_type": "video/mp4",
                              "film": ["private": true], "profile": "must not persist", "token": "must not persist"])
    try current.received(done)
    try Data("synthetic-output".utf8).write(to: root.appendingPathComponent("shot.mp4"))
    try Data("synthetic-original".utf8).write(to: root.appendingPathComponent("original.mp4"))
    try current.delivered(file: root.appendingPathComponent("shot.mp4"), original: root.appendingPathComponent("original.mp4"))
    current.localSettlementObserved = true
    try SkyStudioOfficialReceiptStore.write(current, at: file)
    let restored = try SkyStudioOfficialReceiptStore.readIfPresent(at: file)
    checkEqual(restored, current, "known job, output and settlement evidence survive restart")
    checkEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "atomic updates retain permissions600")
    let stored = try String(contentsOf: file, encoding: .utf8)
    check(!stored.contains("must not persist") && !stored.contains("recipe_pin") && !stored.contains("\"film\""), "unknown/private response fields are not persisted")

    var next = current; next.jobID = "another-job"
    receiptRefuses("known jobID cannot change") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.jobID = nil
    receiptRefuses("known jobID cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.remoteResult = nil
    receiptRefuses("known result cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.remoteResult = ["url": "https://assets.example/generated/different.mp4"]
    receiptRefuses("known result URL cannot change") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.savedFile = nil
    receiptRefuses("delivered file evidence cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.savedOriginal = nil
    receiptRefuses("original file evidence cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.savedFile = root.appendingPathComponent("replacement.mp4")
    receiptRefuses("delivered file evidence cannot change") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.savedFileIdentity = nil
    receiptRefuses("known file identity cannot disappear") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.localSettlementObserved = false
    receiptRefuses("local settlement evidence cannot regress") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.billing = ["status": "reserved", "credits_charged": 10]
    receiptRefuses("final authoritative billing cannot become unknown") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    next = current; next.serverState = "running"
    receiptRefuses("terminal remote state cannot return to running") { try SkyStudioOfficialReceiptStore.write(next, at: file) }
    var other = done; other.jobID = "replacement-job"
    receiptRefuses("received refuses replacement server identity") { try current.received(other) }
    other = done; other.result = nil
    try current.received(other)
    checkEqual(current.remoteResult, restored?.remoteResult, "later status without result keeps original recovery metadata")
    checkEqual(try SkyStudioOfficialReceiptStore.readIfPresent(at: file), restored, "failed writes leave exact old receipt intact")

    let changed = try receiptDecode(receipt, replacing: "renderDigest", with: .string(String(repeating: "c", count: 64)))
    receiptRefuses("different effective render cannot use receipt") { try SkyStudioOfficialReceiptStore.write(changed, at: file) }
    let secret = try receiptDecode(receipt, replacing: "params", with: ["film": ["shot": "private"]])
    receiptRefuses("raw public-film request cannot be persisted in params") { try secret.validate() }
    let nestedSecret = try receiptDecode(receipt, replacing: "params", with: ["options": [["TOKEN": "private"]]])
    receiptRefuses("nested private request fields cannot hide inside settings") { try nestedSecret.validate() }
    next = current; next.remoteResult = ["url": "https://assets.example/result.mp4", "seed": ["arbitrary": "metadata"]]
    receiptRefuses("public result metadata cannot carry unknown nested content") { try next.validate() }
    let newer = try receiptDecode(receipt, replacing: "version", with: 99)
    receiptRefuses("unknown receipt schema fails closed") { try newer.validate() }
    let unsubmitted = try receiptDecode(receipt, replacing: "submitted", with: false)
    receiptRefuses("receipt cannot reset submitted marker") { try unsubmitted.validate() }
    try runReceiptSavedFileChecks(current, root: root)
    try runReceiptRefundChecks(receipt)
}

private func runReceiptSavedFileChecks(_ receipt: SkyStudioOfficialReceipt, root: URL) throws {
    let output = root.appendingPathComponent("shot.mp4")
    check(receipt.validSavedFile(output), "unchanged delivered output retains its stat identity")
    check(receipt.validSavedFile(root.appendingPathComponent("original.mp4")), "unchanged original retains its stat identity")
    var legacy = receipt; legacy.savedFileIdentity = nil
    check(!legacy.validSavedFile(output), "legacy receipt without file identity cannot skip verification")
    try Data("replaced-output-different-size".utf8).write(to: output)
    check(!receipt.validSavedFile(output), "same output path with changed bytes is not the recorded file")
    var next = receipt
    receiptRefuses("delivery cannot replace original recorded identity") { try next.delivered(file: output) }
    try Data().write(to: output)
    check(!receipt.validSavedFile(output), "zero-byte output is never accepted for recovery")
    receiptRefuses("delivery rejects empty output") { try next.delivered(file: output) }
    let directory = root.appendingPathComponent("directory-output")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    receiptRefuses("delivery rejects nonregular output") { try next.delivered(file: directory) }
}

private func runReceiptRefundChecks(_ initial: SkyStudioOfficialReceipt) throws {
    var refunded = initial
    refunded.jobID = "refunded-original"
    refunded.serverState = "failed"
    refunded.billing = ["status": "refunded", "credits_charged": 0, "credits_refunded": 10]
    try refunded.validate()
    var next = refunded
    next.billing = ["status": "charged", "credits_charged": 10, "credits_refunded": 10]
    receiptRefuses("confirmed full refund cannot become a charge") { try next.validate(successorOf: refunded) }
    next.billing = ["status": "refund_pending", "credits_charged": 0, "credits_refunded": 10]
    receiptRefuses("confirmed full refund cannot become pending") { try next.validate(successorOf: refunded) }
    next.billing = ["status": "refunded", "credits_charged": 0, "credits_refunded": 8]
    receiptRefuses("confirmed refund amount cannot decrease") { try next.validate(successorOf: refunded) }
    next.billing = ["status": "refunded", "credits_charged": 0]
    receiptRefuses("confirmed refund amount cannot disappear") { try next.validate(successorOf: refunded) }
}

private func receiptDecode(_ receipt: SkyStudioOfficialReceipt, replacing key: String, with value: JSONValue) throws -> SkyStudioOfficialReceipt {
    var object = try JSONValue.decode(JSONEncoder().encode(receipt)).objectValue!
    object[key] = value
    return try JSONDecoder().decode(SkyStudioOfficialReceipt.self, from: JSONValue.object(object).encodedData())
}

private func runReceiptCorruptionChecks(_ receipt: SkyStudioOfficialReceipt, file: URL) throws {
    let corrupt = Data("{incomplete".utf8)
    try corrupt.write(to: file)
    receiptRefuses("corrupt existing record is never missing") { _ = try SkyStudioOfficialReceiptStore.readIfPresent(at: file) }
    receiptRefuses("create cannot replace corrupt existing record") { try SkyStudioOfficialReceiptStore.create(receipt, at: file) }
    receiptRefuses("write cannot replace corrupt existing record") { try SkyStudioOfficialReceiptStore.write(receipt, at: file) }
    checkEqual(try Data(contentsOf: file), corrupt, "corrupt evidence is preserved for investigation")
    var object = try JSONValue.decode(JSONEncoder().encode(receipt)).objectValue!
    object["recipe_pin"] = "must-not-be-loaded"
    try JSONValue.object(object).encodedData().write(to: file)
    receiptRefuses("unknown top-level receipt fields rejected") { _ = try SkyStudioOfficialReceiptStore.readIfPresent(at: file) }
    try JSONEncoder().encode(receipt).write(to: file)
    let different = file.deletingLastPathComponent().appendingPathComponent(String(repeating: "0", count: 64) + ".json")
    try FileManager.default.copyItem(at: file, to: different)
    receiptRefuses("valid receipt cannot be read under another operation digest") { _ = try SkyStudioOfficialReceiptStore.readIfPresent(at: different) }
}

private func runReceiptConcurrentCreateChecks(_ root: URL) throws {
    let receipt = officialReceiptFixture(root, key: "concurrent-operation")
    let file = SkyStudioOfficialReceiptStore.url(accountID: receipt.accountID, key: receipt.idempotencyKey, directory: root)
    let outcomes = OfficialReceiptCreateOutcomes()
    DispatchQueue.concurrentPerform(iterations: 6) { _ in
        do { try SkyStudioOfficialReceiptStore.create(receipt, at: file); outcomes.add(created: true) }
        catch SkyStudioOfficialReceiptError.alreadyExists { outcomes.add(created: false) }
        catch { outcomes.add(error: true) }
    }
    checkEqual(outcomes.created, 1, "concurrent receipt creation has exactly one winner")
    checkEqual(outcomes.existing, 5, "other callers recover the same original receipt")
    checkEqual(outcomes.errors, 0, "concurrent atomic writes do not corrupt receipts")
}

private final class OfficialReceiptCreateOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created = 0
    private(set) var existing = 0
    private(set) var errors = 0
    func add(created: Bool = false, error: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if error { errors += 1 } else if created { self.created += 1 } else { existing += 1 }
    }
}
