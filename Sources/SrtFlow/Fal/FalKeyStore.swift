import Foundation
import Security

// MARK: - fal.ai 的 Key 存在系统钥匙串里
//
// 管什么：方案第 17 条 —— **能添加、能删除，存系统钥匙串；删除就从钥匙串里抹掉；先只管一把 Key**。
// 一条通用密码项：服务名 = 这个 App 的 bundle id + `.fal`（测试版是另一个 bundle id，钥匙串里也是另一条），账号固定 `api-key`。
// 怎么读写钥匙串（两档：不弹框 / 弹框）在 KeychainSecret 里，和 Sky Studio 的 Key 共用一份；这里只管 fal 这一条叫什么、粘进来的话怎么整理。
// 不管什么：调 fal（FalClient）、Key 在哪填（FalSettingsView）、什么时候读（FalKeyCache）。

enum FalKeyStore {
    typealias Access = KeychainSecret.Access
    typealias ReadResult = KeychainSecret.ReadResult
    typealias StoreError = KeychainSecret.StoreError

    static let account = "api-key"

    static var defaultService: String { (Bundle.main.bundleIdentifier ?? "com.srtflow.SrtFlow") + ".fal" }

    /// 一个服务名上的 fal Key（自检用自己的服务名）。
    static func secret(service: String = defaultService) -> KeychainSecret {
        KeychainSecret(service: service, account: account, keychainName: "SkyCut fal.ai API key")
    }

    // MARK: 存 / 取 / 删

    /// 存过 Key 没有。**只查属性，不读密钥、不弹授权框**。
    static func hasKey(service: String = defaultService) -> Bool { secret(service: service).exists() }

    static func read(_ access: Access, service: String = defaultService) -> ReadResult { secret(service: service).read(access) }

    /// 存（已经有就换掉）。传进来的话先整理（`normalized`）；整理不出一把像样的 Key 就抛错。
    static func save(_ raw: String, service: String = defaultService) throws {
        guard let key = normalized(raw) else { throw StoreError(status: errSecParam) }
        try secret(service: service).save(key)
    }

    /// 从钥匙串里抹掉。本来就没有也算成功。
    static func delete(service: String = defaultService) throws { try secret(service: service).delete() }

    // MARK: 整理用户粘贴的 Key（纯）

    /// fal 的 Key 长 `<id>:<secret>`。用户常把 `Key ` 前缀、引号、首尾空白 / 换行一起粘进来：去掉；中间还有空白或太短就不收。
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if text.lowercased().hasPrefix("key ") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard text.count >= 16, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return text
    }
}

/// 「问 macOS 要授权」那句提示挂过没有（`willAsk` 是 @Sendable 的，不能直接改局部变量）。
final class FalPromptFlag: @unchecked Sendable {
    var value = false
}

/// 这一次运行里读到的 fal Key：一次运行最多问钥匙串一次（也就最多弹一次授权框）。缓存本身是 KeychainSecretCache。
enum FalKeyCache {
    static let shared = KeychainSecretCache(FalKeyStore.secret())
}
