import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The helper next to a macOS open / save window
//
// What it does: SkyCut's own small window (in-process, so it keeps working when the system's panel service hangs) for
// SystemFileWindows: when the person asks for another file window while the system window is up, a strip next to it with
// "Close It" (never on a timer since 2026-11-27); when the system window failed, the same job without it — type or paste
// a path, drag the files from Finder, or try the window again.
// What it doesn't: the system window or when it failed (SystemFileChooser); which request is open (SystemFileWindows);
// the export panel's folder row (it has its own inline version, ExportFolderRow).
// Rules: docs/architecture/system-file-windows.md.

@MainActor
final class FileWindowHelper: NSObject, FileWindowHelping, NSWindowDelegate {
    private var panel: NSPanel?
    /// The fallback's answer when its window is closed with the red button.
    private var onClose: (() -> Void)?

    func showStrip(near frame: NSRect, close: @escaping () -> Void) {
        present(FileWindowStripView(close: close), near: frame, takesKeyboard: false, onClose: nil)
    }

    func showFallback(
        _ request: FileWindowRequest, failure: SystemFileChooser.Failure,
        answer: @escaping ([URL]?) -> Void, tryAgain: @escaping () -> Void
    ) {
        let view = FileWindowFallbackView(request: request, failure: failure, answer: answer, tryAgain: tryAgain)
        present(view, near: .zero, takesKeyboard: true) { answer(nil) }
    }

    func hide() {
        onClose = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        let closed = onClose
        onClose = nil
        panel = nil
        closed?()
    }

    private func present<Content: View>(_ content: Content, near frame: NSRect, takesKeyboard: Bool, onClose: (() -> Void)?) {
        hide()
        let host = NSHostingView(rootView: content.appLanguage())
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: takesKeyboard ? [.titled, .closable] : [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "SkyCut"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.delegate = self
        place(panel, near: frame)
        self.onClose = onClose
        self.panel = panel
        if takesKeyboard { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
    }

    /// Just below the system window when there is room, else just above it; centered when there is no system window.
    private func place(_ panel: NSPanel, near frame: NSRect) {
        guard frame != .zero, let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let x = min(max(frame.midX - size.width / 2, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
        let below = frame.minY - size.height - 8
        let y = below >= screen.visibleFrame.minY ? below : min(frame.maxY + 8, screen.visibleFrame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The person asked for another file window while the system window is up: a way to close that window if it is stuck. It
/// names the file window and says the button closes it (never SkyCut); the user approved the wording on 2026-11-27.
struct FileWindowStripView: View {
    let close: () -> Void

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(spacing: 10) {
            Text("If the window for choosing a file is stuck or not responding, click here to close it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { close() }
                .instantHelp("Close the window for choosing a file")
        }
        .padding(12)
        .frame(width: 420)
    }
}

/// The system window failed: the same job without it.
struct FileWindowFallbackView: View {
    let request: FileWindowRequest
    let failure: SystemFileChooser.Failure
    let answer: ([URL]?) -> Void
    let tryAgain: () -> Void

    @State private var typed = ""
    @State private var refusedTyped = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: FileWindowText.message(failure, for: request))
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $typed, prompt: Text(verbatim: "/Volumes/…"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(useTyped)
            if refusedTyped {
                Text(verbatim: FileWindowText.refused(request))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Try Again") { tryAgain() }
                    .instantHelp("Open the macOS window again")
                Spacer(minLength: 0)
                Button("Cancel") { answer(nil) }
                Button(FileWindowText.useLabel(for: request)) { useTyped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { typed = TypedPath.suggestion(for: request) }
        .dropDestination(for: URL.self) { urls, _ in
            let taken = TypedPath.accepted(urls, for: request)
            guard !taken.isEmpty else { return false }
            answer(taken)
            return true
        }
    }

    private func useTyped() {
        guard let url = TypedPath.answer(typed, for: request) else {
            refusedTyped = true
            return
        }
        answer([url])
    }
}

/// A typed or dropped answer to a FileWindowRequest — decided without touching a drive (the consumer checks the file
/// the way it would have after the system window).
enum TypedPath {
    /// A path someone typed or pasted: quotes and Terminal's `\ ` escapes removed, `~` expanded, `file://` accepted.
    /// nil when it is not a full path.
    static func url(_ text: String, isDirectory: Bool) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url }
        path = (path.replacingOccurrences(of: "\\ ", with: " ") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    /// What the field starts with: the start folder, and for a save the suggested name in it.
    static func suggestion(for request: FileWindowRequest) -> String {
        guard let start = request.start else { return "" }
        if case .save(_, let name) = request.kind { return start.appendingPathComponent(name).path }
        return start.path + (request.kind == .folder ? "" : "/")
    }

    /// A typed path as the answer: a folder for a folder request; a file of an allowed type for files; for a save, a
    /// path ending in "/" means "into this folder" with the suggested name, and a name without an extension gets the type's.
    static func answer(_ text: String, for request: FileWindowRequest) -> URL? {
        switch request.kind {
        case .folder:
            return url(text, isDirectory: true)
        case .files:
            guard let file = url(text, isDirectory: false) else { return nil }
            return accepted([file], for: request).first
        case .save(let types, let name):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("/") { return url(trimmed, isDirectory: true)?.appendingPathComponent(name) }
            return url(trimmed, isDirectory: false).map { withExtension($0, types) }
        }
    }

    /// Dropped files: those the request can take (a folder request takes a folder, or a file's folder; a save takes the
    /// suggested name in the dropped folder).
    static func accepted(_ urls: [URL], for request: FileWindowRequest) -> [URL] {
        let files = urls.filter(\.isFileURL)
        switch request.kind {
        case .folder:
            return files.first.map { [$0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent()] } ?? []
        case .save(_, let name):
            return files.first.map { [($0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent()).appendingPathComponent(name)] } ?? []
        case .files(let types, let multiple):
            let taken = files.filter { !$0.hasDirectoryPath && (request.allowsOtherTypes || types.isEmpty || conforms($0, to: types)) }
            return multiple ? taken : Array(taken.prefix(1))
        }
    }

    private static func conforms(_ url: URL, to types: [UTType]) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    private static func withExtension(_ url: URL, _ types: [UTType]) -> URL {
        guard url.pathExtension.isEmpty, let ext = types.first?.preferredFilenameExtension else { return url }
        return url.appendingPathExtension(ext)
    }
}

/// What the fallback says (one place, all three tables).
enum FileWindowText {
    static func message(_ failure: SystemFileChooser.Failure, for request: FileWindowRequest) -> String {
        let lastRun = failure == .lastRunDidNotFinish
        switch request.kind {
        case .files:
            return lastRun
                ? L10n("Last time SkyCut had to be closed while a macOS file window was open. Type the file's full path below, or drag the file here from Finder.")
                : L10n("The macOS file window did not work. Type the file's full path below, or drag the file here from Finder.")
        case .folder:
            return lastRun
                ? L10n("Last time SkyCut had to be closed while a macOS file window was open. Type the folder's path below, or drag a folder here from Finder.")
                : L10n("The macOS file window did not work. Type the folder's path below, or drag a folder here from Finder.")
        case .save:
            return lastRun
                ? L10n("Last time SkyCut had to be closed while a macOS file window was open. Type the full path to save to below, or drag a folder here from Finder.")
                : L10n("The macOS file window did not work. Type the full path to save to below, or drag a folder here from Finder.")
        }
    }

    static func useLabel(for request: FileWindowRequest) -> String {
        switch request.kind {
        case .files: return request.prompt ?? L10n("Open")
        case .folder: return L10n("Use This Folder")
        case .save: return L10n("Save Here")
        }
    }

    static func refused(_ request: FileWindowRequest) -> String {
        switch request.kind {
        case .files: return L10n("Type the full path of a file SkyCut can open here, starting with “/”.")
        case .folder: return L10n("Type the full path of a folder, starting with “/”.")
        case .save: return L10n("Type the full path to save to, starting with “/”.")
        }
    }
}
