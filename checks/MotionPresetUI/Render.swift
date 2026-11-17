import AppKit
import SwiftUI
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 动效预设的离屏出图（scripts/render-motion-presets.sh）：给用户合并前看（2026-11-16 用户定：软件里看得见的新东西先出图）。
// 出的是：加字的「动效预设」一栏、检查器「动画」区的「预设」（英 / 中 / 西 × 森林色 / 经典色深色），和三套预设各几帧的预览与成片
// （RenderFrames.swift）。只出图、不判对错：规矩由 scripts/check-mcp.sh 的 MotionPresetChecks 钉着（docs/architecture/motion-presets.md）。
// 不碰网络、钥匙串、用户的设置（独立的 bundle id），窗口摆在屏幕外、不抢前台。

@main enum MotionPresetRender {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.motionpresetrender"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Motion preset render requires the isolated bundle") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_MOTION_RENDER_OUT"]!)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let project = OpenProjects.shared.primary
            try await renderInterface(project, out: out)
            AppThemeStore.shared.setTheme(.forest)
            NSApp.appearance = NSAppearance(named: .aqua)
            AppLanguageStore.shared.language = .english
            try await MotionPresetFrames.render(project, out: out)
        } catch {
            print("FAIL: motion preset render: \(error)")
            exit(1)
        }
        print("PASS: rendered the motion preset UI and frames to \(out.path)")
        exit(0)
    }

    /// 两种外观 × 三种界面语言：加字的那一栏、检查器的「动画」区；浅色再多一张整个文字检查器（看「预设」在哪）。
    @MainActor
    private static func renderInterface(_ project: VideoEditProject, out: URL) async throws {
        let looks: [(name: String, theme: AppTheme, appearance: NSAppearance?)] = [
            ("light", .forest, NSAppearance(named: .aqua)), ("dark", .classic, NSAppearance(named: .darkAqua))
        ]
        for look in looks {
            AppThemeStore.shared.setTheme(look.theme)
            NSApp.appearance = look.appearance
            for language in [AppLanguage.english, .simplifiedChinese, .spanish] {
                AppLanguageStore.shared.language = language
                func file(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(language.rawValue)-\(look.name).png") }
                // 检查器里选中的是「框住再放开」的标题（占位字跟着语言）。
                var state = TimelineState()
                state.canvasRatio = .wide16x9
                let built = MotionPresetGroups.build(MotionPresetActions.placeholder(.frameReveal, hit: 2.5),
                                                     canvas: TimelineRenderSize.size(for: state))
                MotionPresetGroups.place(built, in: &state)
                project.perform(rebuildsPreview: false) { $0 = state }
                guard let title = built.anchorText else { continue }
                project.selectedTextIDs = [title.id]

                try await Snapshot.take(MotionPresetPanel(project: project), to: file("1-add-panel"), appearance: look.appearance)
                try await Snapshot.take(AnimationPane(project: project, overlay: title), to: file("2-inspector-preset"),
                                        appearance: look.appearance)
                if look.name == "light" {
                    try await Snapshot.take(FullTextInspector(project: project, overlay: title), to: file("3-inspector-full"),
                                            appearance: look.appearance)
                }
                project.selectedTextIDs = []
            }
        }
    }
}

/// 检查器里文字的「动画」那一块，照检查器那条窄栏的宽度和边距摆（252 宽、两边 14）。
private struct AnimationPane: View {
    let project: VideoEditProject
    let overlay: TextOverlay

    var body: some View {
        VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused)
            .textAnimationSection(overlay)
            .padding(14)
            .frame(width: 252, alignment: .topLeading)
            .background(AppThemePalette.current.panel)
    }
}

/// 整个文字检查器（看「预设」落在「动画」区的最上面）。
private struct FullTextInspector: View {
    let project: VideoEditProject
    let overlay: TextOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VideoEditInspectorView(project: project, clock: project.clock, playhead: project.clock.whilePaused).textSection(overlay)
        }
        .padding(14)
        .frame(width: 252, alignment: .topLeading)
        .background(AppThemePalette.current.panel)
    }
}
