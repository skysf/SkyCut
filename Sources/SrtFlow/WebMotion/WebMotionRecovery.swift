import Foundation

// Restores missing generated movies without imported-media relinking or undo entries. Called on open, on runtime revalidation
// (every preview rebuild and app activation) and after going back to a saved version.
// Which movies are there is asked off the main thread, on the cache folder's queue (`WebMotionCacheFiles.queue`): the project's
// folder can be on a slow, sleeping or stuck drive, and these checks used to run on the main thread on every preview rebuild
// (docs/architecture/blocking-media-reads.md "Destination drives", docs/bugfixes/2026-11-19-drive-checks-on-main-thread.md).
// The answer is applied only to clips that are still what was looked at; a motion clip that appeared or changed meanwhile is
// looked at again.
@MainActor
enum WebMotionRecovery {
    /// For the checks only: asked instead of the drive whether a movie is there (to slow the drive down and see where it runs).
    nonisolated(unsafe) static var existsForChecks: (@Sendable (URL) -> Bool)?

    static func start(for project: VideoEditProject) {
        let generation = project.documentGeneration
        let looked = project.state.allClips.filter { $0.webMotion != nil }
        guard !looked.isEmpty else { return }
        let key = "recovery:\(generation)"
        guard WebMotionActivity.claim(key) else { return }
        let projectURL = project.documentURL
        project.trackImportTask(Task { [weak project] in
            var again = false
            defer {
                WebMotionActivity.release(key)
                if again, let project { start(for: project) }
            }
            let found = await locate(looked, projectURL: projectURL)
            guard let project, !Task.isCancelled, project.isCurrentGeneration(generation) else { return }
            var expected = Dictionary(uniqueKeysWithValues: looked.map { ($0.id, Seen($0)) })
            let missing = repair(looked, found: found, in: project, expected: &expected)
            await render(missing, in: project, generation: generation, expected: &expected)
            guard !Task.isCancelled, project.isCurrentGeneration(generation) else { return }
            again = project.state.allClips.contains { clip in clip.webMotion != nil && expected[clip.id] != Seen(clip) }
        })
    }

    /// What recovery last knew of a motion clip: its source and where its movie is.
    private struct Seen: Equatable {
        var record: WebMotionClipRecord?
        var sourceURL: URL
        init(_ clip: EditClip) { (record, sourceURL) = (clip.webMotion, clip.sourceURL) }
    }

    /// Each clip's movie as the drive has it (`WebMotionProjectFiles.cache`), asked on the cache folder's queue.
    nonisolated private static func locate(_ clips: [EditClip], projectURL: URL?) async -> [UUID: WebMotionProjectFiles.Cache] {
        let exists = existsForChecks ?? WebMotionProjectFiles.onDrive
        return await MediaReadQueue.run(on: WebMotionCacheFiles.queue) {
            var found: [UUID: WebMotionProjectFiles.Cache] = [:]
            for clip in clips { found[clip.id] = WebMotionProjectFiles.cache(for: clip, projectURL: projectURL, exists: exists) }
            return found
        }
    }

    /// Points the clips still as they were looked at to their carried movie (or to where a missing one belongs), as one document
    /// repair; returns those whose movie is missing, as they are now.
    private static func repair(
        _ looked: [EditClip], found: [UUID: WebMotionProjectFiles.Cache], in project: VideoEditProject, expected: inout [UUID: Seen]
    ) -> [EditClip] {
        var moved: [UUID: URL] = [:]
        var missing: [EditClip] = []
        for before in looked {
            guard let cache = found[before.id], var current = project.state.clip(with: before.id), Seen(current) == Seen(before) else {
                continue
            }
            if cache.sourceURL != current.sourceURL { moved[before.id] = cache.sourceURL }
            current.sourceURL = cache.sourceURL
            expected[before.id] = Seen(current)
            if cache.missing { missing.append(current) }
        }
        if !moved.isEmpty {
            project.applyDocumentRepair { state in
                for (id, url) in moved { state.update(id) { $0.sourceURL = url } }
            }
        }
        return missing
    }

    private static func render(
        _ missing: [EditClip], in project: VideoEditProject, generation: Int, expected: inout [UUID: Seen]
    ) async {
        for before in missing {
            guard let record = before.webMotion, !Task.isCancelled, project.isCurrentGeneration(generation) else { return }
            do {
                let rendered = try await WebMotionCache.render(record, directory: WebMotionActions.cacheDirectory(for: project))
                let info = try await MediaProbe.probe(url: rendered.file, ffmpeg: nil).get()
                guard !Task.isCancelled, project.isCurrentGeneration(generation),
                      let current = project.state.clip(with: before.id), current.webMotion == before.webMotion,
                      current.sourceURL == before.sourceURL else { continue }
                project.applyDocumentRepair { state in
                    state.update(before.id) { clip in
                        clip.sourceURL = rendered.file
                        clip.webMotion = rendered.record
                        clip.info = info
                    }
                }
                if let clip = project.state.clip(with: before.id) { expected[before.id] = Seen(clip) }
                if project.documentURL != nil { project.saveSoon() }
            } catch {
                guard !Task.isCancelled, project.isCurrentGeneration(generation) else { return }
                project.notice = String(format: L10n("Motion could not be rebuilt: %@"), WebMotionUIError.message(error))
            }
        }
    }
}
