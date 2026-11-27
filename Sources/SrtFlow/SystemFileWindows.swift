import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - Every macOS open / save window outside the export panel
//
// What it does: one shared SystemFileChooser for the whole app — one system window at a time, as with the modal panels
// before — that callers ask with a FileWindowRequest and answer in a closure or awaited. Nothing appears next to the system
// window while the person chooses, however long they take. When they ask for another file window while it is up (the only
// sign SkyCut gets that it may be stuck: a window whose service hangs has dead buttons and macOS says nothing), a small
// helper next to it offers "Close It"; when the system window fails — never appears, vanishes, comes back empty at once,
// closed as stuck, or the last run ended with one open — the helper offers the same job without it: type or paste a path,
// drag the files from Finder, or try the window again. Until 2026-11-27 the strip came on a 5 s timer, next to every
// window a person took longer over (docs/bugfixes/2026-11-27-close-it-strip-popped-up-next-to-every-file-window.md).
// What it doesn't: the window itself (SystemFileChooser); the export panel's folder row (its own chooser and UI); what a
// caller does with the files (a caller whose project changed meanwhile checks that itself).
// A save's answer says whether replacing a file already there was confirmed (`SaveLocation`): only macOS's own save
// window asks that, and only about a file that is there when it answers; a typed or dropped answer in the helper never
// did, so its callers ask (SaveLocation.swift) (2026-11-19, docs/bugfixes/2026-11-19-save-window-fallback-replaces-a-file.md,
// docs/bugfixes/2026-11-19-free-save-name-treated-as-replace-consent.md).
// Rules: docs/architecture/system-file-windows.md.

/// What the helper next to the system window can show (a seam: the checks record what would be shown).
@MainActor
protocol FileWindowHelping: AnyObject {
    /// Next to the open system window, when the person asked for another one meanwhile: "If the window for choosing a file
    /// is stuck or not responding, click here to close it." with Close.
    func showStrip(near frame: NSRect, close: @escaping () -> Void)
    /// The system window failed: the same job without it.
    func showFallback(
        _ request: FileWindowRequest, failure: SystemFileChooser.Failure,
        answer: @escaping ([URL]?) -> Void, tryAgain: @escaping () -> Void
    )
    func hide()
}

@MainActor
final class SystemFileWindows {
    static let shared = SystemFileWindows()

    let chooser: SystemFileChooser
    private let helper: FileWindowHelping
    /// Asks the answered save location's drive whether a file is there (the checks pass a drive that never answers).
    private let probe: ExportDestinationProbe
    /// How long that look may take (the export panel's look at its folder; the checks shorten it).
    static var replaceLookDeadline: TimeInterval = 5
    /// The caller still waiting for an answer; the flag says it came from macOS's own window (not the helper).
    private var answer: (([URL]?, Bool) -> Void)?
    private var phaseWatch: AnyCancellable?
    /// While the strip stands next to another chooser's window (the export panel's): takes it away when that window closes.
    private var stripWatch: AnyCancellable?

    /// nil: the real window and helper (the checks pass fakes).
    init(chooser: SystemFileChooser? = nil, helper: FileWindowHelping? = nil, probe: ExportDestinationProbe = .shared) {
        let chooser = chooser ?? SystemFileChooser()
        self.chooser = chooser
        self.helper = helper ?? FileWindowHelper()
        self.probe = probe
        phaseWatch = chooser.$phase.dropFirst().sink { [weak self] phase in
            MainActor.assumeIsolated { self?.phaseChanged(phase) }
        }
    }

    /// Asks for `request`; `then` gets the picked URLs (never called when nothing was picked). While a window is already
    /// up, a second request brings nothing new up and gets no answer: the open window is what the person is answering, and
    /// the strip next to it offers to close it (`offerToCloseOpenWindow`).
    func open(_ request: FileWindowRequest, then: @escaping ([URL]) -> Void) {
        start(request) { urls, _ in
            if let urls, !urls.isEmpty { then(urls) }
        }
    }

    /// The same, awaited: nil when nothing was picked.
    func choose(_ request: FileWindowRequest) async -> [URL]? {
        await withCheckedContinuation { continuation in
            start(request) { urls, _ in continuation.resume(returning: urls) }
        }
    }

    /// A save window, awaited: where, and whether replacing a file there was confirmed. nil when nothing was chosen.
    func chooseSave(_ request: FileWindowRequest) async -> SaveLocation? {
        await withCheckedContinuation { continuation in
            openSave(request) { continuation.resume(returning: $0) }
        }
    }

    /// A save window answered in a closure: `then` gets nil when nothing was chosen. Replacing is allowed only for a file
    /// that is at the answered URL when macOS's own window answers — the only case in which that window asked "Replace?".
    /// A free name was never a decision to replace: a file that appears there before the write is not replaced. Whether a
    /// file is there is asked off the main thread with a deadline (`ExportDestinationProbe`); no answer = not allowed.
    func openSave(_ request: FileWindowRequest, then: @escaping (SaveLocation?) -> Void) {
        start(request) { [probe] urls, inSystemWindow in
            guard let url = urls?.first else { return then(nil) }
            guard inSystemWindow else { return then(SaveLocation(url: url, mayReplace: false)) }
            Task { @MainActor in
                let asked = await probe.run(
                    on: url.deletingLastPathComponent(), deadline: Self.replaceLookDeadline, timedOut: false
                ) { files in files.kind(url) != .missing }
                then(SaveLocation(url: url, mayReplace: asked))
            }
        }
    }

    private func start(_ request: FileWindowRequest, answer: @escaping ([URL]?, Bool) -> Void) {
        // One system file window in the whole app: this chooser's, or the export panel's folder window (its own chooser).
        guard SystemFileChooser.openWindow == nil else {
            offerToCloseOpenWindow()
            return answer(nil, false)
        }
        // A failed window's fallback still up for an earlier request: that caller gets nothing.
        chooser.dismissFailure()
        finish(nil, inSystemWindow: false)
        self.answer = answer
        chooser.choose(request) { [weak self] urls in self?.finish(urls, inSystemWindow: true) }
    }

    /// "Try Again" in the fallback: the system window once more, the record's detour skipped. If another file window opened
    /// meanwhile (the export panel's), this request gives way and the strip offers to close that one.
    private func tryAgain() {
        guard let request = chooser.request else { return finish(nil, inSystemWindow: false) }
        helper.hide()
        chooser.dismissFailure()
        let opened = chooser.choose(request, force: true) { [weak self] urls in self?.finish(urls, inSystemWindow: true) }
        if !opened {
            finish(nil, inSystemWindow: false)
            offerToCloseOpenWindow()
        }
    }

    /// Answered from the fallback (a typed path, dropped files) or given up there. Nobody asked "Replace?".
    private func answerWithoutWindow(_ urls: [URL]?) {
        chooser.dismissFailure()
        finish(urls, inSystemWindow: false)
    }

    /// The person asked for another file window while one is up (here, or with the export panel's folder button, which
    /// calls this when its chooser opens nothing): the one sign SkyCut gets that it may be stuck (macOS says nothing when
    /// its panel service hangs; the window just stops answering). The strip stands next to the open window, whichever
    /// chooser's it is, only while it is on screen (one that never comes is given up by its chooser's watcher); its button
    /// closes that window. Never on a timer: choosing a file takes as long as the person likes, and nothing pops up by itself.
    func offerToCloseOpenWindow() {
        guard let open = SystemFileChooser.openWindow, open.windowIsVisible else { return }
        stripWatch = nil
        if open !== chooser {
            // Nothing here hears the export panel's window close (its row shows its own fallback): watch it.
            stripWatch = open.$phase.dropFirst().sink { [weak self] phase in
                MainActor.assumeIsolated {
                    guard phase != .choosing, let self else { return }
                    self.stripWatch = nil
                    self.helper.hide()
                }
            }
        }
        helper.showStrip(near: open.windowFrame) { [weak open] in open?.closeStuckWindow() }
    }

    private func finish(_ urls: [URL]?, inSystemWindow: Bool) {
        stripWatch = nil
        helper.hide()
        let pending = answer
        answer = nil
        pending?(urls, inSystemWindow)
    }

    private func phaseChanged(_ phase: SystemFileChooser.Phase) {
        switch phase {
        case .choosing:
            break   // nothing next to the window while the person chooses (offerToCloseOpenWindow)
        case .failed(let failure):
            guard answer != nil, let request = chooser.request else { return }
            helper.showFallback(
                request, failure: failure,
                answer: { [weak self] urls in self?.answerWithoutWindow(urls) },
                tryAgain: { [weak self] in self?.tryAgain() }
            )
        case .idle:
            helper.hide()
        }
    }
}

/// The non-modal open / save windows the views ask for (the name the call sites always used; they were modal before
/// 2026-11-19). The project-related callers check that their project is still the one they asked for.
@MainActor
enum FilePicker {
    static func chooseFiles(
        types: [UTType], allowsMultiple: Bool = true, prompt: String? = nil, message: String? = nil, start: URL? = nil,
        then: @escaping ([URL]) -> Void
    ) {
        // 系统认不出的容器（.mkv 等）也得能选。
        let request = FileWindowRequest(
            kind: .files(types: types, multiple: allowsMultiple), start: start, prompt: prompt, message: message,
            allowsOtherTypes: true
        )
        SystemFileWindows.shared.open(request, then: then)
    }

    static func chooseDirectory(startingAt directory: URL? = nil, then: @escaping (URL) -> Void) {
        SystemFileWindows.shared.open(FileWindowRequest(kind: .folder, start: directory)) { urls in
            if let folder = urls.first { then(folder) }
        }
    }

    /// `then` gets where, and whether a file there may be replaced (`SaveLocation`); never called when nothing was chosen.
    static func chooseSaveLocation(
        types: [UTType], name: String, start: URL? = nil, prompt: String? = nil, message: String? = nil,
        then: @escaping (SaveLocation) -> Void
    ) {
        let request = FileWindowRequest(kind: .save(types: types, name: name), start: start, prompt: prompt, message: message)
        SystemFileWindows.shared.openSave(request) { location in
            if let location { then(location) }
        }
    }
}
