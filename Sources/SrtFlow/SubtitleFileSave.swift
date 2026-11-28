import Foundation
import SrtFlowCore

// MARK: - Writing a subtitle document to a file (the subtitle editor's Save and Export As)
//
// What it does: a subtitle file's bytes, made from the document on the main thread (reindexed, then SubtitleSerializer: the
// serialization the editor always used), and their write on a serial queue, never on the main thread — atomic, and
// replacing a file already at the URL only when allowed (its own file, or confirmed for exactly that URL: NewFileClaim). The
// caller waits at most a deadline; past it the answer is "not responding" and the write goes on. Every write reports its
// real end to the request that asked for it (`landed`), so a late success can still mark that request's document saved.
// What it doesn't: asking the person (FileReplaceQuestion); which document is saved, its unsaved mark and what the person
// is told (SubtitleEditPanel).
//
// Why (2026-11-19): Export As wrote with a plain `Data.write`, replacing a file of the same name unasked
// (docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md), and on the main thread, so a subtitle file on a
// sleeping or stuck drive froze SkyCut (docs/bugfixes/2026-11-19-subtitle-and-version-saves-touch-drives-on-main.md).

enum SubtitleFileSave {
    enum Answer: Equatable {
        case written
        /// A file is already there and replacing it was not allowed: nothing written, that file untouched.
        case occupied
        /// Not written; the system's reason.
        case failed(String)
        /// The drive did not answer within the deadline: the write goes on, and `landed` says how it ended.
        case notResponding
    }

    /// How long a save waits for the drive before it says "not responding" (the project file's deadline; the checks
    /// shorten it).
    nonisolated(unsafe) static var deadline: TimeInterval = 15
    /// The write itself (a seam: the checks pass a drive that is slow or never answers). Runs on the queue.
    nonisolated(unsafe) static var perform: @Sendable (Data, URL, Bool) throws -> NewFileClaim.Outcome = {
        try NewFileClaim.write($0, to: $1, replacing: $2)
    }
    /// One write at a time, in the order asked: two saves of the same file land in order.
    private static let queue = DispatchQueue(label: "SrtFlow.subtitleFile", qos: .userInitiated)
    /// Writes asked for and not landed yet, per file (also after "not responding": the write goes on).
    @MainActor private static var writing: [String: Int] = [:]
    /// Why the last write of each file failed, until a later write of it lands, from whichever saver (review CXM3).
    @MainActor private static var failed: [String: String] = [:]

    /// Why the last write of `url` failed, when no write of it has landed since: told in the next question about it.
    @MainActor
    static func lastFailure(_ url: URL) -> String? { failed[key(url)] }

    /// A write to `url` has not landed yet: nothing may read the file into an editor, or drop what it is writing, before it
    /// does (BurnInSubtitleEdits, review CXM1).
    @MainActor
    static func isWriting(_ url: URL) -> Bool { writing[key(url), default: 0] > 0 }

    /// Waits until no write to `url` is on its way, at most `deadline`. false: one still is.
    @MainActor
    static func waitUntilWritten(_ url: URL, deadline: TimeInterval) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + max(0, deadline)
        while isWriting(url), ProcessInfo.processInfo.systemUptime < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        return !isWriting(url)
    }

    private static func key(_ url: URL) -> String { url.standardized.path }

    /// What the person is told when the drive with `url` did not answer within the deadline.
    @MainActor
    static func notRespondingText(_ url: URL) -> String {
        String(
            format: L10n("The drive with “%@” is not responding. It may be asleep or disconnected, or macOS may be asking for permission."),
            ProjectSaveText.driveName(of: url)
        )
    }

    /// The file's bytes.
    static func data(_ document: SubtitleDocumentModel, format: SubtitleFormat) -> Data {
        var copy = document
        copy.reindex()
        return Data(SubtitleSerializer.serialize(copy, format: format).utf8)
    }

    /// Writes `data` at `url` off the main thread and waits for it at most `deadline` (nil: `SubtitleFileSave.deadline`).
    /// `replacing`: a file already there may be replaced. `landed` gets how the write really ended, on the main actor, once —
    /// also when it ends after this call already answered `.notResponding`.
    @MainActor
    static func write(
        _ data: Data, to url: URL, replacing: Bool, deadline: TimeInterval? = nil,
        landed: @escaping @MainActor (Answer) -> Void = { _ in }
    ) async -> Answer {
        let perform = perform
        let wait = Waiting()
        let seconds = deadline ?? Self.deadline
        let file = key(url)
        writing[file, default: 0] += 1
        return await withCheckedContinuation { continuation in
            wait.continuation = continuation
            queue.async {
                let answer: Answer
                do {
                    answer = try perform(data, url, replacing) == .written ? .written : .occupied
                } catch {
                    answer = .failed(error.localizedDescription)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        writing[file, default: 1] -= 1
                        if writing[file] == 0 { writing[file] = nil }
                        switch answer {
                        case .written: failed[file] = nil
                        case .failed(let reason): failed[file] = reason
                        case .occupied, .notResponding: break
                        }
                        wait.answer(answer)
                        landed(answer)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
                MainActor.assumeIsolated { wait.answer(.notResponding) }
            }
        }
    }

    /// One caller's wait: answered once, by the write's end or the deadline, whichever comes first.
    @MainActor
    private final class Waiting {
        var continuation: CheckedContinuation<Answer, Never>?

        func answer(_ answer: Answer) {
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }
}
