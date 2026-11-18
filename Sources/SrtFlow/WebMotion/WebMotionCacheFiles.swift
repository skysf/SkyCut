import Darwin
import Foundation

// MARK: - The web-motion cache folder's files, on a queue of their own
//
// Owns: the queue every file operation in a motion cache folder runs on (`SkyCut/Motion` beside the project, or a temporary
// folder for an untitled one), and how a passed render takes its place there: one atomic rename(2) over the old file,
// never "remove, then move". A reader — a clip, its undo history, a Save As carrying the movie on the project's writer
// queue — sees the old movie or the new one, never none, and a failed install leaves the old one where it was.
// Does not own: what is rendered or when (WebMotionCache, WebMotionRenderer), where projects carry movies
// (WebMotionProjectFiles).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-web-motion-rerender-deletes-cached-movie.md): a same-fingerprint re-render
// removed the cached movie and then moved the new one in; when the move failed (a full, slow or unplugged drive) the movie
// the clip and its undo history used was gone, and a Save As between the two steps carried nothing.
// docs/architecture/web-motion-renderer.md §15.

enum WebMotionCacheFiles {
    /// For the checks only: runs on the queue right before a passed movie is renamed over `destination`. Throwing makes that
    /// install fail as a full or unplugged drive would; a Save As run here lands between the render and the install.
    nonisolated(unsafe) static var beforeInstallForChecks: (@Sendable (URL) throws -> Void)?

    /// One operation at a time: the folder may be on a slow or stuck drive (docs/architecture/blocking-media-reads.md
    /// "Destination drives"), so never the main thread or Swift's cooperative pool.
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SrtFlow.webMotionCache"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Moves `staged` (written beside `destination`, so on the same volume) over `destination` in one rename(2).
    /// Runs on `queue`.
    static func install(_ staged: URL, at destination: URL) throws {
        try beforeInstallForChecks?(destination)
        guard rename(staged.path, destination.path) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
    }
}
