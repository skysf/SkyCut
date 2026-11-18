import Foundation
import Observation
import SrtFlowMCPKit
import SrtFlowWebMotionKit

// An inspector's uncommitted parameter draft. The timeline changes only after a successful render of the same document/clip.
@MainActor
@Observable
final class WebMotionEditorModel {
    private let project: VideoEditProject
    private let generation: Int
    private var original: EditClip
    private var sourceLane: WebMotionSourceLane?
    var record: WebMotionClipRecord
    private(set) var isRendering = false
    private(set) var error: String?

    init(project: VideoEditProject, clip: EditClip) {
        precondition(clip.webMotion != nil)
        self.project = project
        generation = project.documentGeneration
        original = clip
        sourceLane = WebMotionSourceLane.capture(clip.id, in: project.state)
        record = clip.webMotion!
    }

    var hasChanges: Bool { record != original.webMotion }
    var isStale: Bool {
        !project.isCurrentGeneration(generation) || project.state.clip(with: original.id) != original
            || WebMotionSourceLane.capture(original.id, in: project.state) != sourceLane
    }

    var fields: [WebMotionParameterField] {
        let values = WebMotionParameters.object(record.parametersJSON)
        let fields = record.parameterFields.isEmpty ? WebMotionParameters.inferredFields(values) : record.parameterFields
        return fields.filter { !["duration", "hit"].contains($0.key) }
    }

    func string(for key: String) -> String { WebMotionParameters.object(record.parametersJSON)[key]?.stringValue ?? "" }
    func number(for key: String) -> Double { WebMotionParameters.object(record.parametersJSON)[key]?.doubleValue ?? 0 }

    func setString(_ value: String, for key: String) { set(.string(value), for: key) }
    func setNumber(_ value: Double, for key: String) {
        if key == "duration" { record.duration = value }
        if key == "hit" { record.hitTime = value }
        set(.number(value), for: key)
    }
    func setDuration(_ value: Double) { setNumber(value, for: "duration") }
    func setHit(_ value: Double) { setNumber(value, for: "hit") }

    private func set(_ value: JSONValue, for key: String) {
        var values = WebMotionParameters.object(record.parametersJSON)
        values[key] = value
        do {
            record.parametersJSON = try WebMotionParameters.canonical(values)
            error = nil
        } catch { self.error = WebMotionUIError.message(error) }
    }

    func validateCurrent() throws {
        guard !isStale else {
            throw AIToolError(L10n("This motion changed. Reload its parameters before re-rendering."))
        }
    }

    func reload() {
        guard project.isCurrentGeneration(generation), let current = project.state.clip(with: original.id),
              let record = current.webMotion, !isRendering else { return }
        original = current
        sourceLane = WebMotionSourceLane.capture(current.id, in: project.state)
        self.record = record
        error = nil
    }

    /// The captured document and original clip are checked at Task entry as well as by the shared render/commit service.
    func render() async -> Bool {
        guard !isRendering else { return false }
        isRendering = true
        error = nil
        defer { isRendering = false }
        do {
            try validateCurrent()
            guard record.duration.isFinite, record.duration > 0, record.duration <= WebMotionCaps.maxDuration,
                  WebMotionRequest.frameCount(duration: record.duration, fps: record.fps) > 0 else {
                throw AIToolError(String(format: L10n("Render length must include at least one frame and be at most %@ seconds."),
                                        String(Int(WebMotionCaps.maxDuration))))
            }
            for field in fields where field.kind == .font {
                guard WebMotionEnvironment.hasFont(string(for: field.key)) else {
                    throw AIToolError(L10n("Choose an installed typeface before re-rendering."))
                }
            }
            let placed = try await WebMotionActions.place(record: record, replacing: original.id, project: project, force: true)
            original = placed.clip
            sourceLane = WebMotionSourceLane.capture(original.id, in: project.state)
            record = placed.rendered.record
            return true
        } catch {
            self.error = WebMotionUIError.message(error)
            return false
        }
    }

    /// Prepare the stored source beside its movie; revealing the returned URL is a separate UI action.
    func pageURL() async throws -> URL {
        try validateCurrent()
        let stored = original.webMotion!
        let movie = original.sourceURL
        try await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            Result {
                try FileManager.default.createDirectory(at: movie.deletingLastPathComponent(), withIntermediateDirectories: true)
                try WebMotionCache.writePage(stored, movie: movie)
            }
        }.get()
        try validateCurrent()
        return movie.deletingPathExtension().appendingPathExtension("html")
    }
}

// Renderer errors deliberately retain the page's exact diagnostic text; ordinary model errors expose their message.
enum WebMotionUIError {
    static func message(_ error: Error) -> String {
        if let render = error as? WebMotionRenderError { return render.description }
        if let tool = error as? AIToolError { return tool.message }
        return error.localizedDescription
    }
}
