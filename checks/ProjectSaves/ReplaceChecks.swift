import Foundation
import SrtFlowCore
@testable import SrtFlow

// Saving to a place the person chose never replaces a file there unless the person confirmed it for exactly that URL
// (docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md). A file with known bytes (the sentinel) sits under the
// name each answer leads to: a folder dropped on the file-window helper, a folder typed with "/", a full path typed —
// answers the helper gives without macOS ever asking "Replace?" — keep the sentinel's bytes unless the person answers
// Replace here; an answer from macOS's own window (it asked) replaces without a second question; closing an untitled
// project, the AI's own saves and the subtitle editor's Export As write the same way.
@MainActor enum ReplaceChecks {
    static func run(_ checks: Checks, root: URL) async {
        let folder = root.appendingPathComponent("Replace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let question = FileReplaceQuestion.ask
        await helperAnswers(checks, folder: folder)
        await confirmed(checks, folder: folder)
        await closingUntitled(checks, folder: folder)
        await aiSaves(checks, folder: folder)
        await subtitles(checks, folder: folder)
        FileReplaceQuestion.ask = question
    }

    private static let sentinel = Data("the file that was already there".utf8)

    private static func plant(_ url: URL) {
        try? sentinel.write(to: url)
    }

    private static func untouched(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)) == sentinel
    }

    /// The helper's three answers, decided the way it decides them (TypedPath), on a project's Save As.
    private static func helperAnswers(_ checks: Checks, folder: URL) async {
        let project = makeProject("Replace source", in: folder)
        let own = project.documentURL
        let taken = folder.appendingPathComponent("Taken.skycut")
        let request = FileWindowRequest(kind: .save(types: [.srtFlowProject], name: taken.lastPathComponent), start: folder)
        let answers = [("dropped folder", TypedPath.accepted([folder], for: request).first),
                       ("typed folder", TypedPath.answer(folder.path + "/", for: request)),
                       ("typed path", TypedPath.answer(taken.path, for: request))]
        for (label, answer) in answers {
            plant(taken)
            var asked: [URL] = []
            FileReplaceQuestion.ask = { asked.append($0); return false }
            let saved = await project.saveAs(chosen: SaveLocation(url: answer ?? taken, mayReplace: false))
            checks.require(answer?.path == taken.path && !saved && asked.map(\.path) == [taken.path] && untouched(taken)
                           && project.documentURL == own,
                           "a \(label) in the helper asks before replacing; Cancel keeps the old file's bytes and the project where it was")
        }
        plant(taken)
        edit(project, "replacing the old file")
        FileReplaceQuestion.ask = { _ in true }
        let replaced = await project.saveAs(chosen: SaveLocation(url: taken, mayReplace: false))
        checks.require(replaced && fileHolds(taken, "replacing the old file") && project.documentURL == taken,
                       "answering Replace writes the project there and takes that file")
        _ = OpenProjects.shared.close(project)
    }

    /// macOS's own window asked about replacing: its answer replaces without a second question.
    private static func confirmed(_ checks: Checks, folder: URL) async {
        let project = makeProject("Confirmed in the window", in: folder)
        let taken = folder.appendingPathComponent("Confirmed.skycut")
        plant(taken)
        var asked = 0
        FileReplaceQuestion.ask = { _ in asked += 1; return false }
        let saved = await project.saveAs(chosen: SaveLocation(url: taken, mayReplace: true))
        checks.require(saved && asked == 0 && !untouched(taken) && project.documentURL == taken,
                       "an answer macOS's own window confirmed replaces the file without asking again (asked \(asked))")
        _ = OpenProjects.shared.close(project)
    }

    /// Closing an untitled project → Save… → a typed answer naming a file that is there → Cancel: nothing replaced, nothing
    /// closed.
    private static func closingUntitled(_ checks: Checks, folder: URL) async {
        let project = makeProject("Untitled with a taken name", in: folder)
        await project.startNewProject()
        edit(project, "unsaved work")
        let taken = folder.appendingPathComponent("Closing.skycut")
        plant(taken)
        let untitled = ProjectCloseQuestions.untitled
        let saveLocation = ProjectCloseQuestions.saveLocation
        ProjectCloseQuestions.untitled = { _ in .save }
        ProjectCloseQuestions.saveLocation = { _ in SaveLocation(url: taken, mayReplace: false) }
        FileReplaceQuestion.ask = { _ in false }
        let closing = await project.prepareToClose()
        checks.require(closing == .refused && untouched(taken) && project.isUntitled && !project.state.isEmpty,
                       "closing an untitled project with a typed name that is taken, then Cancel: old file kept, project kept (\(closing))")
        ProjectCloseQuestions.untitled = untitled
        ProjectCloseQuestions.saveLocation = saveLocation
        ProjectCloseQuestions.untitled = { _ in .discard }
        _ = OpenProjects.shared.close(project)
        ProjectCloseQuestions.untitled = untitled
    }

    /// The AI's saves pick names nobody uses; a file that appears under the name meanwhile is not replaced, and nobody is
    /// asked (an AI tool never shows an alert). Saving back to the project's own file still replaces it.
    private static func aiSaves(_ checks: Checks, folder: URL) async {
        let project = makeProject("AI saves", in: folder)
        let taken = folder.appendingPathComponent("Appeared meanwhile.skycut")
        plant(taken)
        var asked = 0
        FileReplaceQuestion.ask = { _ in asked += 1; return true }
        let saved = await project.saveAs(taken, replacing: false)
        checks.require(!saved && asked == 0 && untouched(taken) && project.notice != nil,
                       "a Save As that may not replace leaves a file that is there, asks nobody, and says why (\(project.notice ?? "nil"))")
        edit(project, "saved back")
        let own = project.documentURL
        let back = await project.saveAs(own ?? taken, replacing: true)
        checks.require(back && fileHolds(own, "saved back"), "saving the project back to its own file replaces it")
        _ = OpenProjects.shared.close(project)
    }

    /// The subtitle editor's Export As writes through SubtitleFileSave: a file there is replaced only when confirmed.
    private static func subtitles(_ checks: Checks, folder: URL) async {
        let data = SubtitleFileSave.data(SubtitleDocumentModel(cues: [SubtitleCue(start: 1, end: 2, text: "Hello there")]), format: .srt)
        let taken = folder.appendingPathComponent("Taken.srt")
        plant(taken)
        let refused = await SubtitleFileSave.write(data, to: taken, replacing: false)
        checks.require(refused == .occupied && untouched(taken), "Export As to a subtitle file nobody agreed to replace keeps its bytes")
        let replaced = await SubtitleFileSave.write(data, to: taken, replacing: true)
        let text = (try? String(contentsOf: taken, encoding: .utf8)) ?? ""
        checks.require(replaced == .written && text.contains("Hello there"), "a confirmed Export As replaces it")
        let fresh = folder.appendingPathComponent("Fresh.srt")
        let made = await SubtitleFileSave.write(data, to: fresh, replacing: false)
        checks.require(made == .written && ((try? String(contentsOf: fresh, encoding: .utf8)) ?? "").contains("Hello there"),
                       "Export As to a new name writes the file (the claim is filled, not left empty)")
    }
}
