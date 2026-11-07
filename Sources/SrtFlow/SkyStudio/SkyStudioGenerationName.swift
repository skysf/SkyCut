import Foundation
import SrtFlowCore

// 生成文件的短名字：显式 name 优先，没提示词的图片操作用源图 + 操作；撞名仍由 ExportFileName 统一处理。
enum SkyStudioGenerationName {
    static func stem(name: String?, generation: SkyStudioGeneration, source: URL?, fallback: String) -> String {
        let title: String
        if let name { title = AIVoiceoverPlacement.fileStem(name) }
        else if let source, ["camera_angle", "upscale"].contains(generation.operation) {
            let base = ExportFileName.stem(from: AIVoiceoverPlacement.fileStem(source.deletingPathExtension().lastPathComponent),
                droppingExtension: "", fallback: fallback)
            title = base + " " + (generation.operation == "camera_angle" ? "angle" : generation.params["upscale_factor"]?.stringValue ?? "x2")
        } else { title = AIVoiceoverPlacement.fileStem(generation.prompt) }
        return ExportFileName.stem(from: title, droppingExtension: "", fallback: fallback)
    }
}
