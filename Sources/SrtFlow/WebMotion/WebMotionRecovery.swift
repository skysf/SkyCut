import Foundation

// Restores missing generated movies without imported-media relinking or undo entries. Called on open and runtime revalidation.
@MainActor
enum WebMotionRecovery {
    static func start(for project: VideoEditProject) {
        let generation = project.documentGeneration
        guard project.state.allClips.contains(where: { $0.webMotion != nil }) else { return }
        let key = "recovery:\(generation)"
        guard WebMotionActivity.claim(key) else { return }
        if let url = project.documentURL {
            var repaired = project.state
            WebMotionProjectFiles.refreshWebMotionCaches(in: &repaired, projectURL: url)
            if repaired != project.state { project.applyDocumentRepair { $0 = repaired } }
        }
        let missing = project.state.allClips.filter { $0.webMotion != nil && !FileManager.default.fileExists(atPath: $0.sourceURL.path) }
        guard !missing.isEmpty else { WebMotionActivity.release(key); return }
        project.trackImportTask(Task { [weak project] in
            guard let project, !Task.isCancelled, project.isCurrentGeneration(generation) else {
                WebMotionActivity.release(key)
                return
            }
            defer {
                WebMotionActivity.release(key)
                if !Task.isCancelled, project.isCurrentGeneration(generation), project.state.allClips.contains(where: { clip in
                    clip.webMotion != nil && !FileManager.default.fileExists(atPath: clip.sourceURL.path)
                        && !missing.contains(where: { $0.id == clip.id && $0.webMotion == clip.webMotion })
                }) { start(for: project) }
            }
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
                    if project.documentURL != nil { project.saveNow() }
                } catch {
                    guard !Task.isCancelled, project.isCurrentGeneration(generation) else { return }
                    project.notice = String(format: L10n("Motion could not be rebuilt: %@"), String(describing: error))
                }
            }
        })
    }

}
