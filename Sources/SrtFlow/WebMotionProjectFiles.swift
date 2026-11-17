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
    @discardableResult
    static func refreshWebMotionCaches(in timeline: inout TimelineState, projectURL: URL) -> [UUID] {
        let manager = FileManager.default
        var missing: [UUID] = []
        for clip in timeline.allClips {
            guard let record = clip.webMotion else { continue }
            if let carried = movieURL(for: record, projectURL: projectURL), manager.fileExists(atPath: carried.path) {
                if clip.sourceURL != carried { timeline.update(clip.id) { $0.sourceURL = carried } }
            } else if !manager.fileExists(atPath: clip.sourceURL.path) {
                if let destination = movieURL(for: record, projectURL: projectURL) {
                    timeline.update(clip.id) { $0.sourceURL = destination }
                }
                missing.append(clip.id)
            }
        }
        return missing
    }
}
