import Foundation
import SrtFlowCore

// MARK: - The export panel's "Export Subtitle Files": one decision per file
//
// What it does: the work behind the button and its replace question, apart from the view (SubtitleFilesExport). Pressing
// the button checks the destination before writing (ExportDestinationState.checkBeforeWriting), takes the files in the
// folder that was checked, and asks about the ones that check found there. Replace replaces exactly the files the
// question named; every other file is written as a new file (SubtitleExportPlanner.writeNew), so a file the question did
// not list — one that appeared after the check, or while the question was open — is never replaced: it is left as it was
// and said (pressing the button again asks about it). The writes run off the main thread.
// What it doesn't: which files and their names (the view: SubtitleExportPlanner.fileName, SubtitleFileLanguage); the
// question's wording and the checkboxes (SubtitleFilesExport); the destination's check (ExportDestinationState).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-subtitle-export-replaces-unlisted-file.md): once the question was answered,
// every file was written with the replacing write, also files the question never listed. Rules:
// docs/architecture/export-settings.md §5 item 7.

@MainActor
final class SubtitleFilesWrite: ObservableObject {
    /// One file to write.
    struct File: Sendable {
        var document: SubtitleDocumentModel
        var format: SubtitleFormat
        var url: URL
    }

    @Published private(set) var isWriting = false
    /// What the last write wrote.
    @Published private(set) var written: [URL] = []
    @Published private(set) var error: String?
    /// The files the replace question names: the ones the check before writing found in the folder.
    @Published private(set) var question: [URL] = []
    /// The replace question is up (the view's alert).
    @Published var asksToReplace = false

    /// The files of the press the question is about, in the folder that was checked.
    private var pending: [File] = []
    private var destination: ExportDestinationState?

    /// The button: the check before writing, then the files in the folder it checked (`files(folder)`); a question when
    /// some are there, otherwise the write.
    func request(destination: ExportDestinationState, files: (URL) -> [File]) async {
        guard !isWriting else { return }
        isWriting = true
        error = nil
        self.destination = destination
        let checked = await destination.checkBeforeWriting()
        if let problem = checked.report.problem {
            isWriting = false
            error = ExportDestinationText.message(problem, folder: checked.folder)
            return
        }
        pending = files(checked.folder)
        question = pending.map(\.url).filter { checked.report.contains($0.lastPathComponent) }
        if question.isEmpty {
            await write(replacing: [])
        } else {
            isWriting = false
            asksToReplace = true
        }
    }

    /// Replace in the question: exactly the files it named are replaced; the others are written as new files.
    func replace() async {
        await write(replacing: Set(question))
    }

    private func write(replacing: Set<URL>) async {
        isWriting = true
        error = nil
        let files = pending
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.write(files, replacing: replacing))
            }
        }
        written = outcome.written
        error = outcome.error
        isWriting = false
        await destination?.refresh()  // the folder now has these names
    }

    struct Outcome: Sendable {
        var written: [URL]
        var error: String?
    }

    /// Each file replaced only when `replacing` names it, otherwise written as a new file; a file taken meanwhile is left as
    /// it was and said in the system's words. Stops at the first failure (what was written is still reported). Off the main
    /// thread.
    nonisolated static func write(_ files: [File], replacing: Set<URL>) -> Outcome {
        var written: [URL] = []
        var kept: [URL] = []
        do {
            for file in files {
                if replacing.contains(file.url) {
                    try SubtitleExportPlanner.writeValidated(file.document, format: file.format, to: file.url)
                } else if try !SubtitleExportPlanner.writeNew(file.document, format: file.format, to: file.url) {
                    kept.append(file.url)
                    continue
                }
                written.append(file.url)
            }
        } catch {
            return Outcome(written: written, error: error.localizedDescription)
        }
        let notes = kept.map { CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: $0.path]).localizedDescription }
        return Outcome(written: written, error: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
}
