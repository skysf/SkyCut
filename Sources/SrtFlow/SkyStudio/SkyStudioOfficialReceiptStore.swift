import CryptoKit
import Darwin
import Foundation
import SrtFlowMCPKit

// 官方提交回执的磁盘边界；目录 700、文件 600，SHA-256 文件名，不用用户 key 拼路径。
// 收费前独占创建，之后只能补原单证据；坏文件不是“没有”，没有 reset/delete 或重交入口。
// 调用方在 MediaReadQueue 上做 IO；每个回执用文件锁保护跨实例的读改写。
enum SkyStudioOfficialReceiptStore {
    static func url(accountID: String, key: String, directory: URL) -> URL {
        let identity = String(accountID.utf8.count) + ":" + accountID + key
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
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
        try locked(at: url) {
            guard try readIfPresent(at: url) == nil else { throw SkyStudioOfficialReceiptError.alreadyExists }
            try persist(receipt, at: url)
        }
    }

    static func write(_ receipt: SkyStudioOfficialReceipt, at url: URL) throws {
        try receipt.validate()
        try location(receipt, at: url)
        try locked(at: url) {
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

    private static func locked<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SkyStudioOfficialReceiptError.corrupt }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0, flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func persist(_ receipt: SkyStudioOfficialReceipt, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(receipt)
        guard data.count <= 64 * 1024 else { throw SkyStudioOfficialReceiptError.corrupt }
        // 临时文件先 600，再 fsync / 原子替换；中断不能暴露半份回执或短暂的宽权限。
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".receipt-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        var renamed = false
        defer { Darwin.close(descriptor); if !renamed { try? FileManager.default.removeItem(at: temporary) } }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw posixError() }
        renamed = true
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw posixError() }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
