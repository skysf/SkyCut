import CryptoKit
import Foundation
import IOKit

// MARK: - 这台 Mac 的编号（每个请求的 `X-SkyCut-Machine`）
//
// 管什么：Sky Studio 按「每台 Mac 只给一次体验」认机器（Sky Studio 仓库 docs/agents/skycut-api.md「Transport」「GET /me」）。
// 发过去的是 **SHA-256(硬件 UUID + SkyCut 的盐)** 的 64 位小写十六进制：原始的硬件 UUID 不离开这台 Mac，电脑名（里面常带人的真名）也不发。
// 不管什么：什么时候发（SkyStudioAPI 每个请求都带）。
//
// 仓库是公开的，盐也就是公开的：它只让这串数和别的服务手里的硬件 UUID 对不上号，不是秘密。
// **盐和算法永远不改**：改了，每台 Mac 在 Sky Studio 眼里都成了新机器，又能再体验一次。checks/SkyStudio/MachineChecks.swift 钉着一组算好的值。

enum SkyStudioMachine {
    static let salt = "skycut-machine-v1:7c1f3a9e"

    /// 硬件 UUID → 发给 Sky Studio 的那串（大小写、首尾空白不影响结果）。
    static func hash(hardwareUUID: String) -> String {
        let normalized = hardwareUUID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digest = SHA256.hash(data: Data((normalized + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 这台 Mac 的（一次运行读一次）；读不到硬件 UUID 是 nil，请求里就不带这一个头（/me 会因此报错，设置里照实显示）。
    static let current: String? = hardwareUUID().map(hash(hardwareUUID:))

    /// IOKit 里 `IOPlatformExpertDevice` 的 `IOPlatformUUID`（「关于本机」→「系统报告」里的「硬件 UUID」）。
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let uuid = value as? String, !uuid.isEmpty else { return nil }
        return uuid
    }
}
