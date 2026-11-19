import AppKit
import Foundation

// MARK: - Whether a project may be closed, switched away from or quit
//
// What it does: the one gate before a project's document goes away — New / Open / Open Recent, the project window's close
// button, the AI's close_project, Quit (ProjectQuit) all ask `prepareToClose`. A named project is written (off the main
// thread, ProjectFileWriter) until its file holds everything the project has *now*: an edit made while a write was out is
// written too, within the same deadline. An untitled project with content asks Save… / Discard / Cancel, and "Save…" opens
// the macOS save window (not modal). Every answer that comes after a wait — the drive, the save window, an alert — counts
// only if the project is still the document this close started with: a New / Open asked meanwhile may have replaced it.
// What it doesn't: the write and the dirty marks (ProjectFileWriter, VideoEditProjectSaving.swift); what happens once a
// project is ready (VideoEditProjectDocument.swift replaces the document, OpenProjects closes it, ProjectQuit replies).
//
// Why (2026-11-19, docs/bugfixes/2026-11-19-close-trusts-a-stale-save.md): "ready" used to mean "the write I asked for
// landed". An edit made during that write stayed unsaved in memory, and New Project, closing the window or Quit then threw
// it away; and a save window answered after another project had been opened in the same window wrote that project to the
// place chosen for the first one. Rules: docs/architecture/video-edit-project-file.md §5.

/// Whether a project may be closed, switched away from or quit (VideoEditProject.prepareToClose).
enum ProjectCloseReadiness: Equatable {
    /// The same document, nothing unsaved, nothing being written — at the moment of this answer. Callers act on it at
    /// once, without another wait.
    case ready
    /// Stay as you are: a save failed, the person cancelled, a screen recording is running, or the document was replaced
    /// while this close waited (the reason is in `notice` when there is one).
    case refused
    /// Its file is still being written to a drive that does not answer (Quit asks whether to wait).
    case waitingForDrive
}

/// What closing a project asks the person (a seam: the checks answer for them).
@MainActor
enum ProjectCloseQuestions {
    enum UntitledChoice { case save, discard, cancel }

    /// "Save this project before closing it?" for a never-saved project with content (an in-process alert).
    static var untitled: @MainActor (VideoEditProject) -> UntitledChoice = { _ in askAboutUntitled() }
    /// Where to save it: the macOS save window (not modal). nil when nothing was chosen.
    static var saveLocation: @MainActor (VideoEditProject) async -> URL? = { await $0.chooseSaveLocation() }

    private static func askAboutUntitled() -> UntitledChoice {
        let alert = NSAlert()
        alert.messageText = L10n("Save this project before closing it?")
        alert.informativeText = L10n("It has never been saved, so the edits will be lost.")
        alert.addButton(withTitle: L10n("Save…"))
        alert.addButton(withTitle: L10n("Discard"))
        alert.addButton(withTitle: L10n("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}

extension VideoEditProject {
    /// 关掉当前工程之前先把改动落定。**不是 `.ready` 表示调用方必须中止切换。**
    ///
    /// 以前这里是无条件 `flushAutosave()` 然后直接关。磁盘满、权限变了、外接盘
    /// 被拔掉的时候，保存是失败的，而当前工程照样被关掉 —— 未保存的编辑就这么
    /// 没了。切工程必须是要么整个成功、要么原地不动。
    ///
    /// New / Open / Open Recent、关工程窗口、AI 的 close_project、退出 App（ProjectQuit）都走这里。The file is written off
    /// the main thread and waited for at most `deadline` in all: a drive that does not answer is `.waitingForDrive` (the
    /// project stays open and dirty; Quit asks whether to wait), never a main thread waiting on it. `.ready` is decided at the
    /// moment of answering — the same document as when this was asked, nothing unsaved, nothing being written — so a caller
    /// that acts on it at once never throws away an edit made during the wait.
    func prepareToClose(deadline: TimeInterval = ProjectFileWriter.deadline) async -> ProjectCloseReadiness {
        // 手里还攥着没提交的输入就先落定：这条路是 New / Open / Open Recent /
        // 退出的必经之路，而它下面每一步都是「先读 state 写盘，再销毁视图」——
        // 漏掉这一句，用户「打完字直接退出」丢的就是刚打的那句（复审 P1）。
        endPendingTextEditing()
        if refusesWhileRecording() { return .refused }
        // The document this close is about. The save window is not modal and the drive takes its time: a New / Open asked
        // meanwhile may have replaced it, and nothing decided for it may then be done to the one that replaced it.
        let generation = documentGeneration
        if documentURL == nil {
            // 从没存过、但已经剪了东西：直接扔掉就是数据丢失，得问一句。
            guard !state.isEmpty else { return .ready }
            switch ProjectCloseQuestions.untitled(self) {
            case .discard: return stillClosing(generation) ? .ready : .refused
            case .cancel: return .refused
            case .save:
                // 用户在存盘面板上点了取消，或者写盘失败 —— 都不能继续往下切。An answer that comes after another document
                // replaced this one is dropped before anything is written: it would put that document in this one's place.
                guard let url = await ProjectCloseQuestions.saveLocation(self), stillClosing(generation),
                      await saveAs(url) else { return .refused }
            }
        }
        return await writeForClosing(generation, deadline: deadline)
    }

    /// Nothing to write, nothing being written, nothing to ask: closing this project needs no wait at all.
    func closesAtOnce() -> Bool {
        endPendingTextEditing()
        if #available(macOS 15.0, *), ScreenRecordingCoordinator.shared.locksProjectSwitching { return false }
        return !fileWriter.isBusy && (documentURL == nil ? state.isEmpty : !hasUnsavedChanges)
    }

    /// Checks and dev hooks only (the save blocks on the drive): `prepareToClose`.
    func prepareToCloseDocument() -> Bool {
        endPendingTextEditing()
        if refusesWhileRecording() { return false }
        if documentURL != nil { return flushAutosave() }
        guard !state.isEmpty else { return true }
        switch ProjectCloseQuestions.untitled(self) {
        case .save: return false   // the save window is not modal: only `prepareToClose` can wait for it
        case .discard: return true
        case .cancel: return false
        }
    }

    /// Writes until the file holds everything the project has now, within one `deadline` for all of it. A write that lands
    /// says only that *its* snapshot is on the drive: an edit made while it was out (typing, an AI tool call) keeps the
    /// project dirty (`adoptWritten`), and that newer state is written too before the answer is `.ready`.
    private func writeForClosing(_ generation: Int, deadline: TimeInterval) async -> ProjectCloseReadiness {
        let end = ProcessInfo.processInfo.systemUptime + deadline
        while true {
            // 写盘失败时已经把原因写进 notice 了，这里别再覆盖。
            switch await flushToFile(deadline: max(0, end - ProcessInfo.processInfo.systemUptime)) {
            case .failed: return .refused
            case .notResponding: return .waitingForDrive
            case .saved:
                guard stillClosing(generation) else { return .refused }
                if !hasUnsavedChanges, !fileWriter.isBusy { return .ready }
                // Changed while it was being written: the newest state is written too, in what is left of the deadline.
                if ProcessInfo.processInfo.systemUptime >= end { return .waitingForDrive }
            }
        }
    }

    /// After a wait: still the document this close started with, and no screen recording has locked switching since.
    private func stillClosing(_ generation: Int) -> Bool {
        isCurrentGeneration(generation) && !refusesWhileRecording()
    }

    /// 录制期间禁止切换工程。**挂在这里而不是按钮的 disabled 上** ——
    /// 计划 §11.3 要求「实际执行入口」再校验一次：New / Open / Open Recent /
    /// Finder 外部打开 / 退出全都经过这个方法，菜单置灰挡不住这些路径。
    /// `.importing` / `.partialRecovery` 也算录制中：文件写完了但入轨事务
    /// 没提交、或用户还没处置 partial，此时切工程素材会进错工程。
    private func refusesWhileRecording() -> Bool {
        guard #available(macOS 15.0, *), ScreenRecordingCoordinator.shared.locksProjectSwitching else { return false }
        notice = L10n("Stop the screen recording first.")
        return true
    }
}
