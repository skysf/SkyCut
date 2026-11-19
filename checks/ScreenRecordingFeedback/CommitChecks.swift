import Foundation
import SrtFlowCore
@testable import SrtFlow

// A recording's commit replaces a file only when the person confirmed replacing it
// (docs/bugfixes/2026-11-19-free-save-name-treated-as-replace-consent.md). Real files in a temporary folder and the real
// journal store: a file that appears at the chosen name after the commit's intent was written — the end of a long manual
// recording to a free name, or the instant after a numbered name was picked — keeps its bytes, the recording takes the
// next name and the journal names where it really went; the microphone sidecar the same; a commit the person confirmed
// replaces the file that is there.
@MainActor enum RecordingCommitChecks {
    static func run(root: URL, require: (Bool, String) -> Void) {
        let folder = root.appendingPathComponent("commit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ScreenRecordingManifestStore(
            applicationSupport: root.appendingPathComponent("journal", isDirectory: true), bundleIdentifier: "commit-check"
        )
        lateMainFile(folder: folder, store: store, require: require)
        lateSidecar(folder: folder, store: store, require: require)
        confirmed(folder: folder, store: store, require: require)
    }

    /// Not confirmed; a file appears at the name right after the intent to commit there was written.
    private static func lateMainFile(folder: URL, store: ScreenRecordingManifestStore, require: (Bool, String) -> Void) {
        let request = request("Late", in: folder, microphone: false)
        let late = request.outputURL
        var planted = false
        let committed = try? commit(request, store: store, replacing: false) { manifest in
            guard manifest.stage == .committingMain, !planted else { return }
            planted = true
            try? Data("saved by another app".utf8).write(to: late, options: .atomic)
        }
        let second = folder.appendingPathComponent("Late 2.mov")
        require(planted && read(late) == "saved by another app" && committed?.mainURL == second && read(second) == "recording",
                "a file that appears at a free name after the commit's intent keeps its bytes; the recording takes the next name: "
                + "\(committed?.mainURL.lastPathComponent ?? "nil")")
        require(committed?.manifest.mainFinalPath == second.path && committed?.manifest.stage == .mainCommitted,
                "the journal names where the recording really went")
    }

    /// Not confirmed; a file appears at the sidecar's name right after its intent was written.
    private static func lateSidecar(folder: URL, store: ScreenRecordingManifestStore, require: (Bool, String) -> Void) {
        let request = request("Talk", in: folder, microphone: true)
        let late = request.microphoneURL
        var planted = false
        let committed = try? commit(request, store: store, replacing: false) { manifest in
            guard manifest.stage == .committingMicrophone, !planted else { return }
            planted = true
            try? Data("someone else's sound".utf8).write(to: late, options: .atomic)
        }
        let second = folder.appendingPathComponent("Talk-Mic 2.m4a")
        require(planted && read(late) == "someone else's sound" && committed?.microphoneURL == second && read(second) == "microphone"
                && committed?.manifest.micFinalPath == second.path,
                "a file that appears at the sidecar's name keeps its bytes; the sidecar takes the next name: "
                + "\(committed?.microphoneURL?.lastPathComponent ?? "nil")")
    }

    /// Confirmed in macOS's own window for a file that is there: that file is replaced.
    private static func confirmed(folder: URL, store: ScreenRecordingManifestStore, require: (Bool, String) -> Void) {
        let request = request("Replace", in: folder, microphone: false)
        try? Data("the old take".utf8).write(to: request.outputURL)
        let committed = try? commit(request, store: store, replacing: true) { _ in }
        require(committed?.mainURL == request.outputURL && read(request.outputURL) == "recording",
                "a commit the person confirmed replaces the file at its name")
    }

    private static func commit(
        _ request: ScreenRecordingRequest, store: ScreenRecordingManifestStore, replacing: Bool,
        persisted: (ScreenRecordingManifest) -> Void
    ) throws -> ScreenRecordingFileCommit.Committed {
        try Data("recording".utf8).write(to: request.temporaryURL(for: .main))
        if request.microphone.isEnabled { try Data("microphone".utf8).write(to: request.temporaryURL(for: .microphone)) }
        let manifest = ScreenRecordingFileCommit.startingManifest(for: request, sessionID: request.sessionID)
        try store.persist(manifest)
        return try ScreenRecordingFileCommit(store: store).commit(
            request: request, manifest: manifest, commitMicrophone: request.microphone.isEnabled,
            replacesExistingOutput: replacing, persisted: persisted
        )
    }

    private static func request(_ name: String, in folder: URL, microphone: Bool) -> ScreenRecordingRequest {
        ScreenRecordingRequest(
            sessionID: UUID(), source: .display(displayID: 1), microphone: microphone ? .device(id: "check") : .disabled,
            outputURL: folder.appendingPathComponent("\(name).mov"), capturePixelSize: CGSize(width: 320, height: 180),
            documentGeneration: 1, canvasRatioSnapshot: "auto", canvasEditGeneration: 0, projectHadVisualMedia: false
        )
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
