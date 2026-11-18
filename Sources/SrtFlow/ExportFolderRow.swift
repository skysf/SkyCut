import SwiftUI

// MARK: - The export panel's "Export to" row
//
// What it does: the destination path; the folder button (the macOS folder window, non-modal, SystemFileChooser);
// dropping a folder (or a file: its folder) from Finder; what the last off-main check of the folder said
// (ExportDestinationState); and, when the macOS folder window failed, typing a path instead — so choosing a folder
// never depends on the system panel service alone.
// What it doesn't: the checks (ExportDestinationProbe), opening the window (SystemFileChooser), remembering the
// folder (the caller's `remember`).
// Rules: docs/architecture/export-settings.md, "Export folder window and destination checks".

struct ExportFolderRow: View {
    @ObservedObject var destination: ExportDestinationState
    @ObservedObject var chooser: SystemFileChooser
    /// A folder passed its check and is now the destination: remember it.
    let remember: (URL) -> Void

    @State private var typedPath = ""
    @State private var typedPathIsNotAPath = false
    /// Why the last chosen / typed / dropped folder was not taken, and which folder that was.
    @State private var refused: (problem: ExportDestinationProblem, folder: URL)?
    @State private var isTaking = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        LabeledContent("Export to") {
            HStack(spacing: 6) {
                // 封住理想宽度：长路径从中间截断，这一行不至于被挤成上下两行。
                Text(verbatim: (destination.folder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 230, alignment: .trailing)
                    .instantHelp(verbatim: destination.folder.path)
                if chooser.phase == .choosing || isTaking || destination.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button {
                    chooser.choose(.exportFolder(startingAt: destination.windowStart)) { if let url = $0?.first { take(url) } }
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(chooser.phase == .choosing || isTaking)
                .instantHelp("Choose the folder to export into, or drag a folder here from Finder")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            take(url)
            return true
        }
        .onChange(of: chooser.phase) { _, phase in
            if case .failed = phase, typedPath.isEmpty { typedPath = destination.folder.path }
        }
        chooserRows
        if let message = problemMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if refused == nil, destination.report?.problem == .noResponse {
                    Spacer(minLength: 0)
                    Button("Check Again") { Task { await destination.refresh() } }
                        .controlSize(.small)
                        .instantHelp("Look at the export folder again")
                }
            }
        }
    }

    // MARK: - While the macOS window is open / after it failed

    @ViewBuilder
    private var chooserRows: some View {
        switch chooser.phase {
        case .idle:
            EmptyView()
        case .choosing:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Choose a folder in the macOS window. If that window stops responding, close it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Close It") { chooser.closeStuckWindow() }
                    .controlSize(.small)
                    .instantHelp("Close the macOS folder window")
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: ExportDestinationText.message(failure))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("", text: $typedPath, prompt: Text(verbatim: "/Volumes/…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(useTypedPath)
                    Button("Use This Folder") { useTypedPath() }
                        .disabled(typedPath.trimmingCharacters(in: .whitespaces).isEmpty || isTaking)
                        .instantHelp("Export into the folder at this path")
                }
                if typedPathIsNotAPath {
                    Text("Type the full path of a folder, starting with “/”.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button("Try Again") {
                        chooser.choose(.exportFolder(startingAt: destination.windowStart), force: true) { if let url = $0?.first { take(url) } }
                    }
                        .instantHelp("Open the macOS folder window again")
                    Button("Keep This Folder") { chooser.dismissFailure() }
                        .instantHelp("Keep exporting into the folder above")
                }
                .controlSize(.small)
            }
        }
    }

    private var problemMessage: String? {
        if let refused { return ExportDestinationText.message(refused.problem, folder: refused.folder) }
        guard let problem = destination.report?.problem else { return nil }
        return ExportDestinationText.message(problem, folder: destination.folder)
    }

    private func useTypedPath() {
        guard let url = ExportDestinationState.url(typed: typedPath) else {
            typedPathIsNotAPath = true
            return
        }
        typedPathIsNotAPath = false
        take(url)
    }

    /// Chosen, typed or dropped: checked (off the main thread, with a write test) before it becomes the destination.
    private func take(_ url: URL) {
        isTaking = true
        refused = nil
        Task { @MainActor in
            let problem = await destination.use(url)
            isTaking = false
            if let problem {
                refused = (problem, url)
            } else {
                remember(destination.folder)
                chooser.dismissFailure()
                typedPath = ""
            }
        }
    }
}

/// What the export panel says about its destination and the macOS folder window (one place, all three tables).
/// The AI's export_video says the same sentences in English (`L10n: { $0 }`: the en table's keys are its text). The
/// parameter is named `L10n` on purpose: the calls below stay literal `L10n("…")`, which the localization guard scans.
enum ExportDestinationText {
    static func message(_ problem: ExportDestinationProblem, folder: URL, L10n: (String) -> String = SrtFlow.L10n) -> String {
        let name = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        switch problem {
        case .missing:
            return String(format: L10n("“%@” is not there. Check that its drive is connected, or choose another folder."), name)
        case .notAFolder:
            return String(format: L10n("“%@” is a file, not a folder."), name)
        case .readOnlyVolume:
            return String(format: L10n("“%@” is on a drive macOS can only read from (an NTFS drive, for example). Choose a folder on another drive."), name)
        case .notWritable(let reason):
            return String(format: L10n("SkyCut can't write into “%1$@” (%2$@). Choose another folder, or check its permissions."), name, reason)
        case .noResponse:
            return String(format: L10n("The drive with “%@” is not responding. It may be asleep or disconnected, or macOS may be asking for permission."), name)
        }
    }

    static func message(_ failure: SystemFileChooser.Failure) -> String {
        switch failure {
        case .lastRunDidNotFinish:
            return L10n("Last time SkyCut had to be closed while the macOS folder window was open. Type the folder's path below, or drag a folder here from Finder.")
        case .noWindow, .returnedAtOnce, .closedByUser:
            return L10n("The macOS folder window did not work. Type the folder's path below, or drag a folder here from Finder.")
        }
    }
}

extension FileWindowRequest {
    /// The export panel's folder window.
    static func exportFolder(startingAt folder: URL) -> FileWindowRequest {
        FileWindowRequest(kind: .folder, start: folder, prompt: L10n("Choose"), message: L10n("Choose the folder to export into"))
    }
}
