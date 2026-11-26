import CryptoKit
import Foundation

// MARK: - Fetching the feed and downloading the DMG
//
// What it does: two plain GETs from a session that keeps nothing (no cookies, cache or credentials) and carries nothing
// about the person: no account, key, machine id or other identifier, only a generic User-Agent. No redirects are
// followed (the feed and the DMG are served directly; anything else is a failure). The feed is at most 64 KB; the DMG
// never more bytes than the feed says, then its size and SHA-256 are checked before anything opens it. Every failure is a
// thrown error or nil, which the updater keeps to itself; a DMG that came down but isn't the feed's (more bytes, another
// size, another SHA-256) throws AppUpdateDMGMismatch, which the retry record counts (AppUpdatePipeline). The hashing
// blocks a thread: it runs on AppUpdateWork.queue.
// What it doesn't: parse (AppUpdateFeed), decide when (AppUpdater), open the image (AppUpdateStager).
// Rules: docs/architecture/app-updates.md "Checking" and "Downloading".

enum AppUpdateWork {
    /// hdiutil, copying an app, hashing and code-signature checks block a thread: never on the Swift concurrency pool
    /// (docs/architecture/blocking-media-reads.md). One at a time, in the background.
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SrtFlow.AppUpdate"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await MediaReadQueue.run(on: queue, work)
    }
}

struct AppUpdateError: LocalizedError, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

/// The download came down, but it isn't the feed's DMG: more bytes than the feed says, another size or another SHA-256.
/// Unlike a download that didn't complete, it says something about the DMG: the retry record counts it.
struct AppUpdateDMGMismatch: LocalizedError, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

enum AppUpdateHTTP {
    static func session(requestTimeout: TimeInterval, resourceTimeout: TimeInterval,
                        delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "SkyCut", "Cache-Control": "no-cache"]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// One check: the feed fetched and parsed strictly; offered only if newer than `running` and fit for this macOS.
    static func check(_ source: AppUpdateFeed.Source, running: AppUpdateVersion) async -> AppUpdateCheckResult {
        guard let data = await fetchFeed(source.feedURL), let feed = AppUpdateFeed.parse(data, from: source) else { return .failed }
        return feed.isOffered(to: running, on: ProcessInfo.processInfo.operatingSystemVersion) ? .offer(feed) : .upToDate
    }

    /// The feed's bytes: HTTP 200, no redirect, at most AppUpdateFeed.maxFeedBytes. nil for anything else (offline too).
    static func fetchFeed(_ url: URL) async -> Data? {
        let session = session(requestTimeout: 30, resourceTimeout: 60)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url, delegate: AppUpdateNoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= AppUpdateFeed.maxFeedBytes else { return nil }
        return data
    }

    /// Downloads the feed's DMG to `destination` (replacing what is there): HTTP 200, no redirect, never more than the feed's
    /// size; then the size and the SHA-256 are checked. Throws otherwise, leaving no file: AppUpdateDMGMismatch when it came
    /// down but isn't the feed's DMG. Cancelling the task stops it.
    static func download(_ feed: AppUpdateFeed, to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let transfer = AppUpdateDownload(destination: destination, expectedBytes: feed.dmgSize, progress: progress)
        let session = session(requestTimeout: 60, resourceTimeout: 3600, delegate: transfer)
        defer { session.finishTasksAndInvalidate() }
        do {
            try Task.checkCancellation()
            try await transfer.run(session.downloadTask(with: feed.dmgURL))
            try Task.checkCancellation()
            let size = await AppUpdateWork.run { () -> Int64? in
                (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            }
            guard size == feed.dmgSize else { throw AppUpdateDMGMismatch("size \(size ?? -1), the feed says \(feed.dmgSize)") }
            let digest = await AppUpdateWork.run { AppUpdateDigest.sha256(of: destination) }
            guard digest == feed.dmgSHA256 else {
                throw AppUpdateDMGMismatch("SHA-256 \(digest ?? "unreadable"), the feed says \(feed.dmgSHA256)")
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

enum AppUpdateDigest {
    /// Lowercase hex SHA-256 of a file, read 1 MB at a time; nil if it can't be read. Blocking.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Refuses every redirect: the response is then the redirect itself, not a 200, and the request fails.
final class AppUpdateNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One DMG download with progress: the file is moved out of URLSession's temporary place before its callback returns.
final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var placed: Result<Void, Error>?
    private var task: URLSessionDownloadTask?
    /// The server sent more bytes than the feed says: stopped, and reported as a mismatch (not a lost connection).
    private var oversized = false

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func run(_ task: URLSessionDownloadTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    self.continuation = continuation
                    self.task = task
                }
                task.resume()
                // Cancelled before the task was known to the handler: stop it now.
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            lock.withLock { self.task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes else {
            lock.withLock { oversized = true }
            return downloadTask.cancel()
        }
        progress(Double(totalBytesWritten) / Double(max(expectedBytes, 1)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let result: Result<Void, Error>
        if status != 200 {
            result = .failure(AppUpdateError("HTTP \(status)"))
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        lock.withLock { placed = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, placed, oversized) = lock.withLock {
            () -> (CheckedContinuation<Void, Error>?, Result<Void, Error>?, Bool) in
            defer { self.continuation = nil }
            return (self.continuation, self.placed, self.oversized)
        }
        if oversized {
            return continuation?.resume(throwing: AppUpdateDMGMismatch("more bytes than the feed says (\(expectedBytes))")) ?? ()
        }
        if let error { return continuation?.resume(throwing: error) ?? () }
        continuation?.resume(with: placed ?? .failure(AppUpdateError("no file")))
    }
}
