import AppKit
@testable import SrtFlow

// Off-screen renders of what SkyCut says when it offers to move itself from the installer disk into Applications
// (scripts/render-move-to-applications.sh): the question (alone, and with the line about the app already there), the
// progress panel, and the alerts for a move that stopped (an app of that name running, a folder this user can't write, a
// failed copy, a failed install with the old app left in the Trash, a moved copy that didn't open), in en / zh-Hans / es,
// plus the question in dark. The production objects (MoveToApplicationsAlerts) laid out and captured by window number,
// behind every window. Only images, no verdicts: the behaviour is pinned by scripts/check-move-to-applications.sh.

@main enum MoveToApplicationsRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.movetoapplicationsrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("The move render requires the isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: environment["SRTFLOW_MOVE_RENDER_OUT"]!)
        // The alerts show the app's icon (NSAlert's default); the render app has none of its own.
        appIcon = environment["SRTFLOW_MOVE_RENDER_ICON"].flatMap(NSImage.init(contentsOfFile:))
        if let appIcon { NSApp.applicationIconImage = appIcon } else { print("note: no app icon, the alerts show the generic one") }
        let trashed = URL(fileURLWithPath: "/Users/someone/.Trash/SkyCut.app")
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                let code = language.rawValue
                let name = "SkyCut"
                let detail = SampleReason.systemReason
                try await capture(MoveToApplicationsAlerts.question(appName: name, replacing: false), to: out, "question-\(code)")
                try await capture(MoveToApplicationsAlerts.question(appName: name, replacing: true), to: out, "question-replacing-\(code)")
                try await capture(MoveToApplicationsAlerts.progressPanel(appName: name), to: out, "progress-\(code)")
                try await capture(MoveToApplicationsAlerts.running(appName: name), to: out, "running-\(code)")
                try await capture(MoveToApplicationsAlerts.notWritable(appName: name), to: out, "not-writable-\(code)")
                try await capture(MoveToApplicationsAlerts.failed(.copy, detail: detail, oldAppInTrash: nil, appName: name),
                                  to: out, "failed-copy-\(code)")
                try await capture(MoveToApplicationsAlerts.failed(.install, detail: detail, oldAppInTrash: trashed, appName: name),
                                  to: out, "failed-install-old-in-trash-\(code)")
                try await capture(MoveToApplicationsAlerts.openFailed(appName: name, detail: nil), to: out, "open-failed-\(code)")
            }
            AppLanguageStore.shared.language = .english
            try await capture(MoveToApplicationsAlerts.question(appName: "SkyCut", replacing: true), to: out, "question-replacing-en-dark",
                              appearance: NSAppearance(named: .darkAqua))
        } catch {
            print("FAIL: move render: \(error)")
            exit(1)
        }
        print("PASS: rendered the move-to-Applications alerts in en, zh-Hans and es to \(out.path)")
        exit(0)
    }

    @MainActor private static var appIcon: NSImage?

    @MainActor
    private static func capture(_ alert: NSAlert, to folder: URL, _ name: String, appearance: NSAppearance? = nil) async throws {
        if let appIcon { alert.icon = appIcon }
        alert.layout()
        try await capture(alert.window, to: folder, name, appearance: appearance)
    }

    /// The window behind every other one at the main screen's bottom-left (never key, never in front), captured by its
    /// number with the system's screencapture; drawn with cacheDisplay when the terminal has no Screen Recording permission
    /// and SRTFLOW_RENDER_DRAW_FALLBACK=1 (as checks/OffscreenRender/Snapshot.swift does for SwiftUI views).
    @MainActor
    private static func capture(_ window: NSWindow, to folder: URL, _ name: String, appearance: NSAppearance? = nil) async throws {
        let file = folder.appendingPathComponent(name + ".png")
        window.appearance = appearance ?? NSAppearance(named: .aqua)
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        window.orderBack(nil)
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 80_000_000)
            window.displayIfNeeded()
        }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-l", String(window.windowNumber), "-o", "-x", file.path]
        try shot.run()
        shot.waitUntilExit()
        if shot.terminationStatus != 0 || !FileManager.default.fileExists(atPath: file.path) {
            guard ProcessInfo.processInfo.environment["SRTFLOW_RENDER_DRAW_FALLBACK"] == "1", let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw AIToolError("screencapture could not capture \(name); the terminal needs Screen Recording permission "
                    + "(or set SRTFLOW_RENDER_DRAW_FALLBACK=1 to draw it without)")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AIToolError("could not encode \(name)") }
            try png.write(to: file)
            print("drew \(name) without screencapture (SRTFLOW_RENDER_DRAW_FALLBACK)")
        }
        window.orderOut(nil)
        print("rendered \(name) \(Int(window.frame.width))x\(Int(window.frame.height))")
    }
}

/// A system reason as a failed copy reports it, in the render's language (the real one comes from macOS in its own).
private enum SampleReason {
    @MainActor static var systemReason: String {
        switch AppLanguageStore.shared.language {
        case .simplifiedChinese: return "未能完成操作。设备上没有空间。"
        case .spanish: return "No se ha podido completar la operación. No queda espacio en el dispositivo."
        default: return "The operation couldn’t be completed. No space left on device."
        }
    }
}
