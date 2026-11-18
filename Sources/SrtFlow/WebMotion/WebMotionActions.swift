import Foundation

// One render and one timeline commit for both UI and AI. Async preparation never replaces a newer clip or another document.
@MainActor
enum WebMotionActions {
    struct Placement {
        var clip: EditClip
        var rendered: WebMotionCache.Rendered
        var warnings: [String]
    }

    /// The cache file changes with its inputs, so undo continues to reference the preceding render.
    static func place(record: WebMotionClipRecord, replacing id: UUID? = nil, at: Double? = nil, hitAt: Double? = nil,
                      preferring target: TrackDropTarget? = nil, project: VideoEditProject) async throws -> Placement {
        let record = try WebMotionParameters.normalized(record)
        try WebMotionValidation.validate(record)
        let generation = project.documentGeneration
        let before = id.flatMap { project.state.clip(with: $0) }
        let sourceLane = WebMotionSourceLane.capture(id, in: project.state)
        if id != nil, before?.webMotion == nil { throw AIToolError(L10n("clip_id must identify an existing web-motion clip.")) }
        let start = try startTime(record, before: before, at: at, hitAt: hitAt)
        let requested = target ?? before.flatMap { project.state.location(of: $0.id)?.track }.flatMap { slot -> TrackDropTarget? in
            if case .overlay(let index) = slot { return .overlay(index) }
            return nil
        } ?? (project.state.overlayTracks.isEmpty ? .newOverlayTop : .overlay(0))
        try requireUpperTrack(requested)
        let laneID: UUID?
        if case .overlay(let index) = requested, project.state.overlayTracks.indices.contains(index),
           !project.state.overlayTracks[index].isHidden { laneID = project.state.overlayTracks[index].id }
        else { laneID = nil }
        let key = "\(generation):\(id?.uuidString ?? UUID().uuidString)"
        guard WebMotionActivity.claim(key) else { throw AIToolError(L10n("This motion is already rendering. Wait for that render to finish.")) }
        defer { WebMotionActivity.release(key) }
        let directory = cacheDirectory(for: project)
        let rendered = try await WebMotionCache.render(record, directory: directory)
        let probed = await MediaProbe.probe(url: rendered.file, ffmpeg: nil)
        let info = try probed.get()
        try Task.checkCancellation()
        guard project.isCurrentGeneration(generation),
              id == nil || (project.state.clip(with: id!) == before
                && WebMotionSourceLane.capture(id, in: project.state) == sourceLane) else {
            throw AIToolError(L10n("The project, clip, or source track changed during rendering. The movie was kept in the cache; no edit was applied."))
        }
        let prepared = try preparedClip(before, rendered: rendered, info: info, start: start)
        let placed = try commit(prepared, replacing: id, requested: requested, laneID: laneID, explicitTarget: target, project: project)
        return Placement(clip: placed, rendered: rendered, warnings: WebMotionEnvironment.warnings(for: rendered.record))
    }

    private static func preparedClip(_ before: EditClip?, rendered: WebMotionCache.Rendered,
                                     info: MediaInfo, start: Double) throws -> EditClip {
        var clip = before ?? EditClip(sourceURL: rendered.file, sourceDuration: info.duration, timelineStart: start)
        clip.sourceURL = rendered.file
        clip.webMotion = rendered.record
        clip.info = info
        if let before {
            // Parameter-only edits retain the cut, speed, effects and placement. Changing source duration on a whole clip
            // changes its length; a trimmed/split clip keeps its source range when the new movie can still cover it.
            if isWhole(before) {
                clip.sourceDuration = info.duration
            }
            guard clip.sourceStart + clip.sourceDuration <= info.duration + 0.000001 else {
                throw AIToolError(L10n("The new duration does not cover this trimmed clip. Increase duration or shorten the clip first."))
            }
        }
        clip.timelineStart = start
        return clip
    }

    private static func commit(_ prepared: EditClip, replacing id: UUID?, requested: TrackDropTarget,
                               laneID: UUID?, explicitTarget: TrackDropTarget?, project: VideoEditProject) throws -> EditClip {
        let start = prepared.timelineStart
        let keepsLane: Bool
        if let id, explicitTarget == nil, let location = project.state.location(of: id), !location.track.isMain, !location.track.isAudio {
            let busy = project.state[track: location.track].filter { $0.id != id }
                .map { TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd) }
            keepsLane = TimelineState.fits(start: start, duration: prepared.timelineDuration, among: busy)
            if !keepsLane, project.state.isLaneHidden(location.track) {
                throw AIToolError(L10n("The new motion duration overlaps another clip on its hidden track. Shorten it or choose another upper track."))
            }
        } else { keepsLane = false }
        AIUndoGrouping.step(project.effectiveUndoManager) {
            project.perform { state in
                if let id, keepsLane {
                    state.update(id) { $0 = prepared }
                    return
                }
                if let id, let location = state.location(of: id) {
                    var clips = state[track: location.track]
                    clips.removeAll { $0.id == id }
                    state[track: location.track] = clips
                }
                let resolved: TrackDropTarget
                if case .overlay = requested {
                    resolved = laneID.flatMap { id in state.overlayTracks.firstIndex { $0.id == id && !$0.isHidden } }
                        .map(TrackDropTarget.overlay) ?? .newOverlayTop
                } else { resolved = requested }
                let landing = state.mediaImportLandings([.init(duration: prepared.timelineDuration, isAudio: false)],
                                                       firstStart: start, preferring: resolved)
                state.insertImported([prepared], at: landing)
            }
        }
        guard let placed = project.state.clip(with: prepared.id) else { throw AIToolError(L10n("The rendered motion could not be placed.")) }
        return placed
    }

    static func startTime(_ record: WebMotionClipRecord, before: EditClip?, at: Double?, hitAt: Double?) throws -> Double {
        guard at == nil || hitAt == nil else { throw AIToolError(L10n("Pass at or hit_at, not both.")) }
        if hitAt != nil, let before, !isWhole(before),
           record.hitTime < before.sourceStart || record.hitTime >= before.sourceStart + before.sourceDuration {
            throw AIToolError(L10n("The hit is outside this trimmed clip. Choose a hit inside its source range first."))
        }
        let localHit = (record.hitTime - (before?.sourceStart ?? 0)) / max(0.05, before?.speed ?? 1)
        let start = at ?? hitAt.map { $0 - localHit } ?? before?.timelineStart ?? 0
        guard start.isFinite, start >= 0 else {
            throw AIToolError(L10n("The requested hit would start before the timeline. Move hit_at later or reduce hit."))
        }
        return start
    }

    private static func isWhole(_ clip: EditClip) -> Bool {
        abs(clip.sourceStart) < 0.000001 && abs(clip.sourceDuration - (clip.info?.duration ?? clip.webMotion?.duration ?? 0)) < 0.000001
    }

    static func requireUpperTrack(_ target: TrackDropTarget) throws {
        switch target {
        case .overlay, .newOverlayTop, .insertOverlay: return
        default: throw AIToolError(L10n("Web motion needs an upper video track (V2 or higher)."))
        }
    }

    static func cacheDirectory(for project: VideoEditProject) -> URL {
        if let url = project.documentURL { return WebMotionProjectFiles.directory(for: url) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("SrtFlow/Motion/\(project.documentGeneration)", isDirectory: true)
    }
}

// Transient per-document render ownership; it never enters the project file or drives timeline view updates.
@MainActor
enum WebMotionActivity {
    private static var active: Set<String> = []
    static func claim(_ key: String) -> Bool { active.insert(key).inserted }
    static func release(_ key: String) { active.remove(key) }
}
