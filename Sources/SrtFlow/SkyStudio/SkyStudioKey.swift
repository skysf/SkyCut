import Foundation

// MARK: - Sky Studio 的 API Key（`sk-…`）
//
// 管什么：Key 存在钥匙串的哪一条（服务名 = bundle id + `.skystudio`，账号 `api-key`；测试版是另一个 bundle id、另一条）、
// 粘进来的话怎么整理、这一次运行里读到的记在哪（`cache`）。一把 Key 同时管 SkyCut 的授权和 Sky Studio 的积分（收费方案第 7 条）。
// 不管什么：拿 Key 去问 Sky Studio（SkyStudioAPI）、什么时候问（SkyStudioAccount）、设置里那一节（SkyStudioSettingsSection）。
//
// 服务名是身份类的名字，**永远不改**（docs/architecture/product-name.md）：改了用户存的 Key 就找不到了。checks/product-name.sh 钉着。

enum SkyStudioKey {
    static let account = "api-key"

    static var defaultService: String { (Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow") + ".skystudio" }

    static let secret = KeychainSecret(service: defaultService, account: account, keychainName: "SkyCut Sky Studio API key")

    /// 这一次运行里读到的 Key。**后台问 Sky Studio 时只走 `keyWithoutPrompt()`**：弹钥匙串授权框只在用户点了设置里的按钮之后。
    static let cache = KeychainSecretCache(secret)

    /// Sky Studio 的 Key 是 `sk-` 加 43 个 URL 安全的字符（Sky Studio 仓库 docs/agents/skycut-api.md「Keys」）。
    /// 用户常把 `Bearer ` 前缀、引号、首尾空白 / 换行一起粘进来：去掉；不是 `sk-` 开头、带了 URL 安全字符以外的东西、太短就不收。
    /// 长度不写死成 46：那边哪天换了长度，这里不该先拒掉一把能用的 Key。
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let urlSafe = text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
        guard text.hasPrefix("sk-"), text.count >= 20, urlSafe else { return nil }
        return text
    }
}
