import AppKit
import SwiftUI
import SrtFlowCore

/// 工作台里的一个工具。
///
/// 「编辑字幕」不再单列：字幕表就在烧录那一栏的预览旁边，改完立刻能看到
/// 烧出来的样子，也能存回原文件。
enum ToolSection: String, CaseIterable, Identifiable {
    // 剪辑是默认工作台，其他工具在右上角的更多菜单里。
    case videoEdit
    case compress
    case burnIn
    case batchConvert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress Video"
        case .burnIn: return "Burn In Subtitles"
        case .videoEdit: return "Edit Video"
        case .batchConvert: return "Batch Convert"
        }
    }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.circle"
        case .burnIn: return "text.below.photo"
        case .videoEdit: return "film.stack"
        case .batchConvert: return "square.stack.3d.down.right"
        }
    }

    /// 工具用途的说明。
    var blurb: String {
        switch self {
        case .compress: return "Make files much smaller without visible quality loss."
        case .burnIn: return "Render subtitles permanently into the picture."
        case .videoEdit: return "Cut, arrange, and retime clips on a timeline."
        case .batchConvert: return "Convert many subtitle files at once."
        }
    }
}

/// 主窗口当前在哪一栏。
///
/// 单独拎出来是因为菜单和 Dock 拖放都要能切栏目，它们拿不到视图里的 `@State`。
@MainActor
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()

    private static let sectionKey = "mainWindowSection"

    /// 打开 App 总是进剪辑页（2026-10-01 用户定），不再记上次停在哪一栏。
    /// 冒烟 / 性能测试要直接起到别的页，用启动参数 `-mainWindowSection burnIn`（只认参数域，
    /// 不再往 defaults 里写）。
    @Published var section: ToolSection

    private init() {
        let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[Self.sectionKey] as? String
        section = argument.flatMap(ToolSection.init(rawValue:)) ?? .videoEdit
    }
}

/// 一个窗口装下所有工具：剪辑是默认工作台，更多菜单切换其他工具。
///
/// 以前压缩、烧字幕、批量转换各是一个独立窗口，来回切要在窗口之间找。合成一个
/// 之后还顺手解决了一件事：三个工具的状态都提到了全局（`EncodeQueue.compress`
/// 等），所以压缩可以在后台一直跑，同时去另一栏调字幕样式。
struct MainWindowView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var state = MainWindowState.shared
    @ObservedObject private var toolchain = MediaToolchain.shared
    @ObservedObject private var compressHandoff = CompressHandoff.shared
    @ObservedObject private var burnInHandoff = BurnInHandoff.shared
    // 这个视图在代码里拼字符串（L10n(...)），不是纯 LocalizedStringKey，
    // 光靠环境 locale 变化不会重新求值 body，所以要显式观察语言选择。
    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        detail
            .navigationTitle("")
            .modifier(WorkbenchToolToolbar(section: state.section))
        // Translation Host：常驻零尺寸视图，字幕翻译的 session 只能活在它的
        // translationTask 闭包里（SubtitleGen/TranslationHost.swift）。
        .background {
            if #available(macOS 15.0, *) { TranslationHostView() }
        }
        .onAppear {
            toolchain.resolveIfNeeded()
            // 启动时就是被文件唤起的，这时中转站里已经有东西了。
            routeStagedFiles()
            // 用户把主窗口关了之后，AI 要剪的时候靠它把窗口开回来（AIEditorPresenter）。
            AIEditorPresenter.openMainWindow = openWindow
        }
        // 拖到窗口空白处的文件按类型分流。拖到某个工具的列表上则由那个
        // 工具自己接（子视图的 onDrop 优先），直接进它的队列。
        .onDropOfFiles { urls in handleDrop(urls) }
        // AppDelegate 只能把文件放进中转站，切栏目得由视图来做。
        .onChange(of: compressHandoff.pendingVideos) { _, _ in routeStagedFiles() }
        .onChange(of: burnInHandoff.pendingVideos) { _, _ in routeStagedFiles() }
        .onChange(of: burnInHandoff.pendingSubtitles) { _, _ in routeStagedFiles() }
    }

    // MARK: - 当前工具

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .compress: CompressView()
        case .burnIn: BurnInView()
        // 主窗口剪辑页里永远是 primary 那一个工程（docs/architecture/open-projects.md）。
        case .videoEdit: VideoEditView(project: OpenProjects.shared.primary, host: .mainWindow)
        case .batchConvert: BatchConvertView()
        }
    }

    // MARK: - 动作

    /// 中转站里有文件就切到对应的栏目，工具自己会去取。
    private func routeStagedFiles() {
        if !burnInHandoff.pendingVideos.isEmpty || !burnInHandoff.pendingSubtitles.isEmpty {
            show(.burnIn)
        }
        if !compressHandoff.pendingVideos.isEmpty { show(.compress) }
    }

    /// 切栏目，并把主窗口拉到前面 —— 文件可能是从 Dock 图标或某个字幕窗口那边来的。
    private func show(_ section: ToolSection) {
        state.section = section
        openWindow(id: WindowID.main)
    }

    /// 拖进来的东西按类型分流：视频去压缩，视频加字幕去烧字幕，光是字幕就去
    /// 烧录页的字幕列里编辑。
    private func handleDrop(_ urls: [URL]) {
        let videos = urls.filter(MediaFileTypes.isVideo)
        let subtitles = urls.filter(MediaFileTypes.isSubtitle)

        if !videos.isEmpty {
            // 同时拖进视频和字幕，显然是想烧字幕。
            if !subtitles.isEmpty {
                BurnInHandoff.shared.stage(videos: videos, subtitles: subtitles)
                show(.burnIn)
            } else {
                CompressHandoff.shared.stage(videos: videos)
                show(.compress)
            }
            return
        }

        if !subtitles.isEmpty {
            BurnInHandoff.shared.stage(videos: [], subtitles: subtitles)
            show(.burnIn)
        }
    }
}

// MARK: - 文件中转站

/// 从 AppDelegate 或别的栏目把文件交给某个工具时用的中转站。
///
/// 工具视图只在自己那一栏显示时才存在，文件先放这儿，它出现时自己来取。
@MainActor
final class CompressHandoff: ObservableObject {
    static let shared = CompressHandoff()
    @Published var pendingVideos: [URL] = []

    private init() {}

    func stage(videos: [URL]) {
        pendingVideos.append(contentsOf: videos)
    }

    func take() -> [URL] {
        let result = pendingVideos
        pendingVideos.removeAll()
        return result
    }
}

@MainActor
final class BurnInHandoff: ObservableObject {
    static let shared = BurnInHandoff()
    @Published var pendingVideos: [URL] = []
    @Published var pendingSubtitles: [URL] = []

    private init() {}

    func stage(videos: [URL], subtitles: [URL]) {
        pendingVideos.append(contentsOf: videos)
        pendingSubtitles.append(contentsOf: subtitles)
    }

    func take() -> (videos: [URL], subtitles: [URL]) {
        let result = (pendingVideos, pendingSubtitles)
        pendingVideos.removeAll()
        pendingSubtitles.removeAll()
        return result
    }
}
