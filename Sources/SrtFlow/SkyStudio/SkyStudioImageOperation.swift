import Foundation
import SrtFlowMCPKit

// MARK: - 图片操作的类型与输入合同
// 管什么：换机位的离散移动、图片放大倍率和单图合同；不计价、不组合供应商提示词、不跑视频 upscale。
struct SkyStudioCameraAngle: Equatable, Sendable {
    static let rotations = [-180, -135, -90, -45, 0, 45, 90, 135, 180]
    static let tilts = [-45, 0, 45]
    static let zooms = [-1, 0, 1, 2]
    var rotate: Int
    var tilt: Int
    var zoom: Int

    var json: JSONValue { ["rotate": .number(Double(rotate)), "tilt": .number(Double(tilt)), "zoom": .number(Double(zoom))] }
    var isIdentity: Bool { rotate == 0 && tilt == 0 && zoom == 0 }

    static func read(_ value: JSONValue) throws -> Self {
        guard let fields = value.objectValue else { throw AIToolError("camera_angle must be an object with rotate, tilt and zoom.") }
        guard Set(fields.keys).isSubset(of: ["rotate", "tilt", "zoom"]) else { throw AIToolError("camera_angle accepts only rotate, tilt and zoom.") }
        let args = AIToolArguments(value)
        func stop(_ name: String, choices: [Int]) throws -> Int {
            let number = try args.int(name) ?? 0
            guard choices.contains(number) else { throw AIToolError("camera_angle.\(name) must be one of: \(choices.map(String.init).joined(separator: ", ")).") }
            return number
        }
        let result = try Self(rotate: stop("rotate", choices: rotations), tilt: stop("tilt", choices: tilts), zoom: stop("zoom", choices: zooms))
        guard !result.isIdentity else { throw AIToolError("camera_angle requires a nonzero rotate, tilt or zoom; nothing was quoted or started.") }
        return result
    }
}

enum SkyStudioImageOperation {
    static let names = ["generate", "remove_background", "camera_angle", "upscale"]
    static let factors = ["x2", "x3", "x4"]

    static func validateRoute(_ args: AIToolArguments) throws {
        if ["camera_angle", "upscale"].contains(try args.string("operation")?.lowercased() ?? "") {
            if args.has("film") { throw AIToolError("camera_angle and image upscale do not accept film. Use ordinary generate_media with kind=image.") }
            if let kind = try args.string("kind"), kind.lowercased() != "image" { throw AIToolError("camera_angle and image upscale require kind=image; upscale_clip is video-only.") }
        }
    }

    static func problem(model: SkyStudioModel, ask: SkyStudioGeneration.Ask, references: SkyStudioReferencePlan) -> String? {
        if ask.cameraAngle != nil && ask.operation != "camera_angle" { return "camera_angle controls require operation=camera_angle." }
        if ask.upscaleFactor != nil && ask.operation != "upscale" { return "upscale_factor requires image operation=upscale, not upscale_clip." }
        guard ask.operation != "generate" else { return nil }
        guard model.kind == "image" else { return "Image operations require kind=image." }
        if references.files.count != 1 || references.count("image") != 1 || references.webURL != nil {
            return "operation=\(ask.operation) requires exactly one input image: image or one reference_images entry."
        }
        if ask.operation == "camera_angle" {
            guard let angle = ask.cameraAngle, !angle.isIdentity else { return "operation=camera_angle requires camera_angle with a nonzero move." }
            for (axis, value) in [("rotate", angle.rotate), ("tilt", angle.tilt), ("zoom", angle.zoom)] {
                let stops = model.params["camera_angle"]?[axis]?.arrayValue?.compactMap(\.intValue) ?? []
                if !stops.contains(value) { return "camera_angle.\(axis) is not offered by this model." }
            }
        }
        if ask.operation == "upscale" {
            if ask.resolution != nil || ask.aspectRatio != nil { return "Image upscale does not accept resolution or aspect_ratio; output follows the source shape." }
            let factor = ask.upscaleFactor ?? model.defaults["upscale_factor"]?.stringValue ?? "x2"
            if !model.choices("upscale_factor").contains(factor) { return "upscale_factor is not offered by this model." }
        }
        return nil
    }
}
