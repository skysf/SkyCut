import Foundation
import Security

// MARK: - 钥匙串里的一条通用密码（一把 Key）
//
// 管什么：一条通用密码项（服务名 + 账号）存没存过、读、存、删，以及「这一次运行里读到的记在内存里」（KeychainSecretCache）。
// fal.ai 的 Key（FalKeyStore）和 Sky Studio 的 Key（SkyStudioKey）都是它：读钥匙串分两档这条规则只有这一份。
// 不管什么：哪把 Key 用哪个服务名、粘进来的话怎么整理（各自的文件）、什么时候读（调用方）。
//
// 2026-09-29 本机探针量出来的行为（docs/architecture/fal-generation.md 第六节）：
// - **只读属性（有没有存过）不弹授权框**；读密钥本身时，只有创建这一项的那个签名能免弹窗读 —— 换了签名，第一次读会弹
//   macOS 的「要使用钥匙串里的机密信息」框，点「始终允许」之后这一版不再弹（2026-10-03 起发布版用固定证书签：
//   同一把证书签的下一个构建读前一个构建建的项不弹，docs/architecture/code-signing-and-permissions.md）；
// - 所以读分两档：`.silent`（`kSecUseAuthenticationUIFail`：要弹框就直接回「需要授权」，不弹）和 `.interactive`（弹框、等用户点）；
// - 读到之后这次运行里记在内存里（KeychainSecretCache），一次运行最多弹一次。
// - 不用 data-protection 钥匙串：它要 entitlement，ad-hoc 签名的 App 用不了。

struct KeychainSecret: Sendable {
    enum Access: Sendable { case silent, interactive }

    enum ReadResult: Equatable, Sendable {
        case key(String)
        case missing
        /// 只读了「不弹框」那档、而这一版还没被允许读：要 `.interactive` 才读得到。
        case needsPermission
        case failed(OSStatus)
    }

    struct StoreError: Error, Equatable {
        let status: OSStatus
        var message: String {
            "The macOS keychain refused (\(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"))."
        }
    }

    let service: String
    let account: String
    /// 「钥匙串访问」里看到的名字（不是界面文案，不翻译）。
    let keychainName: String

    /// 存过没有。**只查属性，不读密钥、不弹授权框**。
    func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query.merge(Self.neverPrompt) { _, new in new }
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read(_ access: Access) -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        if access == .silent { query.merge(Self.neverPrompt) { _, new in new } }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return .missing }
            return .key(text)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return .needsPermission
        default:
            return .failed(status)
        }
    }

    /// 存（已经有就换掉）。整理用户粘的话是调用方的事，这里原样存。
    func save(_ value: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = keychainName
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    /// 从钥匙串里抹掉。本来就没有也算成功。
    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    /// 「要弹授权框就直接报错、别弹」。这个常量从 macOS 11 起标了弃用（说改用 `LAContext.interactionNotAllowed`），
    /// 但 2026-09-29 探针量过：**`LAContext` 拦不住老式（文件）钥匙串的授权框**（读别的签名建的项，进程卡在框上等人点），
    /// 老常量才拦得住（直接回 -25308）。所以留着它，警告只有这一处。
    private static var neverPrompt: [String: Any] {
        [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// 这一次运行里读到的 Key 记在内存里：一次运行最多问钥匙串一次（也就最多弹一次授权框）。
actor KeychainSecretCache {
    private let secret: KeychainSecret
    private var cached: String?

    init(_ secret: KeychainSecret) {
        self.secret = secret
    }

    /// 取 Key。要弹授权框时先在主线程上调 `willAsk`（让提示条先说一句这是什么），弹框在后台线程上等，不占主线程。
    func key(willAsk: @escaping @MainActor @Sendable () -> Void = {}) async -> KeychainSecret.ReadResult {
        if let cached { return .key(cached) }
        var result = secret.read(.silent)
        if result == .needsPermission {
            await willAsk()
            let secret = secret
            result = await Task.detached { secret.read(.interactive) }.value
        }
        if case .key(let text) = result { cached = text }
        return result
    }

    /// 只试不弹框的那一档：要授权就回 `.needsPermission`，什么都不弹。后台定时做的事用它（用户没在看，弹出来的框没人懂）。
    func keyWithoutPrompt() -> KeychainSecret.ReadResult {
        if let cached { return .key(cached) }
        let result = secret.read(.silent)
        if case .key(let text) = result { cached = text }
        return result
    }

    /// 用户刚在设置里存了 / 换了 / 删了 Key：直接记下，不用再读一遍（读就可能弹框）。
    func remember(_ key: String?) { cached = key }
}
