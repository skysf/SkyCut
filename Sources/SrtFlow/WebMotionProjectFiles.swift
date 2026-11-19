import Foundation

// Project-relative files for generated motion, separate from imported media and bookmark resolution.
// A carried render is reused on another Mac; only a missing cache is queued here. Rendering belongs to the service.
enum WebMotionProjectFiles {
    static func directory(for projectURL: URL) -> URL {
        projectURL.deletingLastPathComponent().appendingPathComponent("SkyCut/Motion", isDirectory: true)
    }

    /// The fingerprint is a SHA-256 digest, never an arbitrary path supplied by a stored page.
    static func filename(for record: WebMotionClipRecord) -> String? {
        guard let fingerprint = record.provenance?.fingerprint,
              fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return "motion-\(fingerprint).mov"
    }

    static func movieURL(for record: WebMotionClipRecord, projectURL: URL) -> URL? {
        filename(for: record).map { directory(for: projectURL).appendingPathComponent($0) }
    }

    /// Version equality compares source content, not where a disposable movie currently lives. This value is comparison
    /// only: the real project and version files keep their usable URLs, and ordinary imported media stays exact.
    static func normalizingCacheLocations(in original: TimelineState) -> TimelineState {
        var result = original
        for clip in original.allClips {
            guard let record = clip.webMotion else { continue }
            let name = filename(for: record) ?? "unrendered-\(clip.id.uuidString.lowercased()).mov"
            let sentinel = URL(string: "srtflow-motion-cache:///\(name)")!
            result.update(clip.id) { $0.sourceURL = sentinel }
        }
        return result
    }

    /// Save As carries movies into the new project folder before the JSON is committed. A cache causes a save failure only
    /// when it existed but could not be carried; a missing movie never prevents saving its recoverable source page.
    static func preparingForSave(_ original: TimelineState, projectURL: URL) throws -> TimelineState {
        let manager = FileManager.default
        var timeline = original
        for clip in original.allClips {
            guard let record = clip.webMotion, let destination = movieURL(for: record, projectURL: projectURL) else { continue }
            if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: clip.sourceURL.path) {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".motion-save-\(UUID().uuidString).mov")
                defer { try? manager.removeItem(at: temporary) }
                try manager.copyItem(at: clip.sourceURL, to: temporary)
                // Another save of the same immutable fingerprint may have finished while this copy was in progress.
                if !manager.fileExists(atPath: destination.path) { try manager.moveItem(at: temporary, to: destination) }
            }
            timeline.update(clip.id) { $0.sourceURL = destination }
        }
        return timeline
    }

    /// The project-relative carried movie takes precedence over an absolute path from the original Mac. Existing movies
    /// remain valid across OS/font changes; the rendering service reports provenance differences without replacing them.
    /// Asks the drive on the caller's thread: the project load runs off the main thread; recovery asks `cache` on the cache
    /// folder's queue instead (WebMotionRecovery).
    @discardableResult
    static func refreshWebMotionCaches(in timeline: inout TimelineState, projectURL: URL) -> [UUID] {
        var missing: [UUID] = []
        for clip in timeline.allClips {
            guard let found = cache(for: clip, projectURL: projectURL, exists: onDrive) else { continue }
            if found.sourceURL != clip.sourceURL { timeline.update(clip.id) { $0.sourceURL = found.sourceURL } }
            if found.missing { missing.append(clip.id) }
        }
        return missing
    }

    /// Where a web-motion clip's movie is: the carried movie beside the project when it is there, else the stored file; a
    /// missing movie points where it belongs beside the project (where recovery renders it).
    struct Cache: Equatable, Sendable {
        var sourceURL: URL
        var missing: Bool
    }

    /// Whether a movie is on the drive: asked on the caller's thread, so never call it on the main thread.
    static let onDrive: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// The rule of `refreshWebMotionCaches` for one clip; `exists` asks the drive, on whatever thread the caller chose. nil for
    /// a clip without web motion.
    static func cache(for clip: EditClip, projectURL: URL?, exists: (URL) -> Bool) -> Cache? {
        guard let record = clip.webMotion else { return nil }
        let carried = projectURL.flatMap { movieURL(for: record, projectURL: $0) }
        if let carried, exists(carried) { return Cache(sourceURL: carried, missing: false) }
        if exists(clip.sourceURL) { return Cache(sourceURL: clip.sourceURL, missing: false) }
        return Cache(sourceURL: carried ?? clip.sourceURL, missing: true)
    }
}
