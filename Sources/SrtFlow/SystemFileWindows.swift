import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// MARK: - Every macOS open / save window outside the export panel
//
// What it does: one shared SystemFileChooser for the whole app — one system window at a time, as with the modal panels
// before — that callers ask with a FileWindowRequest and answer in a closure or awaited. While the window has been up a
// while, a small helper next to it offers "Close It" (a window whose service hangs has dead buttons); when the system
// window fails — never appears, vanishes, comes back empty at once, closed as stuck, or the last run ended with one open —
// the helper offers the same job without it: type or paste a path, drag the files from Finder, or try the window again.
// What it doesn't: the window itself (SystemFileChooser); the export panel's folder row (its own chooser and UI); what a
// caller does with the files (a caller whose project changed meanwhile checks that itself).
// Rules: docs/architecture/system-file-windows.md.

/// What the helper next to the system window can show (a seam: the checks record what would be shown).
@MainActor
protocol FileWindowHelping: AnyObject {
    /// Next to the system window: "If the macOS window stops responding, close it here."
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
    /// How long the system window stays up before the helper offers "Close It" (most picks take less).
    private let stripDelay: TimeInterval
    /// The caller still waiting for an answer.
    private var answer: (([URL]?) -> Void)?
    private var phaseWatch: AnyCancellable?
    private var stripTask: Task<Void, Never>?

    /// nil: the real window and helper (the checks pass fakes).
    init(chooser: SystemFileChooser? = nil, helper: FileWindowHelping? = nil, stripDelay: TimeInterval = 5) {
        let chooser = chooser ?? SystemFileChooser()
        self.chooser = chooser
        self.helper = helper ?? FileWindowHelper()
        self.stripDelay = stripDelay
        phaseWatch = chooser.$phase.dropFirst().sink { [weak self] phase in
            MainActor.assumeIsolated { self?.phaseChanged(phase) }
        }
    }

    /// Asks for `request`; `then` gets the picked URLs (never called when nothing was picked). While a window is already
    /// up, a second request brings nothing new up and gets no answer: the open window is what the person is answering.
    func open(_ request: FileWindowRequest, then: @escaping ([URL]) -> Void) {
        start(request) { urls in
            if let urls, !urls.isEmpty { then(urls) }
        }
    }

    /// The same, awaited: nil when nothing was picked.
    func choose(_ request: FileWindowRequest) async -> [URL]? {
        await withCheckedContinuation { continuation in
            start(request) { continuation.resume(returning: $0) }
        }
    }

    private func start(_ request: FileWindowRequest, answer: @escaping ([URL]?) -> Void) {
        guard chooser.phase != .choosing else { return answer(nil) }
        // A failed window's fallback still up for an earlier request: that caller gets nothing.
        chooser.dismissFailure()
        finish(nil)
        self.answer = answer
        chooser.choose(request) { [weak self] urls in self?.finish(urls) }
    }

    /// "Try Again" in the fallback: the system window once more, the record's detour skipped.
    private func tryAgain() {
        guard let request = chooser.request else { return finish(nil) }
        helper.hide()
        chooser.dismissFailure()
        chooser.choose(request, force: true) { [weak self] urls in self?.finish(urls) }
    }

    /// Answered from the fallback (a typed path, dropped files) or given up there.
    private func answerWithoutWindow(_ urls: [URL]?) {
        chooser.dismissFailure()
        finish(urls)
    }

    private func finish(_ urls: [URL]?) {
        stripTask?.cancel()
        stripTask = nil
        helper.hide()
        let pending = answer
        answer = nil
        pending?(urls)
    }

    private func phaseChanged(_ phase: SystemFileChooser.Phase) {
        stripTask?.cancel()
        stripTask = nil
        switch phase {
        case .choosing:
            let delay = stripDelay
            stripTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Only next to a window that is on screen (one that never comes is given up by the chooser's watcher).
                while let self, !Task.isCancelled, self.chooser.phase == .choosing, !self.chooser.windowIsVisible {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let self, !Task.isCancelled, self.chooser.phase == .choosing else { return }
                self.helper.showStrip(near: self.chooser.windowFrame) { [weak self] in self?.chooser.closeStuckWindow() }
            }
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

    static func chooseSaveLocation(
        types: [UTType], name: String, start: URL? = nil, prompt: String? = nil, message: String? = nil,
        then: @escaping (URL) -> Void
    ) {
        let request = FileWindowRequest(kind: .save(types: types, name: name), start: start, prompt: prompt, message: message)
        SystemFileWindows.shared.open(request) { urls in
            if let file = urls.first { then(file) }
        }
    }
}
