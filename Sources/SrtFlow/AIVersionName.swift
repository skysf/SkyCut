import Foundation
import SrtFlowCore

// MARK: - 同一个文件夹出几个版本时，文件名带上版本（AI 多开方案板 5、L 节）
//
// 管什么：`new_project` / `export_video` 的 `version`（「30s」「竖屏」「v2」）怎么拼进文件名：「南极 - 30s」。只靠撞名加编号的话是
// 「南极」「南极 2」「南极 3」，用户分不清哪个是哪个（2026-10-17 用户拍板）。纯值，自检直接测（checks/MCP/VersionNameChecks.swift）。
// 不管什么：什么时候必须给版本（AIProjectOpenTools：这个会话在同一个文件夹里已经开着工程）；撞名照旧加编号（ExportFileName.unoccupied）。

enum AIVersionName {
    /// 版本名最长几个字（再长就截掉：它只是区分几个版本的标签）。
    static let maxLength = 40

    /// 整理 AI 给的版本名：去掉首尾空白、文件名里不能有的 `/` `:` 换成 `-`，太长截掉；空的回 nil。
    static func clean(_ version: String?) -> String? {
        guard let version else { return nil }
        let cleaned = ExportFileName.stem(from: version, droppingExtension: "", fallback: "")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// 「<名字> - <版本>」；没有版本就是名字本身。名字已经以「 - <版本>」结尾（导出一个叫「南极 - 30s」的工程时又给了 30s）就不再叠一遍。
    static func stem(_ name: String, version: String?) -> String {
        guard let version = clean(version) else { return name }
        let suffix = " - " + version
        return name.lowercased().hasSuffix(suffix.lowercased()) ? name : name + suffix
    }
}
