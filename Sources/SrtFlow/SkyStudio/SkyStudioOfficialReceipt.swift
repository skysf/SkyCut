import Foundation
import SrtFlowMCPKit

// 官方镜头提交的持久回执：仅保留查原单 / 取回成品所需的公开身份与结算证据。
// 不存提示词、film、引用、pin、审查指纹、API Key 或确认码；它永远不是重新 POST 的许可。
struct SkyStudioOfficialReceipt: Codable, Equatable, Sendable {
    let version: Int
    let accountID: String
    let projectPath: String
    let idempotencyKey: String
    let argumentsDigest: String
    let renderDigest: String
    let kind: String
    let modelID: String
    let modelTitle: String
    let params: [String: JSONValue]
    let folder: URL
    let stem: String
    let reservedCredits: Double
    let reservedDay: Date
    /// 收费 POST 之前落盘；即使没有 jobID，也只允许核查原请求，不能清掉重交。
    let submitted: Bool
    /// 明确未发送 / 未入场的证据；submitted 仍是禁止重交的墓碑，不冒充云端已接单。
    var submissionRejection: String?
    var jobID: String?
    var serverState: String?
    var billing: JSONValue?
    var remoteResult: JSONValue?
    var savedFile: URL?
    var savedOriginal: URL?
    var savedFileIdentity: JSONValue?
    var savedOriginalIdentity: JSONValue?
    /// 只作证据；重启恢复不因此重新扣账或重复退本机预留。
    var localSettlementObserved = false

    init(accountID: String, projectPath: String, idempotencyKey: String, argumentsDigest: String, renderDigest: String,
         kind: String, modelID: String, modelTitle: String, params: [String: JSONValue], folder: URL, stem: String,
         reservedCredits: Double, reservedDay: Date) {
        version = 1
        submitted = true
        self.accountID = accountID
        self.projectPath = projectPath
        self.idempotencyKey = idempotencyKey
        self.argumentsDigest = argumentsDigest
        self.renderDigest = renderDigest
        self.kind = kind
        self.modelID = modelID
        self.modelTitle = modelTitle
        self.params = params
        self.folder = folder
        self.stem = stem
        self.reservedCredits = reservedCredits
        self.reservedDay = reservedDay
    }

    mutating func rejectedBeforeAdmission(_ code: String) throws {
        var next = self
        next.submissionRejection = code
        try next.validate(successorOf: self)
        self = next
    }

    mutating func received(_ status: SkyStudioJobStatus) throws {
        var next = self
        guard jobID == nil || jobID == status.jobID else { throw SkyStudioOfficialReceiptError.identityMismatch }
        next.jobID = status.jobID
        if let state = status.state { next.serverState = state.rawValue }
        if let billing = status.billing {
            next.billing = .object(billing.json.objectValue?.filter { Self.billingFields.contains($0.key) } ?? [:])
        }
        if let result = status.result {
            var value = remoteResult?.objectValue ?? [:]
            for (key, item) in result.metadata where Self.resultFields.contains(key) && item != .null {
                value[key] = item
            }
            // 只从已解析的成品值写地址；metadata 不得替换另一份结果。
            value["url"] = .string(result.url.absoluteString)
            next.remoteResult = .object(value)
        }
        try next.validate(successorOf: self)
        self = next
    }

    mutating func delivered(file: URL, original: URL? = nil) throws {
        var next = self
        next.savedFile = file.standardizedFileURL
        next.savedFileIdentity = try Self.fileIdentity(file)
        if let original {
            next.savedOriginal = original.standardizedFileURL
            next.savedOriginalIdentity = try Self.fileIdentity(original)
        }
        try next.validate(successorOf: self)
        self = next
    }

    /// 只有记录过的非空普通文件仍是原身份，恢复才可直接使用；老回执缺身份也按未知处理。
    func validSavedFile(_ file: URL) -> Bool {
        let expected = file == savedFile ? savedFileIdentity : (file == savedOriginal ? savedOriginalIdentity : nil)
        guard let expected, let actual = try? Self.fileIdentity(file) else { return false }
        return expected == actual
    }

    func validate() throws {
        guard version == 1, submitted, !accountID.isEmpty, accountID.utf16.count <= 160,
              !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, idempotencyKey.utf16.count <= 128,
              Self.digest(argumentsDigest), Self.digest(renderDigest),
              projectPath.hasPrefix("/"), URL(fileURLWithPath: projectPath).standardizedFileURL.path == projectPath,
              ["image", "image_to_video", "text_to_video"].contains(kind), !modelID.isEmpty, !modelTitle.isEmpty,
              Self.fileURL(folder), !stem.isEmpty, stem != ".", stem != "..", !stem.contains("/"), !stem.contains("\\"),
              reservedCredits.isFinite, reservedCredits >= 0, reservedDay.timeIntervalSince1970.isFinite,
              jobID.map(Self.jobIdentifier) ?? true,
              serverState.map({ ["queued", "running", "done", "failed", "cancelled"].contains($0) }) ?? true,
              savedFile.map(Self.fileURL) ?? true, savedOriginal.map(Self.fileURL) ?? true,
              Self.publicValue(.object(params)), billing.map(Self.publicValue) ?? true, remoteResult.map(Self.publicValue) ?? true else {
            throw SkyStudioOfficialReceiptError.corrupt
        }
        if serverState != nil || billing != nil || remoteResult != nil {
            guard jobID != nil else { throw SkyStudioOfficialReceiptError.corrupt }
        }
        if let submissionRejection {
            guard (submissionRejection == "local_not_sent" || SkyStudioJobAdmission.rejectedCodes.contains(submissionRejection)),
                  jobID == nil, remoteResult == nil, serverState == nil, billing == nil else { throw SkyStudioOfficialReceiptError.corrupt }
        }
        if savedFile != nil || savedOriginal != nil { guard remoteResult != nil else { throw SkyStudioOfficialReceiptError.corrupt } }
        for (identity, file) in [(savedFileIdentity, savedFile), (savedOriginalIdentity, savedOriginal)] {
            if let identity {
                guard let file, Self.validFileIdentity(identity, for: file) else { throw SkyStudioOfficialReceiptError.corrupt }
            }
        }
        if let billing {
            guard let object = billing.objectValue, Set(object.keys).isSubset(of: Self.billingFields),
                  let status = billing["status"]?.stringValue,
                  ["reserved", "charged", "refunded", "not_charged", "pending_review", "refund_pending"].contains(status),
                  object.values.allSatisfy({ $0.objectValue == nil && $0.arrayValue == nil }) else { throw SkyStudioOfficialReceiptError.corrupt }
            for key in ["credits_reserved", "credits_charged", "credits_refunded"] {
                if let amount = billing[key], amount != .null {
                    guard let number = amount.doubleValue, number.isFinite, number >= 0 else { throw SkyStudioOfficialReceiptError.corrupt }
                }
            }
        }
        if let remoteResult {
            guard let object = remoteResult.objectValue, Set(object.keys).isSubset(of: Self.resultFields),
                  object.values.allSatisfy({ $0.objectValue == nil && $0.arrayValue == nil }),
                  let raw = remoteResult["url"]?.stringValue, let url = URLComponents(string: raw),
                  ["http", "https"].contains(url.scheme ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                throw SkyStudioOfficialReceiptError.corrupt
            }
        }
    }

    func validate(successorOf old: Self) throws {
        try validate()
        guard version == old.version, accountID == old.accountID, projectPath == old.projectPath,
              idempotencyKey == old.idempotencyKey, argumentsDigest == old.argumentsDigest, renderDigest == old.renderDigest,
              kind == old.kind, modelID == old.modelID, modelTitle == old.modelTitle, params == old.params,
              folder == old.folder, stem == old.stem, reservedCredits == old.reservedCredits, reservedDay == old.reservedDay,
              submitted == old.submitted, old.jobID == nil || jobID == old.jobID else { throw SkyStudioOfficialReceiptError.identityMismatch }
        guard !old.localSettlementObserved || localSettlementObserved,
              old.submissionRejection == nil || submissionRejection == old.submissionRejection,
              old.savedFile == nil || savedFile == old.savedFile,
              old.savedOriginal == nil || savedOriginal == old.savedOriginal,
              old.savedFileIdentity == nil || savedFileIdentity == old.savedFileIdentity,
              old.savedOriginalIdentity == nil || savedOriginalIdentity == old.savedOriginalIdentity,
              old.billing == nil || billing != nil else { throw SkyStudioOfficialReceiptError.evidenceRegression }
        if let oldState = old.serverState, ["done", "failed", "cancelled"].contains(oldState),
           serverState == nil || ["queued", "running"].contains(serverState ?? "") { throw SkyStudioOfficialReceiptError.evidenceRegression }
        if SkyStudioBilling(old.billing)?.netCharged != nil, SkyStudioBilling(billing)?.netCharged == nil {
            throw SkyStudioOfficialReceiptError.evidenceRegression
        }
        if SkyStudioBilling(old.billing)?.returnedAll == true, SkyStudioBilling(billing)?.returnedAll != true {
            throw SkyStudioOfficialReceiptError.evidenceRegression
        }
        if let refunded = old.billing?["credits_refunded"]?.doubleValue,
           billing?["credits_refunded"]?.doubleValue.map({ $0 >= refunded }) != true {
            throw SkyStudioOfficialReceiptError.evidenceRegression
        }
        for (key, value) in old.remoteResult?.objectValue ?? [:] {
            guard let next = remoteResult?[key] else { throw SkyStudioOfficialReceiptError.evidenceRegression }
            if key != "caption_status" && key != "caption_retry_after_seconds" && next != value {
                throw SkyStudioOfficialReceiptError.evidenceRegression
            }
        }
    }

    private static let billingFields: Set<String> = ["policy_version", "status", "provider_outcome", "credits_reserved", "credits_charged",
                                                    "credits_refunded", "refund_reason", "no_refund_reason", "review_required"]
    private static let resultFields: Set<String> = ["url", "generation_id", "content_type", "width", "height", "duration", "fps", "expires_at",
                                                   "caption_file", "caption_status", "caption_retry_after_seconds", "seed", "billable_duration",
                                                   "billing_duration", "transparent", "has_alpha"]
    private static let forbiddenFields: Set<String> = ["film", "prompt", "inputs", "references", "recipe_pin", "seam_review", "profile",
                                                      "selection", "authorization", "api_key", "key", "token", "confirm_token", "access_token", "request"]
    private static func publicValue(_ value: JSONValue) -> Bool {
        if let object = value.objectValue {
            return object.allSatisfy { !forbiddenFields.contains($0.key.lowercased()) && publicValue($0.value) }
        }
        if let array = value.arrayValue { return array.allSatisfy(publicValue) }
        return value.doubleValue.map(\.isFinite) ?? true
    }
    private static func digest(_ value: String) -> Bool { value.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil }
    private static func fileURL(_ value: URL) -> Bool {
        value.isFileURL && value.path.hasPrefix("/") && value == value.standardizedFileURL && value.query == nil && value.fragment == nil
    }
    private static func fileIdentity(_ url: URL) throws -> JSONValue {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else { throw SkyStudioOfficialReceiptError.corrupt }
        let value = try SkyStudioApproval.file(url)
        guard validFileIdentity(value, for: url.standardizedFileURL) else { throw SkyStudioOfficialReceiptError.corrupt }
        return value
    }
    private static func validFileIdentity(_ value: JSONValue, for file: URL) -> Bool {
        guard let object = value.objectValue, Set(object.keys) == ["path", "device", "inode", "bytes", "modified"],
              value["path"]?.stringValue == file.path,
              let modified = value["modified"]?.doubleValue, modified.isFinite,
              let bytes = value["bytes"]?.stringValue.flatMap(UInt64.init), bytes > 0 else { return false }
        return ["device", "inode"].allSatisfy { value[$0]?.stringValue.flatMap(UInt64.init) != nil }
    }
    private static func jobIdentifier(_ value: String) -> Bool { !value.isEmpty && value.utf16.count <= 128 && !value.contains("/") && !value.contains("..") }
}

enum SkyStudioOfficialReceiptError: Error, LocalizedError, Equatable {
    case corrupt, alreadyExists, missing, identityMismatch, evidenceRegression
    var errorDescription: String? {
        switch self {
        case .corrupt: return "The official submission receipt is invalid. Preserve it and investigate the original operation; do not submit again."
        case .alreadyExists: return "This official operation was already recorded. Recover the original job; do not submit again."
        case .missing: return "The original official receipt is missing. Do not recreate it or submit again."
        case .identityMismatch: return "This receipt is bound to a different original operation or server job. Do not overwrite or resubmit it."
        case .evidenceRegression: return "A receipt update would discard known result or settlement evidence. Preserve the original record."
        }
    }
}
