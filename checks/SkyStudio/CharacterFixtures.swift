import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SrtFlowMCPKit

// 同最终合同形状的免费夹具；动态模型 / 档位另测，不能把这些值当成客户端价格表或生产上线证据。
let nativeCharacterJobID = "22222222-2222-4222-8222-222222222222"
func characterCapabilitiesJSON() -> JSONValue {
    ["defaults": ["model": "nano2", "resolution": "2K", "create_aspect_ratio": "21:9", "headshot_aspect_ratio": "1:1"],
     "max_prompt_characters": 25000, "roles": ["front", "side", "back", "headshot"], "required_import_roles": ["front", "side", "back"],
     "models": [["id": "nano2", "resolution": ["2K", "4K"], "prices": ["2K": ["text": 29, "reference": 39], "4K": ["text": 44, "reference": 64]]],
                ["id": "future-character-model", "resolution": ["future-tier"], "prices": ["future-tier": ["text": 7, "reference": 9]]]],
     "import_credits": 0, "mutation_credits": 0, "billing_policy": ["version": "2026-10-31", "no_refund_after_provider_success": true]]
}

func characterQuoteJSON(_ body: JSONValue) -> JSONValue {
    if body["operation"] == "character_import" { return ["credits": 0, "typical_seconds": 0, "billing_policy": characterCapabilitiesJSON()["billing_policy"]!] }
    var value: [String: JSONValue] = ["credits": body["source_type"] == "text" ? 29 : 39,
        "typical_seconds": 40, "character_operation": body["operation"]!, "model": body["model"]!,
        "effective_params": ["resolution": body["params"]!["resolution"]!, "aspect_ratio": body["operation"] == "character_headshot" ? "1:1" : "21:9", "reference_image_count": body["source_type"] == "text" ? 0 : 1],
        "billing_policy": characterCapabilitiesJSON()["billing_policy"]!]
    if body["operation"] == "character_headshot" { value["character_usage"] = characterUsage(roles: ["front"]) }
    return .object(value)
}

func nativeCharacterStatus(operation: String = "character_create", state: String = "done", characterStatus: String = "ready", charged: Double = 29) -> JSONValue {
    let id = operation == "character_headshot" ? characterID : nativeCharacterJobID
    var character = characterJSON().objectValue!
    character["id"] = .string(id)
    var result: [String: JSONValue] = ["character_id": .string(id)]
    if characterStatus == "ready" { result["character"] = .object(character) }
    if operation != "character_import" { result["url"] = "https://assets.example/source.png" }
    return ["job_id": .string(nativeCharacterJobID), "status": .string(state), "character_id": .string(id),
        "character_operation": .string(operation), "character_status": .string(characterStatus),
        "generation_status": operation == "character_import" ? "not_submitted" : "succeeded", "delivery_status": characterStatus == "ready" ? "delivered" : "saving",
        "billing": ["status": charged == 0 ? "not_charged" : "charged", "credits_charged": .number(charged)],
        "credits_charged": .number(charged), "result": .object(result)]
}

func writeCharacterPhoto(_ folder: URL, name: String = "photo.png") throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(name)
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return file
}
