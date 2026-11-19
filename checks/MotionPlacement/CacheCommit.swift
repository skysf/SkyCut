import Foundation
import SrtFlowMCPKit
import SrtFlowWebMotionKit
@testable import SrtFlow

// A cached movie that a clip, its undo history and a Save As may be reading is never lost to a render of the same
// fingerprint. An unchanged Re-render reuses the checked movie. A render that does replace it (here: its receipt is gone)
// installs the new one in a single rename, after its checks: a failed install or a render from another system identity
// keeps the previous movie, and a Save As landing mid-install still carries one
// (docs/bugfixes/2026-11-19-web-motion-rerender-deletes-cached-movie.md).
@MainActor func runMotionCacheCommitChecks(_ root: URL) async throws {
    let fixture = try MotionFixture(root: root.appendingPathComponent("cache-commit"))
    defer { _ = OpenProjects.shared.close(fixture.project) }
    let clip = try await WebMotionActions.place(record: fixture.record, at: 2, project: fixture.project).clip
    let cache = try CachedMotion(clip: clip, directory: WebMotionActions.cacheDirectory(for: fixture.project))
    fixture.resetUndo()
    try await unchangedRerenderReuses(fixture, cache)
    try await failedInstallKeepsMovie(cache)
    try await otherSystemKeepsMovie(fixture.root, cache)
    try await saveAsDuringInstallCarriesMovie(fixture, cache)
}

/// The placed clip's movie, its receipt and the bytes every failure must leave in place.
private struct CachedMotion {
    let clip: EditClip
    let record: WebMotionClipRecord
    let directory: URL
    let movie: URL
    let receipt: URL
    let bytes: Data

    init(clip: EditClip, directory: URL) throws {
        self.clip = clip
        record = clip.webMotion!
        self.directory = directory
        movie = clip.sourceURL
        receipt = movie.deletingPathExtension().appendingPathExtension("render.json")
        bytes = try Data(contentsOf: movie)
    }

    /// A receipt lost (deleted, or its write failed): the next render must render this fingerprint again in place.
    func forgetReceipt() { try? FileManager.default.removeItem(at: receipt) }

    var movieIntact: Bool { (try? Data(contentsOf: movie)) == bytes }

    var stagedLeftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".skycut-web-motion-") }
    }

    func reads(_ url: URL) async -> Bool {
        guard let info = try? await MediaProbe.probe(url: url, ffmpeg: nil).get(), let expected = clip.info else { return false }
        return abs(info.duration - expected.duration) < 0.000001 && info.displaySize == expected.displaySize
    }
}

@MainActor private func unchangedRerenderReuses(_ fixture: MotionFixture, _ cache: CachedMotion) async throws {
    try await withRendererSentinel(root: fixture.root) { marker in
        let editor = WebMotionEditorModel(project: fixture.project, clip: cache.clip)
        let reused = await editor.render()
        motionRequire(reused && editor.error == nil && !FileManager.default.fileExists(atPath: marker.path),
                      "an unchanged Re-render reuses its checked movie without starting the renderer: \(editor.error ?? "ok")")
    }
    motionRequire(fixture.project.state.clip(with: cache.clip.id)?.sourceURL == cache.movie && cache.movieIntact,
                  "…and the clip keeps the same movie, byte for byte")
}

@MainActor private func failedInstallKeepsMovie(_ cache: CachedMotion) async throws {
    cache.forgetReceipt()
    WebMotionCacheFiles.beforeInstallForChecks = { _ in throw CocoaError(.fileWriteOutOfSpace) }
    defer { WebMotionCacheFiles.beforeInstallForChecks = nil }
    do {
        _ = try await WebMotionCache.render(cache.record, directory: cache.directory)
        motionRequire(false, "a render whose install fails must fail")
    } catch {
        motionRequire(WebMotionUIError.message(error).contains("could not be moved into place"),
                      "the failed install is reported: \(WebMotionUIError.message(error))")
    }
    let reads = await cache.reads(cache.movie)
    motionRequire(cache.movieIntact, "a failed install keeps the movie the clip and its undo history use, byte for byte")
    motionRequire(reads, "…and that movie still reads as the motion")
    motionRequire(cache.stagedLeftovers.isEmpty, "the staged movie of a failed install is removed: \(cache.stagedLeftovers)")
}

/// A helper that passes every check but reports another system identity (and stages a movie that is not one).
@MainActor private func otherSystemKeepsMovie(_ root: URL, _ cache: CachedMotion) async throws {
    let folder = root.appendingPathComponent("other-system-helper")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = WebMotionResult(
        accepted: true, checks: WebMotionCheckName.allCases.map { WebMotionCheck(name: $0, passed: true, detail: "Passed.") },
        failure: nil, pageErrors: [], frameCount: 12, frameHashes: [], blankFrames: [], alpha: nil,
        versions: WebMotionVersions(renderer: 0, macOS: "0.0.0", macOSBuild: "other", webKit: "other"),
        timing: WebMotionTiming(), webKitProcesses: [])
    let line = folder.appendingPathComponent("result.jsonl")
    try WebMotionEvent(kind: .result, result: result).line().write(to: line)
    let helper = folder.appendingPathComponent("helper")
    try Data("""
    #!/bin/sh
    out="$(/usr/bin/plutil -extract outputPath raw -o - -)"
    /bin/echo "not a movie" > "$out"
    /bin/cat '\(line.path)'

    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let previous = ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_HELPER"]
    setenv("SRTFLOW_WEB_MOTION_HELPER", helper.path, 1)
    defer {
        if let previous { setenv("SRTFLOW_WEB_MOTION_HELPER", previous, 1) } else { unsetenv("SRTFLOW_WEB_MOTION_HELPER") }
    }
    cache.forgetReceipt()
    do {
        _ = try await WebMotionCache.render(cache.record, directory: cache.directory)
        motionRequire(false, "a render from another system identity must fail")
    } catch {
        motionRequire(WebMotionUIError.message(error).contains("system identity changed"),
                      "the other system identity is reported: \(WebMotionUIError.message(error))")
    }
    motionRequire(cache.movieIntact && !FileManager.default.fileExists(atPath: cache.receipt.path),
                  "a render that fails its own checks after the helper replaces neither the movie nor the receipt")
    motionRequire(cache.stagedLeftovers.isEmpty, "…and leaves no staged file: \(cache.stagedLeftovers)")
}

/// Save As carries movies on the project's writer queue; here it lands at the worst moment, right before the install.
@MainActor private func saveAsDuringInstallCarriesMovie(_ fixture: MotionFixture, _ cache: CachedMotion) async throws {
    let copy = fixture.root.appendingPathComponent("save-as-during-install/Copy.skycut")
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let state = fixture.project.state
    WebMotionCacheFiles.beforeInstallForChecks = { _ in _ = try VideoEditProjectIO.save(state, to: copy) }
    defer { WebMotionCacheFiles.beforeInstallForChecks = nil }
    cache.forgetReceipt()
    let rendered = try await WebMotionCache.render(cache.record, directory: cache.directory)
    motionRequire(!rendered.cacheHit && rendered.file == cache.movie && FileManager.default.fileExists(atPath: cache.receipt.path),
                  "a movie without its receipt is rendered again in place, and its receipt written")
    let carried = WebMotionProjectFiles.directory(for: copy).appendingPathComponent(cache.movie.lastPathComponent)
    let saved = try VideoEditProjectIO.load(from: copy)
    motionRequire(saved.timeline.clip(with: cache.clip.id)?.sourceURL.standardizedFileURL == carried.standardizedFileURL
                    && saved.motionsToRegenerate.isEmpty,
                  "a Save As landing mid-install carries the movie beside the copy")
    let clipReads = await cache.reads(cache.movie), copyReads = await cache.reads(carried)
    motionRequire(clipReads && copyReads, "the clip's movie and the copy's carried movie both read as the motion")
    motionRequire(cache.stagedLeftovers.isEmpty, "an installed movie leaves no staged file: \(cache.stagedLeftovers)")
}
