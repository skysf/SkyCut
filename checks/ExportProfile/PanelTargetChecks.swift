import Foundation
@testable import SrtFlow

// The export panel writes the file it checked and asked about
// (docs/bugfixes/2026-11-19-export-panel-checks-one-folder-writes-another.md). Folder A is the destination; folder B, which
// already holds a file of the export's name, is being taken while Export is pressed, and the two checks come back in the
// reverse order (A's drive slower). Pressing Export must end in the question about B's file, B's file must stay until
// Replace, Replace writes exactly that file, and an export nobody was asked about never replaces a file that appears.
@MainActor enum PanelTargetChecks {
    static func run(root: URL, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let folderA = root.appendingPathComponent("panel-a", isDirectory: true)
        let folderB = root.appendingPathComponent("panel-b", isDirectory: true)
        let folderC = root.appendingPathComponent("panel-c", isDirectory: true)
        for folder in [folderA, folderB, folderC] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let film = folderB.appendingPathComponent("Clip.mp4")
        try? Data("B's own film".utf8).write(to: film)
        // A's drive answers in 0.6 s, B's in 0.2 s: B's check comes back first although A's was asked for later or earlier.
        var slow = ExportDestinationProbe.FileSystem.live
        slow.kind = { url in
            if url.path.hasPrefix(folderA.path) { Thread.sleep(forTimeInterval: 0.6) }
            if url.path.hasPrefix(folderB.path) { Thread.sleep(forTimeInterval: 0.2) }
            return ExportDestinationProbe.FileSystem.live.kind(url)
        }
        let probe = ExportDestinationProbe(fileSystem: slow)

        // 1. B dropped first (its check is out), Export pressed while it is: the decision waits for B and is about B.
        let dropped = ExportDestinationState(folder: folderA, probe: probe, lookDeadline: 5, writeDeadline: 5)
        let taking = Task { await dropped.use(folderB) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let first = await dropped.exportDecision(stem: "Clip", pathExtension: "mp4")
        _ = await taking.value
        await act(first, project: project)
        require(first == .askToReplace(film), "Export pressed while B is being taken asks about B's file: \(first)")
        require(read(film) == "B's own film", "B's file stays until the user says Replace")

        // 2. Export pressed first (A's check out), then B taken; A's check comes back last and is dropped.
        let pressedFirst = ExportDestinationState(folder: folderA, probe: probe, lookDeadline: 5, writeDeadline: 5)
        async let pressed = pressedFirst.exportDecision(stem: "Clip", pathExtension: "mp4")
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await pressedFirst.use(folderB)
        let second = await pressed
        await act(second, project: project)
        require(second == .askToReplace(film), "a check that comes back for A after B was taken is dropped; B is asked about: \(second)")
        require(read(film) == "B's own film" && !FileManager.default.fileExists(atPath: folderA.appendingPathComponent("Clip.mp4").path),
                "nothing is written into A or over B's file before Replace")

        // 3. Replace writes exactly the file the question named.
        if case .askToReplace(let file) = second { await act(.export(.replacing(file)), project: project) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: film.path))?[.size] as? Int) ?? 0
        require(size > 1000 && VideoEditExporter.shared.finishedURL == film,
                "Replace writes exactly the file it asked about (a real video now, \(size) bytes)")

        // 4. Nothing there when checked, a file appears during the export: the export is a new file and never replaces it.
        let fresh = ExportDestinationState(folder: folderC)
        let third = await fresh.exportDecision(stem: "Clip", pathExtension: "mp4")
        let late = folderC.appendingPathComponent("Clip.mp4")
        try? Data("made by Finder during the export".utf8).write(to: late)
        await act(third, project: project)
        require(third == .export(.newFile(folder: folderC, stem: "Clip", pathExtension: "mp4", number: 1))
                && read(late) == "made by Finder during the export"
                && VideoEditExporter.shared.finishedURL?.lastPathComponent == "Clip 2.mp4",
                "an export nobody was asked about never replaces a file that appeared meanwhile: \(third)")
    }

    /// What the panel does with a decision: exports at once, or (asking) nothing until Replace.
    private static func act(_ decision: ExportDecision, project: VideoEditProject) async {
        guard case .export(let target) = decision else { return }
        let exporter = VideoEditExporter.shared
        for _ in 0..<600 where exporter.isExporting { try? await Task.sleep(nanoseconds: 50_000_000) }
        exporter.export(for: project, state: project.state, to: target, subtitleStyle: .default, subtitleFontURL: nil)
        for _ in 0..<1200 where exporter.isExporting { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }
}
