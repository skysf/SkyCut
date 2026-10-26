import Foundation

// MARK: - 往 AI 客户端的配置文件里写：先备份，再原子写回
//
// 管什么：读 → 改 → 原子写回；第一次改之前存一份原文件 `<原名>.skycut-backup`（改坏了用户能找回来），**权限和原文件一样**。
// 这几份配置里可能直接写着密钥（Codex 的 MCP 服务器能带令牌），原文件一般是只有本人能读的 600；以前备份是另写一个新文件、
// 用的默认权限 644，家目录是 755 时本机别的账户都读得到（docs/bugfixes/2026-10-27-client-config-backup-world-readable.md）。
// 备份一建出来就是这个权限（`O_EXCL` + 原文件的权限位），不走「先建再改权限」，中间不留空档。
// 不管什么：改什么（AIClientConfigFiles）、文件在哪、连哪个客户端（AIClientSetup）。

enum AIClientConfigWrite {
    static let backupSuffix = ".skycut-backup"

    static func rewrite(_ path: String, _ transform: (Data?) throws -> Data) throws {
        let fm = FileManager.default
        let original = fm.contents(atPath: path)
        let next = try transform(original)
        let backup = path + backupSuffix
        if let original, !fm.fileExists(atPath: backup) {
            try writeBackup(original, to: backup, mode: permissions(of: path))
        }
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try next.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 原文件的权限位（链接按它指着的那个文件算）；读不到按最严的 600。
    static func permissions(of path: String) -> mode_t {
        let real = (path as NSString).resolvingSymlinksInPath
        let mode = (try? FileManager.default.attributesOfItem(atPath: real)[.posixPermissions]) as? NSNumber
        return mode.map { mode_t($0.uint16Value) & 0o777 } ?? 0o600
    }

    /// 一建出来就是 `mode`（`O_EXCL`：已经有了就不碰）。
    static func writeBackup(_ data: Data, to path: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
