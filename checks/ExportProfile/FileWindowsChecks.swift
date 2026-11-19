import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import SrtFlow

// Every macOS open / save window outside the export panel (SystemFileWindows, 2026-11-19,
// docs/bugfixes/2026-11-19-modal-file-windows-can-wedge-app.md), with fake windows and a helper that records what it
// would show: an answer reaches the caller; a cancel answers nothing; a window that never comes is given up with the main
// thread free and the fallback offered, and a typed answer there reaches the caller; a window that stays up gets "Close
// It" next to it, which closes it and offers the fallback; "Try Again" asks AppKit again; a second request while one window
// is up opens nothing; a record left by a force quit sends the next request to the fallback first. A save's answer may
// replace a file only when it came from macOS's own window. Then the typed and dropped answers (TypedPath), which never
// touch a drive.
@MainActor enum FileWindowsChecks {
    static func run(require: (Bool, String) -> Void) async {
        let suite = "com.srtflow.SrtFlow.exportprofilecheck.filewindows"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let record = SystemFileWindowRecord(suiteName: suite)
        let a = URL(fileURLWithPath: "/tmp/a.mp4"), b = URL(fileURLWithPath: "/tmp/b.mov")
        let files = FileWindowRequest(kind: .files(types: [.movie], multiple: true), start: URL(fileURLWithPath: "/tmp"))

        // Answered: the caller gets the files, the helper never shows.
        let answering = Rig(record: record) { FakeFolderPanel(.answers(a, after: 0.2)) }
        var got: [URL]?
        answering.windows.open(files) { got = $0 }
        await settle(0.6)
        require(got == [a] && answering.helper.shown.isEmpty, "a picked file reaches the caller; no helper for a quick pick")

        // Cancelled by the person: nothing, and the awaited form says nil.
        let cancelling = Rig(record: record) { FakeFolderPanel(.answers(nil, after: 1.2)) }
        let none = await cancelling.windows.choose(files)
        require(none == nil && !cancelling.helper.shown.contains { $0.hasPrefix("fallback") } && cancelling.helper.hidden > 0,
                "a cancelled window answers nothing and is not a failure (no fallback; its helper goes away)")

        // Never appears: given up after the deadline with the main thread free, the fallback offered for this request.
        let never = Rig(record: record) { FakeFolderPanel(.neverShows) }
        var typedAnswer: [URL]?
        never.windows.open(files) { typedAnswer = $0 }
        let meter = MainThreadGapMeter()
        meter.start()
        await settle(1.5)
        let gap = meter.stop()
        require(never.helper.shown == ["fallback noWindow"] && never.helper.fallbackRequest == files,
                "a window that never comes offers the fallback for that request: \(never.helper.shown)")
        require(gap < 0.5, "waiting for a window that never comes keeps the main thread free: longest gap \(gap) s")
        never.helper.answer?([b])
        require(typedAnswer == [b] && never.helper.hidden > 0, "an answer typed or dropped in the fallback reaches the caller")

        // Up and never answering: "Close It" next to it after the delay; it closes the window and offers the fallback;
        // "Try Again" asks AppKit again (force: the record's detour skipped) and its answer reaches the caller.
        let stuck = Rig(record: record, panels: [FakeFolderPanel(.staysStuck), FakeFolderPanel(.answers(a, after: 0.1))])
        var retried: [URL]?
        stuck.windows.open(files) { retried = $0 }
        await settle(0.6)
        require(stuck.helper.shown == ["strip"] && stuck.helper.stripFrame == stuck.made.first?.frame,
                "a window up for a while gets Close It next to it: \(stuck.helper.shown)")
        stuck.helper.close?()
        require(stuck.made.first?.cancels == 1 && stuck.helper.shown.last == "fallback closedByUser",
                "Close It cancels the stuck window and offers the fallback")
        stuck.helper.tryAgain?()
        await settle(0.4)
        require(stuck.made.count == 2 && retried == [a], "Try Again opens the macOS window again and its answer reaches the caller")

        // A second request while a window is up opens nothing and answers nothing.
        let busy = Rig(record: record) { FakeFolderPanel(.staysStuck) }
        busy.windows.open(files) { _ in }
        let second = await busy.windows.choose(FileWindowRequest(kind: .folder))
        require(second == nil && busy.made.count == 1, "one system window at a time: a second request opens nothing")
        busy.windows.chooser.cancelIfChoosing()

        // A force quit left the record: the fallback comes first and AppKit is not asked.
        var previous = record
        previous.processID = record.processID &+ 1
        previous.markStarted()
        let detour = Rig(record: record) { FakeFolderPanel(.answers(a, after: 0.1)) }
        detour.windows.open(FileWindowRequest(kind: .save(types: [.movie], name: "Cut.mov"))) { _ in }
        require(detour.made.isEmpty && detour.helper.shown == ["fallback lastRunDidNotFinish"],
                "after a run that ended with a window open, the fallback comes first")
        detour.helper.answer?(nil)

        await saveAnswers(require: require, record: record)
        typedAndDropped(require: require)
    }

    /// A save's answer says whether replacing a file there was confirmed: macOS's own window asked, the helper never did
    /// (docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md); a confirmation covers only the URL it was for.
    private static func saveAnswers(require: (Bool, String) -> Void, record: SystemFileWindowRecord) async {
        let save = FileWindowRequest(kind: .save(types: [.quickTimeMovie], name: "Teaser.mov"))
        let picked = URL(fileURLWithPath: "/Volumes/Disk/Teaser.mov")
        let window = Rig(record: record) { FakeFolderPanel(.answers(picked, after: 0.1)) }
        let asked = await window.windows.chooseSave(save)
        require(asked == SaveLocation(url: picked, mayReplace: true),
                "an answer from macOS's own save window may replace (it asked): \(String(describing: asked))")

        let folder = URL(fileURLWithPath: "/Volumes/Disk/Shots", isDirectory: true)
        let helperAnswers = [("typed folder", TypedPath.answer(folder.path + "/", for: save)),
                             ("dropped folder", TypedPath.accepted([folder], for: save).first),
                             ("typed path", TypedPath.answer(folder.path + "/Teaser.mov", for: save))]
        for (label, answer) in helperAnswers {
            let failing = Rig(record: record) { FakeFolderPanel(.neverShows) }
            var got: SaveLocation?
            failing.windows.openSave(save) { got = $0 }
            await settle(1.5)
            failing.helper.answer?(answer.map { [$0] })
            require(answer != nil && got == answer.map { SaveLocation(url: $0, mayReplace: false) },
                    "a \(label) in the helper never asked about replacing, so it may not replace: \(String(describing: got))")
        }
        let confirmed = SaveLocation(url: picked, mayReplace: true)
        require(confirmed.at(picked).mayReplace && !confirmed.at(picked.appendingPathExtension("skycut")).mayReplace,
                "a confirmation covers only the URL it was asked about, not a name the caller completes")
    }

    /// Typed paths and dropped files decide the answer without a drive.
    private static func typedAndDropped(require: (Bool, String) -> Void) {
        let movies = FileWindowRequest(kind: .files(types: [.movie], multiple: false))
        require(TypedPath.answer("'/Volumes/My Passport/C0001.MP4'", for: movies)?.path == "/Volumes/My Passport/C0001.MP4",
                "a typed movie path is taken (quotes removed)")
        require(TypedPath.answer("/Volumes/Disk/notes.txt", for: movies) == nil, "a typed file of another kind is refused")
        var anyKind = movies
        anyKind.allowsOtherTypes = true
        require(TypedPath.answer("/Volumes/Disk/clip.mkv", for: anyKind) != nil, "files macOS doesn't know are taken where allowed")
        require(TypedPath.answer("Movies/a.mp4", for: movies) == nil, "not a full path: refused")

        // A type every Mac knows: SkyCut's own project type is only registered where SkyCut is installed (not on CI), and
        // the project's Save As adds .skycut itself (chooseSaveLocation).
        let save = FileWindowRequest(kind: .save(types: [.quickTimeMovie], name: "Teaser.mov"))
        require(TypedPath.answer("/Volumes/Disk/Projects/", for: save)?.path == "/Volumes/Disk/Projects/Teaser.mov",
                "a typed folder for a save gets the suggested name")
        require(TypedPath.answer("~/Desktop/Cut", for: save)?.path == NSHomeDirectory() + "/Desktop/Cut.mov",
                "a typed name without an extension gets the type's")

        let folder = FileWindowRequest(kind: .folder)
        let dropped = [URL(fileURLWithPath: "/Volumes/Disk/Shots/C0002.MP4"), URL(fileURLWithPath: "/Volumes/Disk/Shots/C0003.MP4")]
        require(TypedPath.accepted(dropped, for: folder).map(\.path) == ["/Volumes/Disk/Shots"], "a dropped file means its folder")
        require(TypedPath.accepted(dropped, for: movies).count == 1
                && TypedPath.accepted(dropped, for: FileWindowRequest(kind: .files(types: [.movie], multiple: true))).count == 2,
                "dropped files: one where one is asked, all where several are")
        require(TypedPath.accepted([URL(fileURLWithPath: "/Volumes/Disk/Shots", isDirectory: true)], for: save).map(\.path)
                == ["/Volumes/Disk/Shots/Teaser.mov"], "a folder dropped on a save gets the suggested name")
    }

    private static func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The shared windows with short deadlines, fake windows (made in order) and a helper that records what it shows.
    @MainActor final class Rig {
        @MainActor final class Made { var panels: [FakeFolderPanel] = [] }

        let windows: SystemFileWindows
        let helper: RecordingHelper
        private let store: Made
        var made: [FakeFolderPanel] { store.panels }

        convenience init(record: SystemFileWindowRecord, make: @escaping () -> FakeFolderPanel) {
            self.init(record: record, factory: make)
        }

        convenience init(record: SystemFileWindowRecord, panels: [FakeFolderPanel]) {
            var queue = panels
            self.init(record: record) { queue.isEmpty ? FakeFolderPanel(.neverShows) : queue.removeFirst() }
        }

        private init(record: SystemFileWindowRecord, factory: @escaping () -> FakeFolderPanel) {
            let store = Made()
            let helper = RecordingHelper()
            let chooser = SystemFileChooser(
                makePanel: { _ in let panel = factory(); store.panels.append(panel); return panel },
                record: record, note: { _ in }, appearDeadline: 0.6, quickReturn: 0.05
            )
            self.store = store
            self.helper = helper
            windows = SystemFileWindows(chooser: chooser, helper: helper, stripDelay: 0.4)
        }
    }

    /// Records what the helper would show and keeps its buttons' actions.
    @MainActor final class RecordingHelper: FileWindowHelping {
        private(set) var shown: [String] = []
        private(set) var hidden = 0
        private(set) var stripFrame: NSRect?
        private(set) var fallbackRequest: FileWindowRequest?
        private(set) var close: (() -> Void)?
        private(set) var answer: (([URL]?) -> Void)?
        private(set) var tryAgain: (() -> Void)?

        func showStrip(near frame: NSRect, close: @escaping () -> Void) {
            shown.append("strip")
            stripFrame = frame
            self.close = close
        }

        func showFallback(
            _ request: FileWindowRequest, failure: SystemFileChooser.Failure,
            answer: @escaping ([URL]?) -> Void, tryAgain: @escaping () -> Void
        ) {
            shown.append("fallback \(failure)")
            fallbackRequest = request
            self.answer = answer
            self.tryAgain = tryAgain
        }

        func hide() { hidden += 1 }
    }
}
