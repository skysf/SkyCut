import AppKit
import Foundation
import SrtFlowCore
@testable import SrtFlow

// The bench for the Burn In subtitle checks (export-profile's SubtitleEditsChecks and SubtitleExportChecks, project-saves'
// SubtitleQuitChecks): subtitle files in a folder of their own; every alert shown through RunLoopAlert (the questions,
// "Replace?", "Could Not Save") answered by pressing the production alert's own buttons, found by title (`replies` in
// order, Cancel when none are left), each written down with its buttons and whether it ran inside a Swift task; every
// subtitle write passing a gate that can hold it or make it fail.
@MainActor final class SubtitleEditsBench {
    let folder: URL
    let gate = SubtitleWriteGate()
    /// The questions asked, as their alerts' message texts.
    private(set) var asked: [String] = []
    /// Their informative texts (after a failed Save: why, first).
    private(set) var details: [String] = []
    /// Their buttons' titles, in order.
    private(set) var buttons: [[String]] = []
    /// A question was asked inside a Swift task (it must come from a run-loop turn: system-file-windows.md rule 10).
    private(set) var askedInTask = false
    /// Button titles a reply named that the alert does not have.
    private(set) var missingButtons: [String] = []
    /// The buttons to press, in order, by their English titles.
    var replies: [String] = []
    /// Runs when the next alert comes up, before it is answered (something changing while it is up).
    var whileAsked: (() -> Void)?
    private let run = RunLoopAlert.run
    private let perform = SubtitleFileSave.perform

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        RunLoopAlert.run = { [unowned self] alert in
            if withUnsafeCurrentTask(body: { $0 != nil }) { askedInTask = true }
            asked.append(alert.messageText)
            details.append(alert.informativeText)
            buttons.append(alert.buttons.map(\.title))
            let change = whileAsked
            whileAsked = nil
            change?()
            // No reply left: Cancel when the alert has it, otherwise its only button (a message's OK).
            let title = replies.isEmpty ? (alert.buttons.contains { $0.title == L10n("Cancel") } ? "Cancel" : nil) : replies.removeFirst()
            let index: Int? = title.map { title in alert.buttons.firstIndex { $0.title == L10n(title) } } ?? 0
            guard let index else {
                missingButtons.append(title ?? "?")
                return .cancel
            }
            return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        }
        let gate = gate, perform = perform
        SubtitleFileSave.perform = { data, url, replacing in
            gate.pass(url)
            if gate.failing { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            return try perform(data, url, replacing)
        }
    }

    /// Why a write fails while the gate is failing (the system's words, as SubtitleFileSave passes them on).
    func failure(_ url: URL) -> String {
        CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]).localizedDescription
    }

    /// The seams as they were.
    func restore() {
        RunLoopAlert.run = run
        SubtitleFileSave.perform = perform
        gate.reset()
    }

    /// The question's message for `file`, as the alert words it.
    func question(_ file: String) -> String { String(format: L10n("Save the changes to “%@”?"), file) }

    /// Nothing asked yet, nothing to press, the gate open and writing.
    func forget() {
        asked = []
        details = []
        buttons = []
        replies = []
        whileAsked = nil
        gate.reset()
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A one-line subtitle file.
    @discardableResult
    func write(_ url: URL, _ line: String) -> URL {
        try? Data("1\n00:00:00,000 --> 00:00:01,500\n\(line)\n".utf8).write(to: url)
        return url
    }

    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func load(_ url: URL) -> SubtitleDocumentModel? { try? SubtitleLoader.load(url) }

    /// Waits until `edits` has no page action left waiting for its questions or saves (at most 5 s).
    func idle(_ edits: BurnInSubtitleEdits) async { _ = await until { !edits.isBusy } }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }
}

/// Holds subtitle writes while armed (at most 3 s each), makes them fail while failing, and writes down which file each was
/// for.
final class SubtitleWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var waiting = 0
    private var log: [String] = []
    private var failingNow = false
    /// Held writes allowed through while armed (letOneThrough).
    private var permits = 0

    /// Writes fail (no permission) while this is on.
    var failing: Bool {
        get { condition.lock(); defer { condition.unlock() }; return failingNow }
        set { condition.lock(); failingNow = newValue; condition.unlock() }
    }

    func pass(_ url: URL) {
        condition.lock()
        log.append(url.lastPathComponent)
        waiting += 1
        let end = Date().addingTimeInterval(3)
        while armed, permits == 0, condition.wait(until: end) {}
        if armed, permits > 0 { permits -= 1 }
        waiting -= 1
        condition.unlock()
    }

    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    func open() {
        condition.lock()
        armed = false
        permits = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Lets the next held write through and keeps holding the ones after it.
    func letOneThrough() {
        condition.lock()
        permits += 1
        condition.broadcast()
        condition.unlock()
    }

    func reset() {
        open()
        condition.lock()
        log = []
        failingNow = false
        condition.unlock()
    }

    var isHolding: Bool {
        condition.lock()
        defer { condition.unlock() }
        return armed && waiting > 0
    }

    /// The files written so far, by name.
    var written: [String] {
        condition.lock()
        defer { condition.unlock() }
        return log
    }
}
