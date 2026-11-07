import CryptoKit
import Darwin
import Foundation

// 角色与官方生成回执共用的原子字节边界：独占锁、600 文件、700 目录、fsync / rename。
// 不解释回执内容、身份或账单；各自 store 在进入这里之前校验这些合同。
enum SkyStudioReceiptFile {
    static func identifier(accountID: String, key: String) -> String {
        let identity = String(accountID.utf8.count) + ":" + accountID + key
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func locked<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0, flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func persist(_ data: Data, at url: URL) throws {
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
