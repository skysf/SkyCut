import Foundation
import Observation

// A tap/drop's immutable destination, captured before creating a Task. Index changes cannot retarget another upper track.
struct WebMotionPresetRequest {
    var templateID: String
    var at: Double
    var generation: Int
    var target: TrackDropTarget?
    var laneID: UUID?

    @MainActor
    init(templateID: String, at: Double, preferring target: TrackDropTarget? = nil, project: VideoEditProject) {
        self.templateID = templateID
        self.at = at
        generation = project.documentGeneration
        self.target = target
        if case .overlay(let index) = target, project.state.overlayTracks.indices.contains(index) {
            laneID = project.state.overlayTracks[index].id
        }
    }

    func resolvedTarget(in state: TimelineState) -> TrackDropTarget? {
        guard case .overlay = target else { return target }
        return laneID.flatMap { id in state.overlayTracks.firstIndex { $0.id == id && !$0.isHidden } }
            .map(TrackDropTarget.overlay) ?? .newOverlayTop
    }
}

// Local card/drop work state. Both entry points resolve a fresh template and use the same render/commit service as the AI.
@MainActor
@Observable
final class WebMotionPresetModel {
    private let project: VideoEditProject
    private(set) var isRendering = false
    private(set) var error: String?

    init(project: VideoEditProject) { self.project = project }

    func add(_ request: WebMotionPresetRequest) async -> Bool {
        guard !isRendering else { return false }
        isRendering = true
        error = nil
        defer { isRendering = false }
        do {
            guard project.isCurrentGeneration(request.generation), !Task.isCancelled else {
                throw AIToolError(L10n("The project changed before this motion could be added. Try again in the current project."))
            }
            let record = try MotionPresetLibrary.template(request.templateID, in: project.state)
            let placed = try await WebMotionActions.place(record: record, at: request.at,
                                                          preferring: request.resolvedTarget(in: project.state), project: project)
            project.select(placed.clip.id, additive: false)
            return true
        } catch {
            self.error = WebMotionUIError.message(error)
            return false
        }
    }
}
