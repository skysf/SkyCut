import Foundation

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
defer { try? secret.delete() }

check(!secret.exists(), "nothing stored yet")
check(secret.read(.silent) == .missing, "a missing key reads as missing")
do {
    try secret.save(SkyStudioKey.normalized("Bearer \(first)\n")!)   // 粘进来带前缀和换行
} catch {
    check(false, "saving failed: \(error)")
}
check(secret.exists(), "the key is there after saving")
check(secret.read(.silent) == .key(first), "the key reads back (tidied), silently")
do { try secret.save(second) } catch { check(false, "replacing failed: \(error)") }
check(secret.read(.silent) == .key(second), "a second save replaces the key")
check(secret.read(.interactive) == .key(second), "the interactive read gives the same key")
do { try secret.delete() } catch { check(false, "deleting failed: \(error)") }
check(!secret.exists(), "the key is gone after deleting")
check(secret.read(.silent) == .missing, "and reads as missing")
do { try secret.delete() } catch { check(false, "deleting nothing is not an error: \(error)") }
check(SkyStudioKey.normalized("nope") == nil, "a bad key is refused before storage")
check(!secret.exists(), "a refused key stores nothing")

if failures > 0 {
    print("✗ \(failures) of \(checks) keychain checks failed.")
    exit(1)
}
print("All \(checks) keychain checks passed.")
