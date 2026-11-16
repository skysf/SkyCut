import AppKit
import SwiftUI
@testable import SrtFlow

// Off-screen renders of production views for PR images (scripts/render-voice-library.sh, scripts/render-project-versions.sh).
// Moved here from checks/VoiceLibraryUI/Render.swift when the second render tool needed it (2026-11-17).

/// 把一个视图放进屏幕外的窗口、等它排好、存成 PNG。
@MainActor
enum Snapshot {
    static func take<Content: View>(_ view: Content, to file: URL) async throws {
        let host = NSHostingView(rootView: view.appLanguage().background(AppThemePalette.current.window))
        // 系统截不到整个在屏幕外的窗口：摆在主屏左下角、排在所有窗口的最底下（不抢前台、不成为 key）。
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // 真 App 里 sheet 的浅 / 深外观由 `.preferredColorScheme` 给（森林色固定浅色）；自建的窗口够不着它，照同一条规矩自己设。
        window.appearance = AppThemePalette.current.isForest ? NSAppearance(named: .aqua) : nil
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        container.addSubview(host)
        window.orderBack(nil)
        // 等 `.task` 里的取数、布局各走完几轮（假服务当场回答）。
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            window.setContentSize(size)
            container.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        // AppKit 的控件（输入框、分段、下拉、勾选框）`cacheDisplay` 画不对（黑底、发白）：按窗口号用系统的 screencapture 拍，
        // 窗口在屏幕外也拍得到；它用的是起这个脚本的终端的录屏权限。
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-l", String(window.windowNumber), "-o", "-x", file.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus != 0 || !FileManager.default.fileExists(atPath: file.path) {
            // No Screen Recording permission for the process that started the script (an agent's shell, CI): draw the view
            // ourselves. Text, shapes and buttons come out right; text fields and pickers may not (see above), so it says so.
            guard ProcessInfo.processInfo.environment["SRTFLOW_RENDER_DRAW_FALLBACK"] == "1",
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw AIToolError("screencapture could not capture \(file.lastPathComponent); the terminal needs Screen Recording permission "
                    + "(or set SRTFLOW_RENDER_DRAW_FALLBACK=1 to draw it without)")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AIToolError("could not encode \(file.lastPathComponent)") }
            try png.write(to: file)
            print("drew \(file.lastPathComponent) without screencapture (SRTFLOW_RENDER_DRAW_FALLBACK)")
        }
        window.orderOut(nil)
        window.close()
        print("rendered \(file.lastPathComponent) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
    }
}
