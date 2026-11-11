import AppKit
import SwiftUI

// 主题切换的真实回归：开着的每一种窗口 / 面板，切主题、系统切深浅色之后，窗框、SwiftUI 读到的浅 / 深、画出来的底色
// 三样都要和新主题一致（森林色永远浅；经典色跟系统，系统再切也跟着）。编译方式见 scripts/check-theme-switch.sh。
//
// 由来（docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md）：呈现根把经典色交成
// `.preferredColorScheme(nil)`，SwiftUI 只把窗口的外观还给系统、不撤掉之前的浅色 —— 系统深色时森林色 → 经典色，
// 主窗口、工程窗口、录屏控制条窗框深、内容浅，sheet 整个停在浅色。
//
// 系统的深浅色只在这个进程里模拟（`NSApp.appearance`，SkyCut 自己从不设它），不碰用户的系统设置。
// 主题 Store 不读写偏好：脚本开着 PerfCounters。每一步最多等 2 秒等它一致，过了还不一致才算红。
//
// 窗口放在屏幕左下角、完全透明（alphaValue 0）、不吃鼠标：挪到屏幕外不行 —— 挂上 sheet 的窗口会被 AppKit 拉回屏幕里，
// 锚在屏幕外的 popover 弹不出来。离屏渲染（cacheDisplay）不看窗口的透明度，量得照样准；用户的屏幕上什么都看不见。

@MainActor
enum Seen {
    /// 每个宿主里 SwiftUI 最后一次 body 读到的 colorScheme。
    static var scheme: [String: ColorScheme] = [:]
}

private struct Probe: View {
    let tag: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = { Seen.scheme[tag] = scheme }()
        // 材质跟着浅 / 深画：浅色是浅灰、深色是深灰，左上角量它。
        Text(verbatim: tag).padding(12).frame(width: 220, height: 90).background(.regularMaterial)
    }
}

@MainActor
final class Presented: ObservableObject {
    static let shared = Presented()
    @Published var sheet = false
    @Published var popover = false
}

/// 主窗口那种：SwiftUI 场景的窗口（SrtFlowApp 的 Window("SkyCut")），popover 也从它弹（剪辑页的 popover 都在窗口里）。
private struct MainWindowRoot: View {
    @ObservedObject var presented: Presented

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Probe(tag: "main window")
            .popover(isPresented: $presented.popover) { Probe(tag: "popover").appLanguage() }
    }
}

private struct ProjectWindowRoot: View {
    @ObservedObject var presented: Presented

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Probe(tag: "project window")
            .sheet(isPresented: $presented.sheet) { Probe(tag: "sheet").appLanguage() }
    }
}


@MainActor
final class Checks: NSObject, NSApplicationDelegate {
    private var failures = 0
    private var checks = 0
    private let presented = Presented.shared
    private var projectWindow: NSWindow!
    private var controlBar: NSPanel!
    private let anchorWindow = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false
    )
    private let anchor = TooltipAnchorBox()
    private var corner: NSPoint { NSScreen.main?.visibleFrame.origin ?? .zero }

    /// 看不见、点不着：透明、不吃鼠标，放在屏幕左下角。
    private func hide(_ window: NSWindow?) {
        guard let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 「系统是深色」：只改这个进程。
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // 工程窗口那种：AppKit 建的窗口，宿主就是 contentView（ProjectWindowController）。
        projectWindow = NSWindow(
            contentRect: NSRect(origin: corner, size: CGSize(width: 220, height: 90)),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        hide(projectWindow)
        projectWindow.contentView = NSHostingView(rootView: ProjectWindowRoot(presented: presented).appLanguage())
        projectWindow.orderFrontRegardless()
        // 录屏控制条那种：titled + fullSizeContentView 的 NSPanel，宿主就是 contentView（ScreenRecordingControlPanel）。
        controlBar = NSPanel(
            contentRect: NSRect(origin: corner, size: CGSize(width: 220, height: 90)),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false
        )
        hide(controlBar)
        controlBar.titlebarAppearsTransparent = true
        controlBar.contentView = NSHostingView(rootView: Probe(tag: "recording bar").appLanguage())
        controlBar.orderFrontRegardless()
        let view = NSView(frame: CGRect(x: 40, y: 100, width: 20, height: 18))
        anchorWindow.contentView?.addSubview(view)
        anchor.view = view
        Task { await run() }
    }

    private func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL \(message)")
        }
    }

    // MARK: 量

    private struct Host {
        let tag: String
        let window: NSWindow?
        let content: NSView?
        let readsSwiftUI: Bool
    }

    private func hosts() -> [Host] {
        let scene = NSApp.windows.first { $0.title == "ThemeSwitchScene" }
        let sheet = projectWindow.attachedSheet
        let popover = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        let tooltip = InstantTooltipController.shared.panelContentForChecks
        return [
            Host(tag: "main window", window: scene, content: scene?.contentView, readsSwiftUI: true),
            Host(tag: "project window", window: projectWindow, content: projectWindow.contentView, readsSwiftUI: true),
            Host(tag: "recording bar", window: controlBar, content: controlBar.contentView, readsSwiftUI: true),
            Host(tag: "sheet", window: sheet, content: sheet?.contentView, readsSwiftUI: true),
            Host(tag: "popover", window: popover, content: popover?.contentView, readsSwiftUI: true),
            Host(tag: "tooltip", window: tooltip?.window, content: tooltip, readsSwiftUI: false),
        ]
    }

    /// 离屏渲一张，量左上角那一块的亮度：材质浅色约 235、深色约 51。
    private func painted(_ view: NSView?) -> ColorScheme? {
        guard let view, view.bounds.width > 12, view.bounds.height > 12,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let c = rep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.5 ? .light : .dark
    }

    private func frame(_ window: NSWindow?) -> ColorScheme? {
        guard let window else { return nil }
        return window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// 每个宿主不一致的地方；空 = 全对。
    private func mismatches(_ expected: ColorScheme) -> [String] {
        var out: [String] = []
        for host in hosts() {
            var wrong: [String] = []
            let frameScheme = frame(host.window)
            let paintedScheme = painted(host.content)
            if frameScheme != expected { wrong.append("窗框 \(frameScheme.map { "\($0)" } ?? "没有")") }
            if host.readsSwiftUI, Seen.scheme[host.tag] != expected {
                wrong.append("SwiftUI 读到 \(Seen.scheme[host.tag].map { "\($0)" } ?? "没有")")
            }
            if paintedScheme != expected { wrong.append("画出来 \(paintedScheme.map { "\($0)" } ?? "没有")") }
            if !wrong.isEmpty { out.append("\(host.tag)：" + wrong.joined(separator: "、")) }
        }
        return out
    }

    /// 生产上提示每次悬停都重新 show；这里每一步重新弹一次，弹完同一轮挪到屏幕外（用户的屏幕上不出现）。
    private func showTooltip() {
        InstantTooltipController.shared.hide(owner: anchor)
        InstantTooltipController.shared.show(label: Text(verbatim: "Settings"), shortcut: nil, from: anchor)
        hide(InstantTooltipController.shared.panelContentForChecks?.window)
    }

    private func expect(_ step: String, _ expected: ColorScheme) async {
        showTooltip()
        var wrong = mismatches(expected)
        for _ in 0..<20 where !wrong.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
            wrong = mismatches(expected)
        }
        check(wrong.isEmpty, "\(step)：应当全是 \(expected)，2 秒后还不一致 —— " + wrong.joined(separator: "；"))
    }

    // MARK: 步骤

    private func run() async {
        let scene = NSApp.windows.first { $0.title == "ThemeSwitchScene" }
        hide(scene)
        scene?.setFrameOrigin(corner)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 先挂 sheet、再弹 popover：sheet 挂上时会成为 key，同时弹的 popover（transient）会被它关掉。
        presented.sheet = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        hide(projectWindow.attachedSheet)
        presented.popover = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        hide(NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") })
        showTooltip()
        let names = hosts().filter { $0.window != nil }.map(\.tag)
        check(names.count == 6, "六种宿主都要在场（主窗口、工程窗口、录屏控制条、sheet、popover、提示），实际 \(names)")

        let store = AppThemeStore.shared
        let system = { (name: NSAppearance.Name) in NSApp.appearance = NSAppearance(named: name) }
        await expect("森林色、系统深色", .light)
        store.setTheme(.classic)
        await expect("森林色 → 经典色、系统深色（用户撞上的）", .dark)
        system(.aqua)
        await expect("经典色、系统切成浅色", .light)
        system(.darkAqua)
        await expect("经典色、系统切回深色", .dark)
        store.setTheme(.forest)
        await expect("经典色 → 森林色、系统深色", .light)
        system(.aqua)
        await expect("森林色、系统切成浅色", .light)
        system(.darkAqua)
        await expect("森林色、系统切回深色（森林色不跟系统）", .light)
        store.setTheme(.classic)
        await expect("再切一次经典色、系统深色", .dark)
        store.setTheme(.forest)

        InstantTooltipController.shared.hide(owner: anchor)
        if failures == 0 {
            print("All \(checks) checks passed.")
            exit(0)
        }
        print("\(failures) of \(checks) checks FAILED.")
        exit(1)
    }
}

@main
struct ThemeSwitchChecks: App {
    @NSApplicationDelegateAdaptor(Checks.self) private var checks

    var body: some Scene {
        Window("ThemeSwitchScene", id: "main") { MainWindowRoot(presented: Presented.shared).appLanguage() }
            .defaultSize(width: 220, height: 90)
            .defaultPosition(.bottomLeading)
    }
}
