import Foundation
import Security

// KeychainSecret 对真的钥匙串走一遍（本机手动，不在 check-all 里）：存 → 有 → 静默读到 → 换一把 → 读到新的 → 删 → 没有。
// 用一个专门的服务名（`check.srtflow.keychain.<pid>`），跑完一定删掉；同一个进程建的项自己读不弹授权框。
// 不验「别的签名读要弹框」那一半：那要两个不同签名的进程，靠 docs/architecture/sky-studio-account.md 的人工清单和 2026-09-29 的探针。

var failures = 0
var checks = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL [line \(line)] \(message)") }
}

let service = "check.srtflow.keychain.\(getpid())"
let first = "sk-" + String(repeating: "A", count: 43)
let second = "sk-" + String(repeating: "B", count: 43)
let secret = KeychainSecret(service: service, account: "api-key", keychainName: "SkyCut keychain regression")
// 整段真钥匙串检查禁用交互；绝不运行会弹框的变体，失败直接报状态码。
let disabled = await KeychainSecretExecutor.run {
    var previous = DarwinBoolean(true)
    let status = SecKeychainGetUserInteractionAllowed(&previous)
    return (status == 0 ? SecKeychainSetUserInteractionAllowed(false) : status, previous.boolValue)
}
guard disabled.0 == errSecSuccess else { print("Keychain status: \(disabled.0)"); exit(1) }


check(!(await secret.exists()), "nothing stored yet")
check(await secret.read(.silent) == .missing, "a missing key reads as missing")
do {
    try await secret.save(SkyStudioKey.normalized("Bearer \(first)\n")!)   // 粘进来带前缀和换行
} catch {
    check(false, "saving failed: \(error)")
}
check(await secret.exists(), "the key is there after saving")
check(await secret.read(.silent) == .key(first), "the key reads back (tidied), silently")
do { try await secret.save(second) } catch { check(false, "replacing failed: \(error)") }
check(await secret.read(.silent) == .key(second), "a second save replaces the key")
do { try await secret.delete() } catch { check(false, "deleting failed: \(error)") }
check(!(await secret.exists()), "the key is gone after deleting")
check(await secret.read(.silent) == .missing, "and reads as missing")
do { try await secret.delete() } catch { check(false, "deleting nothing is not an error: \(error)") }
check(SkyStudioKey.normalized("nope") == nil, "a bad key is refused before storage")
check(!(await secret.exists()), "a refused key stores nothing")

try? await secret.delete()
let restored = await KeychainSecretExecutor.run { SecKeychainSetUserInteractionAllowed(disabled.1) }
check(restored == errSecSuccess, "restore the process interaction setting")

if failures > 0 {
    print("✗ \(failures) of \(checks) keychain checks failed.")
    exit(1)
}
print("All \(checks) keychain checks passed.")
