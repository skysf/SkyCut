import Foundation
import SrtFlowMCPKit

// 官方报价/提交所依赖的已存公开故事与当前画面身份；只读，绝不存私有配方或收费凭据。
// 显式引用准备可以先于故事；已提交原单的 GET 恢复不经过这里。
@MainActor
enum SkyStudioOfficialAuthority {
    static func snapshot(request: SkyStudioJobRequest, referenceSources: JSONValue, catalog: SkyStudioCatalog, project: VideoEditProject) async throws -> JSONValue {
        let (film, render) = try declaration(request)
        return try await AIFilmProduction.validate(film: film, render: render, project: project, catalog: catalog, referenceSources: referenceSources)
    }

    static func recheck(_ expected: JSONValue, request: SkyStudioJobRequest, referenceSources: JSONValue, catalog: SkyStudioCatalog, project: VideoEditProject) throws {
        let (film, render) = try declaration(request)
        try AIFilmProduction.recheck(expected, film: film, render: render, project: project, catalog: catalog, referenceSources: referenceSources)
    }

    private static func declaration(_ request: SkyStudioJobRequest) throws -> (SkyStudioFilm, SkyStudioFilm.Render) {
        guard let film = request.film, let kind = SkyStudioFilm.Render.Kind(rawValue: request.kind) else {
            throw AIToolError("An official quote requires its public film and supported render kind.")
        }
        let render = SkyStudioFilm.Render(kind: kind, model: request.model, prompt: request.prompt ?? "",
            params: request.params, inputs: request.allInputs, context: film.context)
        return (film, render)
    }
}
