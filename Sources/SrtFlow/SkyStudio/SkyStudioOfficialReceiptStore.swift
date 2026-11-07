import CryptoKit
import Darwin
import Foundation
import SrtFlowMCPKit

// 官方提交回执的磁盘边界；目录 700、文件 600，SHA-256 文件名，不用用户 key 拼路径。
// 收费前独占创建，之后只能补原单证据；坏文件不是“没有”，没有 reset/delete 或重交入口。
// 调用方在 MediaReadQueue 上做 IO；每个回执用文件锁保护跨实例的读改写。
enum SkyStudioOfficialReceiptStore {
    static func url(accountID: String, key: String, directory: URL) -> URL {
        let digest = SkyStudioReceiptFile.identifier(accountID: accountID, key: key)
        return directory.appendingPathComponent(digest + ".json")
    }

    static func readIfPresent(at url: URL) throws -> SkyStudioOfficialReceipt? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 64 * 1024 else {
            throw SkyStudioOfficialReceiptError.corrupt
        }
        let data = try Data(contentsOf: url)
        let value = try JSONValue.decode(data)
        guard let object = value.objectValue, Set(object.keys).isSubset(of: fields) else { throw SkyStudioOfficialReceiptError.corrupt }
        let receipt = try JSONDecoder().decode(SkyStudioOfficialReceipt.self, from: data)
        try receipt.validate()
        try location(receipt, at: url)
        return receipt
    }

    static func create(_ receipt: SkyStudioOfficialReceipt, at url: URL) throws {
        try receipt.validate()
        try location(receipt, at: url)
        try SkyStudioReceiptFile.locked(at: url) {
            guard try readIfPresent(at: url) == nil else { throw SkyStudioOfficialReceiptError.alreadyExists }
            try persist(receipt, at: url)
        }
    }

    static func write(_ receipt: SkyStudioOfficialReceipt, at url: URL) throws {
        try receipt.validate()
        try location(receipt, at: url)
        try SkyStudioReceiptFile.locked(at: url) {
            guard let old = try readIfPresent(at: url) else { throw SkyStudioOfficialReceiptError.missing }
            try receipt.validate(successorOf: old)
            try persist(receipt, at: url)
        }
    }

    private static let fields: Set<String> = ["version", "accountID", "projectPath", "idempotencyKey", "argumentsDigest", "renderDigest",
        "kind", "modelID", "modelTitle", "params", "folder", "stem", "reservedCredits", "reservedDay", "submitted", "submissionRejection", "jobID", "serverState",
        "billing", "remoteResult", "savedFile", "savedOriginal", "savedFileIdentity", "savedOriginalIdentity", "localSettlementObserved"]

    private static func location(_ receipt: SkyStudioOfficialReceipt, at target: URL) throws {
        guard target.isFileURL, target.standardizedFileURL == target,
              url(accountID: receipt.accountID, key: receipt.idempotencyKey, directory: target.deletingLastPathComponent()) == target else {
            throw SkyStudioOfficialReceiptError.identityMismatch
        }
    }

    private static func persist(_ receipt: SkyStudioOfficialReceipt, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        guard data.count <= 64 * 1024 else { throw SkyStudioOfficialReceiptError.corrupt }
        try SkyStudioReceiptFile.persist(data, at: url)
    }
}
