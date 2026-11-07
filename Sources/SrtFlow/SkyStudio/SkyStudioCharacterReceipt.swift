import Foundation
import SrtFlowMCPKit

// 原生角色收费 / 导入的持久原单：POST 前存确认身份和已上传输入，收到 job_id 立即记下。
// 不存 API Key，不提供清空后重交入口；未知收费提交没有 job_id 时只能核查，不能借恢复重放。
struct SkyStudioCharacterReceipt: Equatable, Sendable, Codable {
    var version = 1
    var accountID: String
    var idempotencyKey: String
    var argumentsDigest: String
    var approvalIdentity: String
    var request: SkyStudioJobRequest
    var mutation: SkyStudioCharacterMutation? = nil
    var reservedCredits: Double
    var reservedDay: Date
    var submissionAttempted = false
    var rejectionCode: String?
    var jobID: String?
    var characterID: String?
    var latest: [String: JSONValue] = [:]

    var localID: String { "character-" + SkyStudioReceiptFile.identifier(accountID: accountID, key: idempotencyKey) }
    var isFree: Bool { mutation != nil || request.nativeCharacter?.operation == .importViews }
    var operation: String { request.nativeCharacter?.operation.rawValue ?? "character_replace_view" }

    enum Recovery: Equatable { case originalJob(String), libraryRead(String), freeImport, notSubmitted, unknown }
    func recovery(explicitFreeImport: Bool = false) -> Recovery {
        if let mutation { return .libraryRead(mutation.id) }
        if let jobID { return .originalJob(jobID) }
        if rejectionCode != nil || !submissionAttempted { return .notSubmitted }
        if isFree && explicitFreeImport { return .freeImport }
        return .unknown
    }

    func validate() throws {
        guard version == 1, !accountID.isEmpty, !idempotencyKey.isEmpty, idempotencyKey.utf16.count <= 128,
              SkyStudioCharacter.isRevision(argumentsDigest), SkyStudioCharacter.isRevision(approvalIdentity),
              (request.nativeCharacter != nil) != (mutation != nil), request.film == nil, request.characterAssets == nil,
              request.idempotencyKey == idempotencyKey, reservedCredits.isFinite, reservedCredits >= 0,
              !isFree || reservedCredits == 0 else { throw SkyStudioCharacterReceiptError.invalid }
    }

    mutating func received(_ status: SkyStudioJobStatus) throws {
        guard jobID == nil || jobID == status.jobID,
              characterID == nil || status.characterID == nil || characterID == status.characterID else { throw SkyStudioCharacterReceiptError.conflict }
        if let id = status.characterID, request.nativeCharacter?.operation != .headshot, id != status.jobID { throw SkyStudioCharacterReceiptError.conflict }
        jobID = status.jobID
        if let id = status.characterID { characterID = id }
        latest.merge(SkyStudioCharacterJobReport.fields(status, freeImport: isFree)) { _, new in new }
        if let characterID { latest["character_id"] = .string(characterID) }
    }

    mutating func receivedFailure(_ failure: SkyStudioJobFailure) throws {
        if let id = failure.jobID {
            guard jobID == nil || jobID == id else { throw SkyStudioCharacterReceiptError.conflict }
            jobID = id
        }
        latest["failure"] = failure.json
    }

    static func arguments(_ args: AIToolArguments) -> String {
        var fields = args.raw.objectValue ?? [:]
        for key in ["project", "idempotency_key", "confirm_token", "quote_only", "resume", "approval_scope", "user_requested_overrides"] { fields[key] = nil }
        return SkyStudioCharacterCache.digest(JSONValue.object(fields).encodedString())
    }
}

enum SkyStudioCharacterReceiptError: Error, LocalizedError {
    case invalid, conflict
    var errorDescription: String? {
        "The Character recovery receipt is invalid or conflicts with its original identity. Preserve it for review; no upload, new Character or paid submission was repeated."
    }
}

// 一个库目录按本 App 原 bundle id 隔离；文件名是原账户 + 操作 key 的摘要，不是用户路径。
enum SkyStudioCharacterReceiptStore {
    static func url(_ localID: String, directory: URL) throws -> URL {
        guard localID.hasPrefix("character-"), SkyStudioCharacter.isRevision(String(localID.dropFirst("character-".count))) else { throw SkyStudioCharacterReceiptError.invalid }
        return directory.appendingPathComponent(String(localID.dropFirst("character-".count)) + ".json")
    }

    static func read(_ localID: String, directory: URL) throws -> SkyStudioCharacterReceipt? {
        let file = try url(localID, directory: directory)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, let bytes = attributes[.size] as? NSNumber,
              bytes.intValue > 0, bytes.intValue <= 512 * 1024 else { throw SkyStudioCharacterReceiptError.invalid }
        let value = try JSONDecoder().decode(SkyStudioCharacterReceipt.self, from: Data(contentsOf: file))
        try value.validate()
        guard value.localID == localID else { throw SkyStudioCharacterReceiptError.conflict }
        return value
    }

    static func write(_ value: SkyStudioCharacterReceipt, directory: URL, creating: Bool = false) throws {
        try value.validate()
        let file = try url(value.localID, directory: directory)
        try SkyStudioReceiptFile.locked(at: file) {
            let old = try read(value.localID, directory: directory)
            guard !creating || old == nil else { throw SkyStudioCharacterReceiptError.conflict }
            if let old {
                guard old.accountID == value.accountID, old.idempotencyKey == value.idempotencyKey,
                      old.argumentsDigest == value.argumentsDigest, old.approvalIdentity == value.approvalIdentity, old.reservedCredits == value.reservedCredits, old.reservedDay == value.reservedDay,
                      !old.submissionAttempted || (old.request == value.request && old.mutation == value.mutation),
                      old.jobID == nil || old.jobID == value.jobID, old.characterID == nil || old.characterID == value.characterID,
                      !old.submissionAttempted || value.submissionAttempted else { throw SkyStudioCharacterReceiptError.conflict }
            } else if !creating { throw SkyStudioCharacterReceiptError.invalid }
            let data = try JSONEncoder().encode(value)
            guard data.count <= 512 * 1024 else { throw SkyStudioCharacterReceiptError.invalid }
            try SkyStudioReceiptFile.persist(data, at: file)
        }
    }
}
