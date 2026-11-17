import AppKit
import SwiftUI
@testable import SrtFlow

// 离屏出图共用的一件：把一个视图放进屏幕外的窗口、等它排好、用系统的 screencapture 按窗口号拍成 PNG。
// 声音库（scripts/render-voice-library.sh）和动效预设（scripts/render-motion-presets.sh）的出图都用它；只是出图，不判对错。
// 2026-11-16 从 checks/VoiceLibraryUI/Render.swift 搬出来（第二个用处）：多了固定尺寸和指定浅 / 深两个可选参数，不给时和原来一样。

@MainActor
enum Snapshot {
    /// `size` = nil 按视图自己要的大小；`appearance` = nil 照真 App 的规矩（森林色固定浅色、经典色跟系统）。
    static func take<Content: View>(
        _ view: Content, to file: URL, size: CGSize? = nil, appearance: NSAppearance? = nil
    ) async throws {
        let host = NSHostingView(rootView: view.appLanguage().background(AppThemePalette.current.window))
        // 系统截不到整个在屏幕外的窗口：摆在主屏左下角、排在所有窗口的最底下（不抢前台、不成为 key）。
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: size?.width ?? 600, height: size?.height ?? 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // 真 App 里 sheet 的浅 / 深外观由 `.preferredColorScheme` 给（森林色固定浅色）；自建的窗口够不着它，照同一条规矩自己设。
        window.appearance = appearance ?? (AppThemePalette.current.isForest ? NSAppearance(named: .aqua) : nil)
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        container.addSubview(host)
        window.orderBack(nil)
        // 等 `.task` 里的取数、布局各走完几轮（假服务当场回答）。
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 80_000_000)
            let fitted = size ?? host.fittingSize
            host.frame = NSRect(origin: .zero, size: fitted)
            window.setContentSize(fitted)
            container.frame = NSRect(origin: .zero, size: fitted)
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
        guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw AIToolError("screencapture could not capture \(file.lastPathComponent); the terminal needs Screen Recording permission")
        }
        window.orderOut(nil)
        window.close()
        print("rendered \(file.lastPathComponent) \(Int(host.bounds.width))x\(Int(host.bounds.height))")
    }
}
