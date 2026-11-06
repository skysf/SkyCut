import Foundation

// 只管按构建身份定位录屏账本及原子读写；恢复裁决和媒体文件处置由协调者负责。

/// manifest 的持久化栅栏：单一 JSON 文件 + 原子写。
///
/// `persist()` **成功返回后**，manifest 已通过「写临时文件 + 原子 rename」进入
/// 文件系统命名空间 —— 进程级崩溃（含 kill -9）后必然能读回。这正是 journal
/// 协议里「persist 之后才许 rename」这道栅栏的实现。
///
/// 威胁模型是 **App 崩溃**，不是整机掉电：掉电级持久性需要 F_FULLFSYNC，
/// 计划未要求；若将来要，加在 persist() 里，不改协议。
///
/// `load()` 读到损坏文件会抛错 —— 调用方应当如实报告「恢复信息损坏」，
/// **不许**因此退回 glob 扫描。
public struct ScreenRecordingManifestStore: Sendable {
    public let fileURL: URL

    /// App 的唯一入口：正式版 / Beta / Dev / 冒烟只使用自己 bundle id 下的账本。
    /// 不读、迁移或清理旧的共用 SrtFlow 目录：旧账本无法证明归属，可能仍在写盘。
    public init(applicationSupport: URL, bundleIdentifier: String) {
        self.init(directory: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }

    /// 精确目录入口，供隔离夹具使用；App 必须使用带 bundleIdentifier 的入口。
    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("active-recording-manifest.json")
    }

    /// 原子落盘。**返回成功之后，调用方才允许做对应的 rename。**
    public func persist(_ manifest: ScreenRecordingManifest) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 账本文件**是否存在** —— 与「能否解码」无关。
    ///
    /// 「有没有未了结的账」必须以它为准，不能用 `try? load() != nil`：
    /// 那样一份**损坏**的 JSON 会被读成「没有账本」，下一次录制的 `persist()`
    /// 就把它覆盖掉了，上一段录制的唯一索引随之消失。解码失败同样是
    /// unsettled，**不允许 fail-open**（复审三 P1-2）。
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> ScreenRecordingManifest? {
        guard fileExists else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ScreenRecordingManifest.self, from: data)
    }

    /// 幂等清除。
    ///
    /// **调用前必须先问 `ScreenRecoveryLedger.canClearManifest`** ——
    /// 光看文件现场（`FileResolution`）是不够的：writing 阶段崩溃留下的 partial
    /// 现场是 `notCommitted(tempExists: true)`，现场本身「没问题」，但用户还没
    /// 决定这份 partial 怎么处理，此时清账会让它变成无人认领的隐藏文件。
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
