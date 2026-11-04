import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 官方生成使用工程里的公开制作计划作为权威。身份只覆盖当前镜头、必要邻镜/切点和相关声音。
// async 初验在读取队列上；最后一次账户/scope await 后，runtime 紧贴 POST 调同步 metadata-only recheck。
// 不读取/解码实际媒体、不生成、不存报价 pin，也不把成片 output review 当成生成前置条件。
enum AIFilmProduction {
    @MainActor
    static func validate(film: SkyStudioFilm, render: SkyStudioFilm.Render, project: VideoEditProject,
                         catalog: SkyStudioCatalog, referenceSources: JSONValue) async throws -> JSONValue {
        let capture = AIFilmProductionCapture(project)
        guard project.documentURL != nil else { throw error("Save the owned project before official generation.") }
        let allowed = allowedImages(capture.original, project: project)
        let result = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result { try identity(film: film, render: render, state: capture.evaluation, generation: capture.generation,
                catalog: catalog, allowedImages: allowed, referenceSources: referenceSources) }
        }
        guard !Task.isCancelled, capture.matches(project) else {
            throw error("The project changed while checking its production sources; read the current plan and quote again.")
        }
        return try result.get()
    }

    @MainActor
    static func recheck(_ expected: JSONValue, film: SkyStudioFilm, render: SkyStudioFilm.Render,
                        project: VideoEditProject, catalog: SkyStudioCatalog, referenceSources: JSONValue) throws {
        let capture = AIFilmProductionCapture(project)
        guard project.documentURL != nil,
              try identity(film: film, render: render, state: capture.evaluation, generation: capture.generation,
                           catalog: catalog, allowedImages: allowedImages(capture.original, project: project),
                           referenceSources: referenceSources) == expected else {
            throw error("Production plan, actual source, anchors or sound changed; obtain and review a new quote before submission.")
        }
    }

    @MainActor
    static func allowedImages(_ state: TimelineState, project: VideoEditProject) -> Set<URL> {
        guard let production = state.production else { return [] }
        return Set(AIFilmProductionJSON.anchorImageURLs(production).filter {
            AIAccessStore.shared.mode == .full || AIWorkspace.shared.allowsReading($0, project: project)
        })
    }

    private static func identity(film: SkyStudioFilm, render: SkyStudioFilm.Render, state: TimelineState, generation: Int,
                                 catalog: SkyStudioCatalog, allowedImages: Set<URL>, referenceSources: JSONValue) throws -> JSONValue {
        guard let production = state.production else {
            throw error("Author save_project.production with the prepared_render and explicit film state/sound before an official quote.")
        }
        let graph = try AIFilmProductionGraph.decode(production)
        guard let index = graph.firstIndex(where: { $0.film.shot.id == film.shot.id }),
              graph[index].film == film, graph[index].render == render else {
            throw error("The exact film and prepared render must match the current authoritative production shot.")
        }
        let relevant = Set([index - 1, index, index + 1].filter { graph.indices.contains($0) })
        var outputs: [JSONValue] = []
        for offset in relevant.sorted() {
            let shot = graph[offset]
            try SkyStudioPublicRenderValidation.validate(shot.render, catalog: catalog, at: "production.render")
            var item: [String: JSONValue] = ["film": shot.film.json, "render": shot.render.json]
            if shot.record.outputClipID != nil {
                let source = try AIFilmProductionSnapshot.authoredSource(shot, state: state)
                let actual = try AIFilmProductionSnapshot.source(shot.record.outputClipID!, state: state, picture: true)
                guard shot.record.boundSourceFingerprint == AIFilmProductionSnapshot.fingerprint(actual) else {
                    throw error("A bound output changed; explicitly rebind its current clip/source before quoting. Saved reviews stay stale.")
                }
                item["output"] = source
            }
            outputs.append(.object(item))
        }
        let shot = graph[index]
        let activeAnchors = shot.record.anchors.filter {
            render.kind == .imageToVideo && render.inputs[$0.role == .first ? "image_url" : "last_frame_url"]?.stringValue != nil
        }
        try AIFilmProductionAnchorReader.validate(activeAnchors, shot: shot, graph: graph, state: state, allowedImages: allowedImages)
        let referenceAnchors = try AIFilmProductionReferences.validate(activeAnchors, sources: referenceSources)
        for role in [FilmProductionState.SourceAnchor.Role.first, .last] {
            let input = role == .first ? "image_url" : "last_frame_url"
            let hasSource = graph.contains { candidate in
                candidate.record.outputClipID != nil && [FilmProductionState.SourceAnchor.SourceEdge.firstUsed, .lastUsed].contains {
                    AIFilmProductionAnchorReader.allowed(role: role, edge: $0, from: candidate.film.shot.id, for: shot)
                }
            }
            if render.kind == .imageToVideo, render.inputs[input]?.stringValue != nil, hasSource,
               !activeAnchors.contains(where: { $0.role == role }) {
                throw error("The actual " + role.rawValue + " frame needs a valid source anchor for its bound source shot.")
            }
        }
        var seams: [JSONValue] = []
        for left in [index - 1, index] where graph.indices.contains(left) && graph.indices.contains(left + 1) {
            if let value = try? AIFilmProductionSnapshot.authoredSeam(graph[left], graph[left + 1], state: state) { seams.append(value) }
        }
        let ids = Set(relevant.map { graph[$0].film.shot.id })
        let cues: [JSONValue] = try production.soundCues.filter { !ids.isDisjoint(with: $0.shotIDs) }.map { cue in
            var item: [String: JSONValue] = ["plan": try AIFilmProductionSnapshot.encoded(cue)]
            if let audio = cue.audioClipID { item["audio"] = try AIFilmProductionSnapshot.source(audio, state: state, picture: false) }
            if let aligned = try? AIFilmProductionSnapshot.cue(cue, shots: graph, state: state) { item["current_alignment"] = aligned }
            return .object(item)
        }
        let contents: JSONValue = ["project_generation": .number(Double(generation)), "production_revision": .number(Double(production.revision)),
            "shots": .array(outputs), "seams": .array(seams), "sound_cues": .array(cues),
            "anchors": .array(try shot.record.anchors.map(AIFilmProductionAnchorReader.json)), "reference_anchors": referenceAnchors]
        return ["production_revision": .number(Double(production.revision)), "shot_id": .string(film.shot.id),
                "shot_revision": .number(Double(film.shot.revision)), "identity": .string(AIFilmProductionSnapshot.fingerprint(contents))]
    }

    private static func error(_ message: String) -> SkyStudioFilmError { SkyStudioFilmReader.error("production", message) }
}
