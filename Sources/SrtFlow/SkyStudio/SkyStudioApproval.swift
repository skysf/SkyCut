import Foundation
import SrtFlowMCPKit

// MARK: - Sky Studio 确认码放行的具体请求（纯值 + 本机输入文件的身份）
// 管什么：kind / model / prompt / params / 输入 / 精确报价，和调用方给的落点，组成稳定的身份；同一件事重问相同、换一件事不同。
// 不管什么：给人看的摘要（调用方）、是否超额 / 发码 / 收码（SkyStudioJobGate）；不把随机 idempotency_key 当成同一件事的身份。

enum SkyStudioApproval {
    static func identity(job: SkyStudioJobRequest, credits: Double, context: [String: JSONValue] = [:]) -> String {
        let value: JSONValue = [
            "request": job.quoteBody,
            "inputs": .object(job.inputs.mapValues(JSONValue.string)),
            "credits": .number(credits),
            "context": .object(context)
        ]
        return "skystudio:" + value.encodedString()
    }

    /// 读属性，不读图像 / 音视频内容；原地改写和同路径换文件也要换确认码。
    static func file(_ url: URL) throws -> JSONValue {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        var identity: [String: JSONValue] = ["path": .string(url.standardizedFileURL.path)]
        for (key, name) in [(FileAttributeKey.systemNumber, "device"), (.systemFileNumber, "inode"), (.size, "bytes")] {
            if let number = values[key] as? NSNumber { identity[name] = .string(number.stringValue) }
        }
        if let modified = values[.modificationDate] as? Date { identity["modified"] = .number(modified.timeIntervalSince1970) }
        return .object(identity)
    }
}
