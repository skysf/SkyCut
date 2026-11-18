import Foundation

// MARK: - The export panel's destination: which folder, and what the last check of it said
//
// What it does: holds the folder the export panel exports into and the latest ExportDestinationProbe report for it.
// The remembered folder is used if it is still there, otherwise the start folder (docs/architecture/export-settings.md
// §4); a chosen, typed or dropped folder is taken only after a check that writes into it; one more check with a
// write test runs right before anything is written. Everything that touches the drive goes through the probe, off the
// main thread, so the panel never waits on a slow or stuck drive.
// What it doesn't: the checks themselves (ExportDestinationProbe), the row (ExportFolderRow), the messages
// (ExportDestinationText), remembering the folder (VideoEditExporter.exportFolder).

@MainActor
final class ExportDestinationState: ObservableObject {
    /// The folder the panel shows and exports into.
    @Published private(set) var folder: URL
    /// The last check of `folder`; nil while the first one is still out.
    @Published private(set) var report: ExportDestinationReport?
    @Published private(set) var isChecking = false

    private let probe: ExportDestinationProbe
    /// A check that only looks (the panel opens, the folder changes).
    private let lookDeadline: TimeInterval
    /// A check that also writes, right before an export: an asleep hard drive can take this long to spin up.
    private let writeDeadline: TimeInterval
    /// Bumped whenever the folder changes: a check that comes back late for an older folder is dropped.
    private var latest = 0
    private var running = 0

    init(folder: URL, probe: ExportDestinationProbe = .shared, lookDeadline: TimeInterval = 5, writeDeadline: TimeInterval = 15) {
        self.folder = folder
        self.probe = probe
        self.lookDeadline = lookDeadline
        self.writeDeadline = writeDeadline
    }

    /// The panel opened: the remembered folder if it is still there, else `fallback` (deleted, drive unplugged).
    /// A drive that does not answer keeps the remembered folder (it may only be asleep) and says so.
    func resolve(remembered: URL?, fallback: URL) async {
        latest += 1
        let token = latest
        guard let remembered else { return await show(fallback, token: token) }
        let report = await check(remembered, writeTest: false)
        if report.problem == .missing || report.problem == .notAFolder {
            await show(fallback, token: token)
        } else {
            apply(remembered, report, token: token)
        }
    }

    /// Look again (after an export, "Check Again").
    func refresh() async {
        latest += 1
        await show(folder, token: latest)
    }

    /// A folder that was chosen, typed or dropped: taken only when SkyCut can write into it (a dropped file means
    /// the folder it is in). Returns why it was not taken.
    func use(_ candidate: URL) async -> ExportDestinationProblem? {
        var target = candidate
        var report = await check(target, writeTest: true)
        if report.problem == .notAFolder {
            target = candidate.deletingLastPathComponent()
            report = await check(target, writeTest: true)
        }
        if let problem = report.problem { return problem }
        latest += 1
        apply(target, report, token: latest)
        return nil
    }

    /// Right before writing into the folder (the video, subtitle files): looks again and writes a test file.
    func checkBeforeWriting() async -> ExportDestinationReport {
        let checked = folder
        let report = await check(checked, writeTest: true)
        if checked == folder { self.report = report }
        return report
    }

    /// Where the macOS folder window starts: the destination, unless the last check found its drive gone or not
    /// answering. Pointing the system window at a stuck drive is how its service gets stuck (2026-11-18 case).
    var windowStart: URL {
        switch report?.problem {
        case .noResponse?, .missing?: return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        default: return folder
        }
    }

    /// A path someone typed or pasted: quotes and Terminal's `\ ` escapes removed, `~` expanded, `file://` accepted.
    /// nil when it is not a full path.
    static func url(typed text: String) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url }
        path = (path.replacingOccurrences(of: "\\ ", with: " ") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func show(_ url: URL, token: Int) async {
        let report = await check(url, writeTest: false)
        apply(url, report, token: token)
    }

    private func apply(_ url: URL, _ report: ExportDestinationReport, token: Int) {
        guard token == latest else { return }
        folder = url
        self.report = report
    }

    private func check(_ url: URL, writeTest: Bool) async -> ExportDestinationReport {
        running += 1
        isChecking = true
        defer {
            running -= 1
            isChecking = running > 0
        }
        return await probe.inspect(url, writeTest: writeTest, deadline: writeTest ? writeDeadline : lookDeadline)
    }
}
