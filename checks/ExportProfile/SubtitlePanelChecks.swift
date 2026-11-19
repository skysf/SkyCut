import Foundation
import SrtFlowCore
@testable import SrtFlow

// The export panel's subtitle files replace only what the replace question named
// (docs/bugfixes/2026-11-19-subtitle-export-replaces-unlisted-file.md), through the button's own work (SubtitleFilesWrite:
// the button calls `request`, the question's Replace calls `replace`) on real folders. The review's sequence: the original
// SRT is there and the translated VTT is not; while the question about the SRT is open, another export makes the VTT;
// Replace replaces the SRT, leaves the VTT as it was and says so. A check whose listing came back without a file that
// appeared before the write asks nothing and replaces nothing. With nothing there, both are written and nothing is said.
@MainActor enum SubtitlePanelChecks {
    static func run(root: URL, require: (Bool, String) -> Void) async {
        await whileAsked(root: root, require: require)
        await staleListing(root: root, require: require)
        await nothingThere(root: root, require: require)
    }

    private static let lines = SubtitleDocumentModel(cues: [SubtitleCue(index: 1, start: 0, end: 1.5, text: "Hello from SkyCut")])

    private static func files(_ folder: URL) -> [SubtitleFilesWrite.File] {
        [SubtitleFilesWrite.File(document: lines, format: .srt, url: folder.appendingPathComponent("Talk.en.srt")),
         SubtitleFilesWrite.File(document: lines, format: .vtt, url: folder.appendingPathComponent("Talk.zh-Hans.vtt"))]
    }

    /// The question names the SRT; the VTT appears while it is open; Replace.
    private static func whileAsked(root: URL, require: (Bool, String) -> Void) async {
        let folder = make(root, "subtitle-panel-asked")
        let srt = folder.appendingPathComponent("Talk.en.srt"), vtt = folder.appendingPathComponent("Talk.zh-Hans.vtt")
        try? Data("the old original".utf8).write(to: srt)
        let writer = SubtitleFilesWrite()
        await writer.request(destination: ExportDestinationState(folder: folder), files: files)
        require(writer.asksToReplace && writer.question == [srt] && !writer.isWriting,
                "the replace question names the file the check found: \(writer.question.map(\.lastPathComponent))")
        try? Data("made by another export while the question was open".utf8).write(to: vtt)
        await writer.replace()
        require(text(srt).contains("Hello from SkyCut"), "Replace replaces the file the question named")
        require(text(vtt) == "made by another export while the question was open",
                "a file the question never listed is left as it was: \(text(vtt))")
        require(writer.written == [srt] && writer.error?.contains(vtt.lastPathComponent) == true,
                "only the named file is reported written, and the one left alone is said: \(writer.error ?? "nil")")
    }

    /// The check's listing comes back without a file that is there by the time of the write.
    private static func staleListing(root: URL, require: (Bool, String) -> Void) async {
        let folder = make(root, "subtitle-panel-stale")
        let srt = folder.appendingPathComponent("Talk.en.srt"), vtt = folder.appendingPathComponent("Talk.zh-Hans.vtt")
        try? Data("appeared after the listing".utf8).write(to: srt)
        let probe = ExportDestinationProbe(fileSystem: ListingBarrier(parties: 1, folder: folder, listing: []).fileSystem)
        let writer = SubtitleFilesWrite()
        await writer.request(destination: ExportDestinationState(folder: folder, probe: probe), files: files)
        require(!writer.asksToReplace && writer.question.isEmpty, "a listing without the file asks nothing")
        require(text(srt) == "appeared after the listing" && writer.written == [vtt]
                && writer.error?.contains(srt.lastPathComponent) == true,
                "a file the listing did not show is never replaced; the other file is written: \(writer.error ?? "nil")")
    }

    /// Nothing there: both written, nothing asked or said.
    private static func nothingThere(root: URL, require: (Bool, String) -> Void) async {
        let folder = make(root, "subtitle-panel-free")
        let writer = SubtitleFilesWrite()
        await writer.request(destination: ExportDestinationState(folder: folder), files: files)
        let all = files(folder).map(\.url)
        require(!writer.asksToReplace && writer.written == all && writer.error == nil
                && all.allSatisfy { text($0).contains("Hello from SkyCut") },
                "with nothing there both files are written: \(writer.written.map(\.lastPathComponent)), \(writer.error ?? "nil")")
    }

    private static func make(_ root: URL, _ name: String) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
