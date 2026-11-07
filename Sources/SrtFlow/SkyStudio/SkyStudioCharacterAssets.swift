import Foundation
import SrtFlowMCPKit

// 官方 render 的真实角色资产声明：只从本账号 GET DTO 取得 URL，不下载图片。
// 这里的声明供权威制作图比对；服务器仍必须以 character_id 重新核对所有权、选图、pin 和快照。
struct SkyStudioCharacterAssets: Equatable, Sendable, Codable {
    var usage: SkyStudioCharacterUsage
    var urls: [String]

    func inputs(addingTo original: [String: JSONValue]) -> [String: JSONValue] {
        var value = original
        if usage.mode == "frames" { value["image_url"] = .string(urls[0]) }
        else {
            let local = value["references"]?.arrayValue ?? []
            value["references"] = .array(local + urls.map { ["type": "image", "url": .string($0)] })
        }
        return value
    }

    var json: JSONValue { ["usage": usage.json, "assets": .array(urls.map(JSONValue.string))] }
}

