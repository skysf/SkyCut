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
