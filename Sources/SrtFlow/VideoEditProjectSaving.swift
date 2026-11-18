import AppKit
import Foundation

// MARK: - Saving a project: when, what is dirty, what the person is told
//
// What it does: the project's saves — the 2 s autosave, ⌘S, Save As, the flush before closing / switching / quitting —
// all through ProjectFileWriter, so the file is written off the main thread and nobody waits on a drive longer than a
// deadline. Dirty marks: `noteUnsavedChange` bumps the writer's counter; a write marks the project saved only when
// nothing changed since it was taken (`adoptWritten`). A drive that does not answer: a "not responding" notice, the project
// stays dirty and open, the write goes on, and a late success clears the notice; a late failure is said.
// Save As takes its new identity only when its write succeeded in time (docs/architecture/video-edit-project-file.md
// §5 item 6).
// The blocking saves (`saveNow`, `flushAutosave`, `saveDocument(as:)`) write on the caller's thread: **checks and dev
// hooks only**, never production code (checks/project-file-wiring.sh).
// What it doesn't: the write (ProjectFileWriter); opening, switching and closing (VideoEditProjectDocument.swift);
// quitting (ProjectQuit).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-project-save-blocks-on-slow-drive.md): every save ran
// `VideoEditProjectIO.save` on the main thread — a project on a sleeping or stuck external drive froze SkyCut, and Quit
// could hang for good.

/// What a save ended with, for the callers that wait.
enum ProjectSaveOutcome: Equatable {
    case saved
    /// Not written (the reason is in the project's notice); the file on disk is untouched.
    case failed
    /// The drive did not answer within the deadline: the write goes on, the project stays dirty.
    case notResponding
}

/// Whether a project may be closed, switched away from or quit (VideoEditProject.prepareToClose).
enum ProjectCloseReadiness: Equatable {
    case ready
    /// Stay as you are: a save failed, the person cancelled, a screen recording is running (the reason is in `notice`).
    case refused
    /// Its file is still being written to a drive that does not answer (Quit asks whether to wait).
    case waitingForDrive
}

extension VideoEditProject {
    /// Something the file holds changed: dirty, and the writer's counter moves (a write taken before it can't clear it).
    func noteUnsavedChange() {
        hasUnsavedChanges = true
        fileWriter.noteChange()
    }

    /// 改动后延迟落盘。拖动时间线时这个方法每帧都会被调到，靠取消重排实现防抖。
    func scheduleAutosave() {
        fileWriter.cancelAutosave()
        // 还没选过位置的未命名工程不偷偷建文件，等第一次 ⌘S 或导出。
        guard documentURL != nil else { return }
        fileWriter.autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveToFile()
        }
    }

    /// Writes the project file now, off the main thread; waits for the drive at most `deadline`.
    @discardableResult
    func saveToFile(deadline: TimeInterval = ProjectFileWriter.deadline) async -> ProjectSaveOutcome {
        // 定时自动保存、另存为、重链接回存都直接进这里，也要先落定输入。
        endPendingTextEditing()
        guard let request = writeRequest(.save) else { return .failed }
        switch await connectedWriter().write(request, deadline: deadline) {
        case .saved?: return .saved      // applied by `applyWrite` before this caller resumed
        case .failed?: return .failed    // said by `applyWrite`
        case nil: return notResponding(request.url)
        }
    }

    /// Writes soon without waiting (relinked or recovered media, a rebuilt motion cache).
    func saveSoon() {
        Task { await saveToFile() }
    }

    /// 把待写的改动落盘（⌘S、关窗、切工程、退出前都走一次），and waits for a write still on its way.
    /// **返回值必须被在意**：写不下去就不能继续做「关掉当前工程」这类破坏性操作。
    @discardableResult
    func flushToFile(deadline: TimeInterval = ProjectFileWriter.deadline) async -> ProjectSaveOutcome {
        // **必须在 hasUnsavedChanges 判定之前**：正在输入的那一格还没进模型，此刻工程可能「看起来是干净的」。
        endPendingTextEditing()
        fileWriter.cancelAutosave()
        guard let url = documentURL else { return .saved }
        if !hasUnsavedChanges {
            guard await fileWriter.waitUntilIdle(deadline: deadline) else { return notResponding(url) }
            if !hasUnsavedChanges { return .saved }
        }
        return await saveToFile(deadline: deadline)
    }

    /// ⌘S：立刻把挂着的自动保存写下去。没存过的工程先问存哪。
    func saveDocument() {
        if documentURL == nil {
            saveDocumentAs()
        } else {
            Task { await flushToFile() }
        }
    }

    func saveDocumentAs() {
        guard let url = chooseSaveLocation() else { return }
        Task { await saveAs(url) }
    }

    /// 存储为的面板。
    func chooseSaveLocation() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.srtFlowProject]
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = documentURL?.deletingLastPathComponent() ?? AIWorkspace.shared.startFolder(project: self)
        panel.canCreateDirectories = true
        panel.prompt = L10n("Save")
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // 用户把扩展名删了也照样存成工程文件（.skycut），不然下次双击打不开。
        if !VideoEditProjectFile.isProjectFile(url) {
            url = url.appendingPathExtension(VideoEditProjectFile.fileExtension)
        }
        return url
    }

    /// 存到 `url` 并从此以它为准（另存为、AI 新建 / 存工程共用这一份），off the main thread. 新身份只有写盘成功才作数：
    /// 写失败或盘不应答（目标盘只读、满了、睡着了）时工程原样留在原来的位置，不会卡在一个写不进去的 URL 上。
    @discardableResult
    func saveAs(_ url: URL, deadline: TimeInterval = ProjectFileWriter.deadline) async -> Bool {
        endPendingTextEditing()
        guard let request = writeRequest(.saveAs, to: url) else { return false }
        guard let result = await connectedWriter().write(request, deadline: deadline) else {
            _ = notResponding(url)
            return false
        }
        return adoptSaveAs(request, result)
    }

    /// 未命名工程的建议文件名：拿主轨第一段素材的名字，比 "Untitled" 好认。
    private var suggestedFileName: String {
        let base = state.mainClips.first?.name ?? L10n("Untitled")
        return "\(base).\(VideoEditProjectFile.fileExtension)"
    }

    /// 把「正在输入、还没进模型」的编辑落定。**所有读 `state` 去写盘的路口都要先调它。**
    ///
    /// 两件事：
    /// 1. 字幕文本草稿存在工程上，这里同步提交（见 `VideoEditSubtitleDraft.swift`）；
    /// 2. 其余输入框（时间码、Inspector 数值）的值仍活在各自的视图里，只能让窗口
    ///    结束编辑、逼它们走一遍失焦提交 —— 这一步是**尽力而为**：AppKit 让第一
    ///    响应者辞职是同步的，但 SwiftUI 把焦点变化转成 `onChange` 可能要等下一拍。
    ///    ⌘S 这类留在 App 里的路径无所谓（晚一拍也会被下一次自动保存捡走），
    ///    退出那条路仍有残留窗口。彻底解决要把那些输入框也改成工程级草稿，
    ///    那是独立于本次改动的一轮（这些输入框在本次改动之前就是这样）。
    func endPendingTextEditing() {
        commitSubtitleDraft()
        // 只让**这个工程的剪辑页**里的输入框辞职：后台工程自动存盘时去踢键窗口，会打断用户在别的窗口里正打的字（open-projects.md）。
        guard OpenProjects.shared.editorIsKey(self) else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Blocking saves: checks and dev hooks only

    /// Checks and dev hooks only: `saveToFile` on the caller's thread (it waits on the drive). Production code saves
    /// through `saveToFile` / `flushToFile` / `saveAs` (checks/project-file-wiring.sh).
    @discardableResult
    func saveNow() -> Bool {
        endPendingTextEditing()
        guard let request = writeRequest(.save) else { return false }
        if case .saved = connectedWriter().writeBlocking(request) { return true }
        return false
    }

    /// Checks and dev hooks only: `flushToFile` on the caller's thread.
    @discardableResult
    func flushAutosave() -> Bool {
        endPendingTextEditing()
        fileWriter.cancelAutosave()
        guard documentURL != nil, hasUnsavedChanges else { return true }
        return saveNow()
    }

    /// Checks and dev hooks only: `saveAs` on the caller's thread.
    @discardableResult
    func saveDocument(as url: URL) -> Bool {
        endPendingTextEditing()
        guard let request = writeRequest(.saveAs, to: url) else { return false }
        return adoptSaveAs(request, connectedWriter().writeBlocking(request))
    }

    // MARK: - Taking a snapshot, applying what the drive said

    private func writeRequest(_ kind: ProjectFileWriteRequest.Kind, to target: URL? = nil) -> ProjectFileWriteRequest? {
        guard let url = target ?? documentURL else { return nil }
        return ProjectFileWriteRequest(
            kind: kind, state: state, url: url, knownRecords: mediaRecords, rowHeights: rowHeights,
            documentBookmark: kind == .save ? documentBookmark : nil,
            revision: fileWriter.revision, generation: documentGeneration
        )
    }

    /// The writer tells this project how each write really ended (even after its caller stopped waiting).
    private func connectedWriter() -> ProjectFileWriter {
        if fileWriter.landed == nil {
            fileWriter.landed = { [weak self] request, result in self?.applyWrite(request, result) }
        }
        return fileWriter
    }

    /// A write of the project's own file ended. Save As is applied by its caller (`adoptSaveAs`), only when in time.
    private func applyWrite(_ request: ProjectFileWriteRequest, _ result: ProjectFileWriteResult) {
        // Another document since (opened / new), or Save As took the project elsewhere: not this file any more.
        guard request.kind == .save, isCurrentGeneration(request.generation), documentURL == request.url else { return }
        switch result {
        case .saved(let url, let records, let bookmark):
            adoptWritten(url, records: records, bookmark: bookmark, taken: request)
        case .failed(let reason):
            notice = String(format: L10n("Could not save the project: %@"), reason)
        }
    }

    private func adoptSaveAs(_ request: ProjectFileWriteRequest, _ result: ProjectFileWriteResult) -> Bool {
        guard isCurrentGeneration(request.generation) else { return false }
        switch result {
        case .saved(let url, let records, let bookmark):
            adoptWritten(url, records: records, bookmark: bookmark, taken: request)
            return true
        case .failed(let reason):
            notice = String(format: L10n("Could not save the project: %@"), reason)
            return false
        }
    }

    /// The file is written: where it is (a moved file followed), its media table, its bookmark, and the dirty mark —
    /// cleared only when nothing changed since the snapshot was taken.
    private func adoptWritten(_ url: URL, records: [String: MediaRecord], bookmark: Data?, taken request: ProjectFileWriteRequest) {
        if documentURL != url { documentURL = url }
        if let bookmark { documentBookmark = bookmark }
        // 定位表形成「读 → 存 → 读」的闭环；the main thread may have changed entries meanwhile (a relink): those win.
        var merged = records
        for (path, record) in mediaRecords where request.knownRecords[path] != record { merged[path] = record }
        mediaRecords = merged
        if fileWriter.revision == request.revision { hasUnsavedChanges = false }
        if let stuck = fileWriter.stuckNotice, notice == stuck { notice = nil }
        fileWriter.stuckNotice = nil
        RecentProjects.note(url)
    }

    /// The drive did not answer in time: said once, cleared when a write lands.
    private func notResponding(_ url: URL) -> ProjectSaveOutcome {
        let text = String(
            format: L10n("The drive with “%@” is not responding, so the project isn't saved yet. SkyCut keeps trying; keep the drive connected."),
            ProjectSaveText.driveName(of: url)
        )
        notice = text
        fileWriter.stuckNotice = text
        return .notResponding
    }
}

/// Names in what the person is told about a project's drive.
enum ProjectSaveText {
    /// "My Passport" for a file on `/Volumes/My Passport/…`, otherwise the folder the file is in.
    static func driveName(of url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
