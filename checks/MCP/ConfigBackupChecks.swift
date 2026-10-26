import Foundation

// 连接 AI 客户端时改配置文件（`AIClientConfigWrite`，docs/bugfixes/2026-10-27-client-config-backup-world-readable.md）：
// 第一次改之前的备份和原文件同样的权限 —— 以前另写一个新文件，600 的 Codex 配置备份成了谁都能读的 644。

func runConfigBackupChecks() {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("skycut-config-backup-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    func mode(_ path: String) -> Int { ((try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
    func text(_ path: String) -> String? { fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

    // 只有本人能读的配置（Codex 的 config.toml 就是 600）。
    let codex = folder.appendingPathComponent("config.toml").path
    fm.createFile(atPath: codex, contents: Data("model = \"x\"\n".utf8), attributes: [.posixPermissions: 0o600])
    do {
        try AIClientConfigWrite.rewrite(codex) { ($0 ?? Data()) + Data("[mcp_servers.skycut]\n".utf8) }
    } catch {
        check(false, "rewriting a config works: \(error)")
    }
    let backup = codex + AIClientConfigWrite.backupSuffix
    checkEqual(mode(backup), 0o600, "the backup of a 600 config is 600 too")
    checkEqual(text(backup), "model = \"x\"\n", "the backup holds the original")
    checkEqual(text(codex), "model = \"x\"\n[mcp_servers.skycut]\n", "the config holds the change")
    checkEqual(mode(codex), 0o600, "the rewritten config keeps its 600")

    // 再改一次：第一份备份不动。
    try? AIClientConfigWrite.rewrite(codex) { _ in Data("changed again\n".utf8) }
    checkEqual(text(backup), "model = \"x\"\n", "a later change keeps the first backup")
    checkEqual(mode(backup), 0o600, "a later change leaves the backup's permissions alone")

    // 照原文件的权限来，不是一律 600。
    let shared = folder.appendingPathComponent("settings.json").path
    fm.createFile(atPath: shared, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
    try? AIClientConfigWrite.rewrite(shared) { _ in Data("{\"a\":1}".utf8) }
    checkEqual(mode(shared + AIClientConfigWrite.backupSuffix), 0o644, "the backup mirrors a 644 original")

    // 配置是个链接（用 dotfiles 管配置的人）：权限按它指着的那个文件算。
    let target = folder.appendingPathComponent("dotfiles-config.toml").path
    fm.createFile(atPath: target, contents: Data("a = 1\n".utf8), attributes: [.posixPermissions: 0o600])
    let link = folder.appendingPathComponent("linked.toml").path
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    try? AIClientConfigWrite.rewrite(link) { _ in Data("b = 2\n".utf8) }
    checkEqual(mode(link + AIClientConfigWrite.backupSuffix), 0o600, "a linked config's backup takes the target's permissions")
    checkEqual(text(link + AIClientConfigWrite.backupSuffix), "a = 1\n", "a linked config's backup holds the target's text")

    // 没有原文件：不建备份，直接建配置。
    let fresh = folder.appendingPathComponent("new/claude_desktop_config.json").path
    try? AIClientConfigWrite.rewrite(fresh) { _ in Data("{}".utf8) }
    check(!fm.fileExists(atPath: fresh + AIClientConfigWrite.backupSuffix), "no backup when there was no file")
    checkEqual(text(fresh), "{}", "a missing config is created")
}
