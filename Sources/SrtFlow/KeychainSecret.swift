import Foundation
import Security

// MARK: - 钥匙串里的一条通用密码（一把 Key）
//
// 管什么：一条通用密码项（服务名 + 账号）存没存过、读、存、删，所有原生调用只在串行执行器上。
// Sky Studio 的 Key（SkyStudioKey）使用它：读钥匙串分两档这条规则只有这一份。
// 不管什么：哪把 Key 用哪个服务名、粘进来的话怎么整理（各自的文件）、何时读（调用方）、缓存和期限（KeychainSecretCache）。
//
// 2026-11-07 探针：固定自签名证书没有 Team ID，分区名单按 cdhash 记，每个新构建仍需「始终允许」。
// 只有 kSecUseAuthenticationUIFail 拦不住分区密码框；静默档必须关闭进程交互，再恢复原状态。
// 所有读写经 KeychainSecretExecutor 互斥，缓存与静默期限由 KeychainSecretCache 管。
// 详见 docs/bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md。
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
    func exists() async -> Bool {
        await KeychainSecretExecutor.run { copyMatching(data: false, access: .silent).0 == errSecSuccess }
    }

    func read(_ access: Access) async -> ReadResult {
        await KeychainSecretExecutor.run { readOnExecutor(access) }
    }

    private func readOnExecutor(_ access: Access) -> ReadResult {
        let (status, result) = copyMatching(data: true, access: access)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return .missing }
            return .key(text)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .needsPermission
        default:
            return .failed(status)
        }
    }

    /// 存（已经有就换掉）。整理用户粘的话是调用方的事，这里原样存。
    func save(_ value: String) async throws {
        let status = await KeychainSecretExecutor.run {
            KeychainSecretExecutor.preconditionIsolated()
            let data = Data(value.utf8)
            var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = baseQuery
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = keychainName
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return status
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    /// 从钥匙串里抹掉。本来就没有也算成功。
    func delete() async throws {
        let status = await KeychainSecretExecutor.run {
            KeychainSecretExecutor.preconditionIsolated()
            return SecItemDelete(baseQuery as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    /// 文件钥匙串保留旧查询标记，并用进程开关挡住它拦不住的分区授权框，不换 LAContext。
    private static var neverPrompt: [String: Any] {
        [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func copyMatching(data: Bool, access: Access) -> (OSStatus, CFTypeRef?) {
        KeychainSecretExecutor.preconditionIsolated()
        var original = DarwinBoolean(true)
        let saved = SecKeychainGetUserInteractionAllowed(&original)
        guard saved == errSecSuccess else { return (saved, nil) }
        let changed = SecKeychainSetUserInteractionAllowed(access == .interactive)
        guard changed == errSecSuccess else { return (changed, nil) }
        // 执行器串行保证关闭交互期间不会有另一档读写。原生调用结束才恢复，不能在超时那边恢复。
        var query = baseQuery
        query[(data ? kSecReturnData : kSecReturnAttributes) as String] = true
        if access == .silent { query.merge(Self.neverPrompt) { _, new in new } }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let restored = SecKeychainSetUserInteractionAllowed(original.boolValue)
        return restored == errSecSuccess ? (status, result) : (restored, nil)
    }
}
