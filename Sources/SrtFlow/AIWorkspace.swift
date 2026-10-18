import Foundation
import SrtFlowMCPKit

// MARK: - AI 能用哪些文件、新文件放哪、什么时候要用户点头
//
// 管什么：用户点名的文件夹（open_folder 登记，里面每一层都能用）、AI 做出来的文件放哪
// （起点下面的 `SrtFlow/` 子文件夹，按导出 / 工程分开；起点的规则在 DefaultFolder）、确认令牌。
// 产品口径见 docs/plans/2026-09-27-mcp.md 第 21–25 条。
// 不管什么：文件夹里有什么（AIMediaScan）、工具怎么做。
//
// **只有删文件才问**（方案第 34 条，2026-09-28 用户拍板）：删进废纸篓先问；读点名文件夹以外的文件问一次，
// 同意了就记住那个文件夹、以后不再问（AIReadGrants）；从不覆盖（撞名加编号），所以也不问；开着的工程没存过就先存下来再换，
// 不问也不丢。时间线上的改动一律不问 —— 有 ⌘Z 和「撤销这一轮」兜底。问法是结果里回 needs_confirmation + 令牌，
// AI 把问题转述给用户，用户同意之后带着令牌再调一次（令牌的规矩 —— 绑着那件事、一次有效、三十分钟、同一件事回同一张、
// 拒绝说原因 —— 在 AIConfirmations.swift）。

@MainActor
final class AIWorkspace {
    static let shared = AIWorkspace()

    /// 用户点名过的文件夹，最近的在最后（全 App 一份：读的时候哪些不用再问，`allowsReading`）。
    private(set) var folders: [URL] = []
    /// 每个会话最后点名的那个（几个会话 / 子代理各 open_folder 一个文件夹时各是各的，方案 D 节）。
    private var sessionFolders: [String: URL] = [:]
    /// 每个工程的工作区文件夹（短 id → 打开 / 新建它时这个会话点名的那个）。
    private var projectFolders: [String: URL] = [:]

    /// 「打开的文件夹」：相对路径按它解析、结果里的路径按它写短、新文件放它下面。AI 的调用里按这一次调用是谁**现查**
    /// （`AICallContext`：这个工程的 → 这个会话的；调用当中 open_folder 换了也跟着换），界面上（打开面板、导出面板第一次用的位置）
    /// 是最后点名的那个。
    var current: URL? {
        if let context = AICallContext.current { return folder(project: context.project, session: context.session) }
        return folders.last
    }

    private init() {}

    func register(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        folders.removeAll { $0.path == standardized.path }
        folders.append(standardized)
        if let session = AICallContext.current?.session { sessionFolders[session] = standardized }
    }

    /// 一个碰工程的调用的工作区文件夹：这个工程打开 / 新建时记下的，没有就是这个会话最后点名的。
    func folder(project: String?, session: String?) -> URL? {
        project.flatMap { projectFolders[$0] } ?? session.flatMap { sessionFolders[$0] }
    }

    /// 这个会话开 / 建了一个工程：它的工作区文件夹就是这个会话此刻点名的那个（之后别的子代理再 open_folder 也不串到它身上）。
    func noteProjectOpened(_ project: String, session: String?) {
        guard let session, let folder = sessionFolders[session] else { return }
        projectFolders[project] = folder
    }

    /// 相对路径按「打开的文件夹」解析；AI 的调用里先按这个工程的、那里没有再看这个会话后来点名的（规矩在 AIPathResolution）。
    func resolve(_ path: String) -> URL {
        let sessionFolder = AICallContext.current?.session.flatMap { sessionFolders[$0] }
        return AIPathResolution.resolve(path, preferred: current, fallback: sessionFolder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func display(_ url: URL) -> String {
        AIFormat.path(url, relativeTo: current)
    }

    /// 不用再问就能读的文件：在点名的文件夹里、在工程的家里（DefaultFolder.home）、在用户同意过的地方（AIReadGrants）、
    /// 或者工程里本来就在用。
    func allowsReading(_ url: URL, project: VideoEditProject) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = folders.map(\.path) + [projectHome(project)?.standardizedFileURL.path].compactMap { $0 }
        if roots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        if AIReadGrants.shared.covers(url) { return true }
        return project.state.mediaURLs.contains { $0.standardizedFileURL.path == path }
    }

    /// 读点名文件夹以外的文件要用户点头：都能读就 nil，否则回 needs_confirmation。令牌绑着这一组文件
    /// （换了文件拿它来不认）；点过头就记住它们的文件夹，以后不再问。`verb` 写进问题里：「read」「look at」「listen to」。
    func confirmReading(
        _ urls: [URL], verb: String, args: AIToolArguments, project: VideoEditProject
    ) throws -> AIToolResult? {
        let outside = Set(urls.map(\.standardizedFileURL).filter { !allowsReading($0, project: project) }.map(\.path)).sorted()
        guard !outside.isEmpty else { return nil }
        let action = "read:" + outside.joined(separator: "|")
        let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: action)
        if redemption == .accepted {
            AIReadGrants.shared.remember(outside.map { URL(fileURLWithPath: $0) })
            return nil
        }
        var names = outside.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if outside.count > 5 { names += " and \(outside.count - 5) more" }
        let which = outside.count == 1 ? "which is" : "which are"
        return AIConfirmations.shared.ask(
            "SkyCut needs to \(verb) \(names), \(which) outside the folder you opened. Allow it? "
                + "SkyCut then remembers that folder and does not ask again for files in it.",
            action: action, refused: redemption.refusal
        )
    }

    /// 新东西默认从哪开始：点名的文件夹 → 工程的家 → 「下载」（规则在 DefaultFolder）。
    /// 手动的「打开工程」「存储为」和导出面板第一次用的位置也从这里拿。
    func startFolder(project: VideoEditProject) -> URL {
        DefaultFolder.start(
            named: current,
            projectHome: projectHome(project),
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            userHome: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// AI 做出来的文件放哪：`<起点>/SrtFlow/<导出|工程|配音|音效|生成|录屏>`。文件夹名跟着 App 的语言。
    func outputFolder(_ kind: Output, project: VideoEditProject) -> URL {
        startFolder(project: project)
            .appendingPathComponent(DefaultFolder.aiFolderName, isDirectory: true)
            .appendingPathComponent(kind.folderName, isDirectory: true)
    }

    private func projectHome(_ project: VideoEditProject) -> URL? {
        project.documentURL.map { DefaultFolder.home(ofProjectFile: $0, projectFolderNames: Self.projectFolderNames) }
    }

    /// 「工程」子文件夹在每种界面语言里的名字：切过语言，之前存的工程也认得出自己的家。
    private static let projectFolderNames = Set(
        AppLanguage.allCases.map { $0.bundle.localizedString(forKey: "Projects", value: "Projects", table: nil) }
    )

    enum Output {
        case exports, projects, voiceovers, soundEffects, generated, recordings

        var folderName: String {
            switch self {
            case .exports: return L10n("Exports")
            case .projects: return L10n("Projects")
            case .voiceovers: return L10n("Voiceovers")
            case .soundEffects: return L10n("Sound Effects")
            case .generated: return L10n("Generated")
            case .recordings: return L10n("Screen Recordings")
            }
        }
    }
}
