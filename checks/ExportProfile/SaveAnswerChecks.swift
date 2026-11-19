import Foundation
import UniformTypeIdentifiers
@testable import SrtFlow

// What a save window's answer may replace (docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md,
// docs/bugfixes/2026-11-19-free-save-name-treated-as-replace-consent.md), with fake windows and real files: macOS's own window
// asks "Replace?" only about a file that is there when it answers, so its answer may replace only such a file; a free name
// it answered was no decision, and a file that appears there before the write keeps its bytes; a drive that does not answer
// the look allows nothing; the helper's typed and dropped answers never asked; a confirmation covers only its own URL.
@MainActor enum SaveAnswerChecks {
    static func run(record: SystemFileWindowRecord, require: (Bool, String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-answers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let save = FileWindowRequest(kind: .save(types: [.quickTimeMovie], name: "Teaser.mov"))
        await systemWindow(save, folder: folder, record: record, require: require)
        await helperAnswers(save, folder: folder, record: record, require: require)
        let picked = folder.appendingPathComponent("Teaser.mov")
        let confirmed = SaveLocation(url: picked, mayReplace: true)
        require(confirmed.at(picked).mayReplace && !confirmed.at(picked.appendingPathExtension("skycut")).mayReplace,
                "a confirmation covers only the URL it was asked about, not a name the caller completes")
    }

    /// macOS's own window.
    private static func systemWindow(
        _ save: FileWindowRequest, folder: URL, record: SystemFileWindowRecord, require: (Bool, String) -> Void
    ) async {
        let taken = folder.appendingPathComponent("Taken.mov")
        try? Data("kept".utf8).write(to: taken)
        let asked = await answer(taken, to: save, record: record)
        require(asked == SaveLocation(url: taken, mayReplace: true),
                "macOS's own window answering a file that is there asked about it: it may be replaced (\(String(describing: asked)))")

        // The review's case: a free name, then another app saves a file there before SkyCut writes.
        let free = folder.appendingPathComponent("Free.mov")
        let location = await answer(free, to: save, record: record)
        require(location == SaveLocation(url: free, mayReplace: false),
                "a free name answered by macOS's own window was never a decision to replace (\(String(describing: location)))")
        try? Data("saved by another app after the window answered".utf8).write(to: free)
        let written = try? NewFileClaim.write(Data("SkyCut's file".utf8), to: free, replacing: location?.mayReplace ?? true)
        require(written == .occupied && read(free) == "saved by another app after the window answered",
                "a file that appears at a free name after the window answered keeps its bytes (\(String(describing: written)))")

        // A drive that does not answer the look: replacing is not allowed, and the answer still comes at the deadline.
        let held = HeldLook()
        let deadline = SystemFileWindows.replaceLookDeadline
        SystemFileWindows.replaceLookDeadline = 0.3
        let stuck = await answer(taken, to: save, record: record, probe: ExportDestinationProbe(fileSystem: held.fileSystem))
        SystemFileWindows.replaceLookDeadline = deadline
        held.open()
        require(stuck == SaveLocation(url: taken, mayReplace: false),
                "a drive that does not answer the look allows no replacing (\(String(describing: stuck)))")
    }

    /// The helper's answers never asked about replacing.
    private static func helperAnswers(
        _ save: FileWindowRequest, folder: URL, record: SystemFileWindowRecord, require: (Bool, String) -> Void
    ) async {
        let shots = folder.appendingPathComponent("Shots", isDirectory: true)
        let answers = [("typed folder", TypedPath.answer(shots.path + "/", for: save)),
                       ("dropped folder", TypedPath.accepted([shots], for: save).first),
                       ("typed path", TypedPath.answer(shots.path + "/Teaser.mov", for: save))]
        for (label, answer) in answers {
            let failing = FileWindowsChecks.Rig(record: record) { FakeFolderPanel(.neverShows) }
            var got: SaveLocation?
            failing.windows.openSave(save) { got = $0 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            failing.helper.answer?(answer.map { [$0] })
            require(answer != nil && got == answer.map { SaveLocation(url: $0, mayReplace: false) },
                    "a \(label) in the helper never asked about replacing, so it may not replace: \(String(describing: got))")
        }
    }

    private static func answer(
        _ url: URL, to save: FileWindowRequest, record: SystemFileWindowRecord, probe: ExportDestinationProbe = .shared
    ) async -> SaveLocation? {
        let window = FileWindowsChecks.Rig(record: record, probe: probe) { FakeFolderPanel(.answers(url, after: 0.1)) }
        return await window.windows.chooseSave(save)
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A drive whose "is anything there?" never answers until the check opens it (at most 3 s).
final class HeldLook: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false

    var fileSystem: ExportDestinationProbe.FileSystem {
        var fileSystem = ExportDestinationProbe.FileSystem.live
        fileSystem.kind = { [self] url in
            hold()
            return ExportDestinationProbe.FileSystem.live.kind(url)
        }
        return fileSystem
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }

    private func hold() {
        condition.lock()
        let end = Date().addingTimeInterval(3)
        while !opened, condition.wait(until: end) {}
        condition.unlock()
    }
}
