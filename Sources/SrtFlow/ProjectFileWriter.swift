import Foundation

// MARK: - Writing one project's file off the main thread
//
// What it does: the only place a project's own file is written (`VideoEditProjectIO.save`, the moved-file bookmark, the
// document bookmark). The write runs on this project's serial queue, never on the main thread; one write at a time, and
// the newest snapshot of the same file replaces one still waiting (a stuck drive never piles up writes). A caller waits
// at most a deadline: past it the answer is "still writing" and the write goes on; whenever a write really ends, the
// project is told (`landed`), so a late success still marks it saved and a late failure is still said.
// Also holds the autosave debounce and the project's change counter (a write taken before a change can't mark the
// project saved).
// What it doesn't: when to save, what is dirty, what the user is told (VideoEditProjectSaving.swift); quitting
// (ProjectQuit); saved versions (ProjectVersionStore writes its own files).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md): autosave, ⌘S, switching projects and
// Quit wrote the project file on the main thread; a project on a sleeping, slow or stuck external drive froze SkyCut
// for as long as the drive took, and Quit could hang for good. Rules: docs/architecture/video-edit-project-file.md
// "Writing the project file off the main thread".

/// One write of a project's file, taken on the main thread.
struct ProjectFileWriteRequest: Sendable {
    enum Kind: Sendable {
        /// The project's own file (autosave, ⌘S, closing): follows a file renamed or moved in Finder.
        case save
        /// A new file (Save As, the AI's new / save_project): written exactly there; the project takes it on success.
        case saveAs
    }

    var kind: Kind
    var state: TimelineState
    var url: URL
    var knownRecords: [String: MediaRecord]
    var rowHeights: TimelineRowHeights
    /// The project file's own bookmark (follows a renamed / moved file); nil for Save As.
    var documentBookmark: Data?
    /// The project's change counter when this was taken (`ProjectFileWriter.revision`).
    var revision: Int
    /// The project's document generation when this was taken: a result for an older document is not applied.
    var generation: Int
    /// Stamped by the writer: a result older than one already applied is dropped.
    fileprivate(set) var sequence = 0
}

/// What a write ended with.
enum ProjectFileWriteResult: Sendable {
    /// Written to `url` (the moved file's new place when it had been moved); `records` is the media table written;
    /// `bookmark` is a fresh bookmark of the file just written.
    case saved(url: URL, records: [String: MediaRecord], bookmark: Data?)
    /// Not written; the system's reason. The file on disk is untouched (atomic write).
    case failed(String)
}

@MainActor
final class ProjectFileWriter {
    /// How long a save waits for the drive before it says "not responding": the export panel's deadline for a check that
    /// writes (an asleep USB hard drive can take this long to spin up, ExportDestinationState). The checks shorten it.
    nonisolated(unsafe) static var deadline: TimeInterval = 15

    /// Bumped by every change to what the project's file holds (`VideoEditProject.noteUnsavedChange`).
    private(set) var revision = 0
    /// The debounced autosave (VideoEditProject.scheduleAutosave).
    var autosaveTask: Task<Void, Never>?
    /// The "not responding" notice this project is showing, cleared when a write lands.
    var stuckNotice: String?
    /// Every write's real end, on the main actor, before anyone waiting for it is resumed (the project applies it).
    var landed: ((ProjectFileWriteRequest, ProjectFileWriteResult) -> Void)?
    /// The write itself (a seam: the checks pass a drive that is slow or never answers). Runs off the main thread.
    var perform: @Sendable (ProjectFileWriteRequest) -> ProjectFileWriteResult = ProjectFileWriter.write

    private let queue: DispatchQueue
    /// The write on the queue now (it may be stuck on the drive), then the ones waiting, oldest first.
    private var running: Ticket?
    private var waiting: [Ticket] = []
    private var stamped = 0
    private var lastLanded = 0

    init(label: String = "project") {
        queue = DispatchQueue(label: "SrtFlow.projectFile.\(label)", qos: .userInitiated)
    }

    /// A write is running or waiting.
    var isBusy: Bool { running != nil || !waiting.isEmpty }

    func noteChange() { revision &+= 1 }

    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Queues `request` and waits for it at most `deadline` (nil: until it ends). nil = still writing.
    func write(_ request: ProjectFileWriteRequest, deadline: TimeInterval?) async -> ProjectFileWriteResult? {
        let ticket = enqueue(request)
        return await wait(for: ticket, deadline: deadline)
    }

    /// Waits until nothing is running or waiting, at most `deadline` (nil: no limit). false = still busy.
    func waitUntilIdle(deadline: TimeInterval?) async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        while let last = waiting.last ?? running {
            let left = deadline.map { $0 - (ProcessInfo.processInfo.systemUptime - started) }
            if let left, left <= 0 { return false }
            guard await wait(for: last, deadline: left) != nil else { return false }
        }
        return true
    }

    /// Checks and dev hooks only (the blocking saves, VideoEditProjectSaving.swift): the same write on the caller's
    /// thread, after the one on the queue. Production code never calls it (checks/project-file-wiring.sh).
    func writeBlocking(_ request: ProjectFileWriteRequest) -> ProjectFileWriteResult {
        let request = stamp(request)
        let perform = perform
        let result = queue.sync { perform(request) }
        deliver(request, result)
        // Waiting snapshots of the same file are older than this one: they are written now as far as their callers care.
        for ticket in waiting where ticket.request.url == request.url { ticket.resolve(result) }
        waiting.removeAll { $0.request.url == request.url }
        return result
    }

    // MARK: - The queue

    private func enqueue(_ request: ProjectFileWriteRequest) -> Ticket {
        let request = stamp(request)
        if let last = waiting.last, last.request.url == request.url, last.request.kind == request.kind {
            last.request = request  // newest snapshot wins; its callers get this write's result
            return last
        }
        let ticket = Ticket(request)
        waiting.append(ticket)
        startNext()
        return ticket
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let ticket = waiting.removeFirst()
        running = ticket
        let request = ticket.request
        let perform = perform
        queue.async { [weak self] in
            let result = perform(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(ticket, result) }
            }
        }
    }

    private func finish(_ ticket: Ticket, _ result: ProjectFileWriteResult) {
        running = nil
        deliver(ticket.request, result)
        ticket.resolve(result)
        startNext()
    }

    private func stamp(_ request: ProjectFileWriteRequest) -> ProjectFileWriteRequest {
        stamped += 1
        var request = request
        request.sequence = stamped
        return request
    }

    /// Tells the project, unless a newer write already landed (a blocking write can overtake the one on the queue).
    private func deliver(_ request: ProjectFileWriteRequest, _ result: ProjectFileWriteResult) {
        guard request.sequence > lastLanded else { return }
        lastLanded = request.sequence
        landed?(request, result)
    }

    private func wait(for ticket: Ticket, deadline: TimeInterval?) async -> ProjectFileWriteResult? {
        if let result = ticket.result { return result }
        return await withCheckedContinuation { continuation in
            let id = ticket.add(continuation)
            guard let deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline)) {
                MainActor.assumeIsolated { ticket.expire(id) }
            }
        }
    }

    /// One queued write and everyone waiting for it.
    @MainActor
    private final class Ticket {
        var request: ProjectFileWriteRequest
        private(set) var result: ProjectFileWriteResult?
        private var waiters: [UUID: CheckedContinuation<ProjectFileWriteResult?, Never>] = [:]

        init(_ request: ProjectFileWriteRequest) {
            self.request = request
        }

        func add(_ continuation: CheckedContinuation<ProjectFileWriteResult?, Never>) -> UUID {
            let id = UUID()
            waiters[id] = continuation
            return id
        }

        /// The write ended: everyone still waiting gets its result.
        func resolve(_ result: ProjectFileWriteResult) {
            self.result = result
            let pending = waiters.values
            waiters = [:]
            for continuation in pending { continuation.resume(returning: result) }
        }

        /// One caller's deadline passed: it gets nil (still writing); the write goes on.
        func expire(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(returning: nil)
        }
    }

    // MARK: - The write (off the main thread)

    /// The project file written with the project file writer (`VideoEditProjectIO.save`: carried web-motion movies,
    /// media bookmarks, atomic JSON). A file renamed or moved in Finder is followed by its bookmark, so the save does not
    /// make a new file under the old name.
    nonisolated static func write(_ request: ProjectFileWriteRequest) -> ProjectFileWriteResult {
        var url = request.url
        if request.kind == .save, !FileManager.default.fileExists(atPath: url.path),
           let moved = movedFile(request.documentBookmark) {
            url = moved
        }
        do {
            let records = try VideoEditProjectIO.save(
                request.state, to: url, knownRecords: request.knownRecords, rowHeights: request.rowHeights
            )
            // A fresh bookmark after every write: the atomic write gives the file a new inode, and a bookmark made before it
            // can't find the file once it is moved in Finder (2026-11-19: it used to be made once, at the first save).
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return .saved(url: url, records: records, bookmark: bookmark)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 工程文件被改名/移动后的新位置（同一个盘）。
    nonisolated private static func movedFile(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale
        ), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }
}
