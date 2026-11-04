import Foundation
import SrtFlowMCPKit

// 公开 render 的目录接线只有这一处：runtime quote 和工程新写 render 都复用。
// 不联网、不解释私有配方；参数具体取值及私有支持范围仍由官方 quote 判定。
enum SkyStudioPublicRenderValidation {
    static func validate(_ render: SkyStudioFilm.Render, catalog: SkyStudioCatalog, at path: String) throws {
        guard let model = catalog.model(render.model, kind: render.kind.rawValue), model.operation != "remove_background" else {
            throw SkyStudioFilmReader.error(path, "Use a currently offered public model for this render kind.")
        }
        var allowed = Set(model.params.keys).union(["reference_image_count", "reference_video_count", "reference_video_seconds"])
        if model.params["duration_values"] != nil || model.params["smart_duration"] != nil { allowed.insert("duration") }
        allowed.subtract(["duration_values", "smart_duration"])
        let unknown = Set(render.params.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw SkyStudioFilmReader.error(path + ".params", "Parameters absent from the public catalog: " + unknown.sorted().joined(separator: ", ") + ".")
        }
    }

}
