import Foundation

// SkyStudioKey：粘进来的 Key 怎么整理、钥匙串那一条叫什么；SkyStudioMachine：发出去的机器号怎么算。
// 钥匙串本身不碰（同 fal：真钥匙串在 scripts/check-fal-keychain.sh，本机手动；两把 Key 的读写是同一份 KeychainSecret）。

func runKeyChecks() {
    let key = "sk-" + "abcdefghijklmnopqrstuvwxyz0123456789-_ABCDE"
    checkEqual(key.count, 46, "the test key has the contract's length")
    checkEqual(SkyStudioKey.normalized(key), key, "a clean key")
    checkEqual(SkyStudioKey.normalized("  \(key)\n"), key, "spaces and a newline around it")
    checkEqual(SkyStudioKey.normalized("\"\(key)\""), key, "quotes around it")
    checkEqual(SkyStudioKey.normalized("Bearer \(key)"), key, "pasted with Bearer")
    checkEqual(SkyStudioKey.normalized("bearer   \(key) "), key, "bearer in lower case")
    checkEqual(SkyStudioKey.normalized("sk-" + String(repeating: "x", count: 60)), "sk-" + String(repeating: "x", count: 60), "a longer key is kept")
    check(SkyStudioKey.normalized("pk-" + String(repeating: "x", count: 43)) == nil, "not sk-")
    check(SkyStudioKey.normalized("sk_" + String(repeating: "x", count: 43)) == nil, "sk_ is not sk-")
    check(SkyStudioKey.normalized("sk-abc") == nil, "too short")
    check(SkyStudioKey.normalized("sk-abcdefghij klmnopqrstuvwxyz") == nil, "a space inside")
    check(SkyStudioKey.normalized("sk-abcdefghij+klmnopqrstuvwxyz") == nil, "a + is not URL-safe")
    check(SkyStudioKey.normalized("sk-abcdefghijklmnopqrstuvwxyzé") == nil, "no letters outside ASCII")
    check(SkyStudioKey.normalized("") == nil, "empty")

    // 钥匙串那一条：bundle id + .skystudio（自检进程没有 bundle id，用的是兜底），账号 api-key。身份类的名字，永远不改。
    checkEqual(SkyStudioKey.defaultService, "com.srtflow.SrtFlow.skystudio", "the keychain service")
    checkEqual(SkyStudioKey.secret.service, SkyStudioKey.defaultService, "the secret uses it")
    checkEqual(SkyStudioKey.secret.account, "api-key", "the keychain account")
    check(SkyStudioKey.secret.service != "com.srtflow.SrtFlow.fal", "a different item from the fal.ai key")
}

func runMachineChecks() {
    // 钉死的一组：盐或算法一改，每台 Mac 在 Sky Studio 眼里都成了新机器（又能再体验一次）—— 这条就红。
    let uuid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
    let pinned = "f18729daee8e8c7ba6bb59c58851a3e64486ace77dc80fe60e487c10633434f9"
    checkEqual(SkyStudioMachine.hash(hardwareUUID: uuid), pinned, "SHA-256(hardware UUID + salt), pinned")
    checkEqual(SkyStudioMachine.hash(hardwareUUID: " \(uuid.lowercased())\n"), pinned, "case and spaces do not matter")
    check(SkyStudioMachine.hash(hardwareUUID: "ABCDEF12-3456-7890-ABCD-EF1234567891") != pinned, "another Mac, another hash")

    // 这台机器：读得到硬件 UUID，发出去的是 64 位小写十六进制，不是原样的 UUID。
    guard let raw = SkyStudioMachine.hardwareUUID() else {
        check(false, "this Mac reports a hardware UUID (IOPlatformUUID)")
        return
    }
    let current = SkyStudioMachine.current ?? ""
    checkEqual(current, SkyStudioMachine.hash(hardwareUUID: raw), "current is the hash of this Mac's UUID")
    checkEqual(current.count, 64, "64 characters")
    check(current.allSatisfy { "0123456789abcdef".contains($0) }, "lower-case hex")
    check(!current.localizedCaseInsensitiveContains(raw.replacingOccurrences(of: "-", with: "")), "the raw UUID does not leave the Mac")
}
