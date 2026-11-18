import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 工程的打开、切换、关闭和素材重链接（保存和自动保存在 VideoEditProjectSaving.swift，写盘在 ProjectFileWriter：
/// off the main thread）。
///
/// 刻意**不**用 NSDocument：那套东西要一个工程一个窗口，跟「一个主窗口 + 侧边栏
/// 切工具」的结构对不上。但「最近打开」照样白嫖 `NSDocumentController` ——
/// File ▸ Open Recent 和 Dock 图标右键的列表都是它管的。
extension VideoEditProject {

    var projectName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? L10n("Untitled")
    }

    var isUntitled: Bool { documentURL == nil }

    // MARK: - 新建

    /// File ▸ New Project (and the AI closing the main window's project): the current one is written and asked about
    /// first, off the main thread (`prepareToClose`); a New / Open asked meanwhile wins.
    func startNewProject() async {
        openRequestToken &+= 1
        let token = openRequestToken
        guard await prepareToClose() == .ready, token == openRequestToken else { return }
        replaceWithNewProject()
    }

    /// Checks and dev hooks only (the save blocks on the drive): `startNewProject`.
    func newProject() {
        guard prepareToCloseDocument() else { return }
        replaceWithNewProject()
    }

    private func replaceWithNewProject() {
        closeCurrentDocument()
        replaceStateForDocument(MainMagnet.newTimeline(remembered: EditorToggles.read(.magnet)))
        // 和打开工程一样重排预览：上一个工程还在路上的那次重建就此作废，不然它落地时把旧工程的画面挂进新工程。
        scheduleRebuild()
    }

    // MARK: - 切换工程的把关（`prepareToClose`, `closesAtOnce`: ProjectClosing.swift）

    /// 清掉属于「上一个工程」的所有运行时状态。**只在 `prepareToCloseDocument`
    /// 放行之后调用。** 漏掉任何一条都会串味：播放器还在放上一条片子、⌘Z 能把
    /// 上一条的内容撤回来、后台导入把素材追加进新工程。
    private func closeCurrentDocument() {
        let closing = documentGeneration
        invalidateDocumentGeneration()
        fileWriter.cancelAutosave()
        clock.pause()
        unloadPreview()  // 卸片 + 引擎整个收掉（新工程没有声音的话图不该还开着）
        optimizedMedia.reset()  // 路上的转码作废；块留在磁盘上
        UpscaleActivity.shared.cancelAll(projectGeneration: closing)  // 这个工程在飞的 upscale 作废（排队中的替它向 Sky Studio 取消）；做完的文件留在磁盘上
        cancelLiveEdit()
        // 三类选择一起清。漏掉字幕 cue 的话，新工程一开就带着上一条工程的
        // cue ID —— 它在新轨上多半不存在，预览要么画悬空拖框，要么撞上新轨
        // 里恰好同 ID 的条目（PR#22 复审 P2）。
        clearSelection()
        missingMedia = []
        notice = nil
        documentURL = nil
        documentBookmark = nil
        mediaRecords = [:]
        // 行高是上一份工程的（键是那边的轨道 UUID），留着只会让新工程拿着一堆
        // 对不上的条目。新工程的每条轨从默认高度起步。
        replaceRowHeightsForDocument(TimelineRowHeights())
        hasUnsavedChanges = false
        effectiveUndoManager?.removeAllActions()
    }

    // MARK: - 打开

    func promptOpenProject() {
        let request = FileWindowRequest(
            kind: .files(types: [.srtFlowProject], multiple: false), start: AIWorkspace.shared.startFolder(project: self),
            prompt: L10n("Open")
        )
        SystemFileWindows.shared.open(request) { [weak self] urls in   // not modal (SystemFileWindows)
            guard let self, let url = urls.first else { return }
            Task { await OpenProjects.shared.userOpen(url, from: self) }   // AI 正在剪这一个：开到新窗口里
        }
    }

    /// 打开工程。
    ///
    /// 顺序很讲究：**先把目标读出来验明正身，再动手里这条**。反过来的话，目标
    /// 文件损坏时当前工程已经被关掉了 —— 画面还在，但 documentURL、撤销栈、脏
    /// 标记全没了，后面的编辑再也不会自动保存。
    func openProject(at url: URL) async {
        // 「重新打开」当前工程 = 把改动落定，不走载入。真走载入的话顺序是
        // 读到磁盘上的旧状态 → flush 把新状态写下去 → 再拿旧状态盖回内存 ——
        // 下一次编辑就会把新状态从磁盘上也抹掉。
        if let current = documentURL,
           current.standardizedFileURL.resolvingSymlinksInPath().path
               == url.standardizedFileURL.resolvingSymlinksInPath().path {
            await flushToFile()
            return
        }

        // 同一个文件只开一份：它已经在别的工程窗口里开着，就把那个窗口摆出来（两份同时自动存盘会互相盖掉）。
        if let elsewhere = OpenProjects.shared.project(openAt: url), elsewhere !== self { return OpenProjects.shared.reveal(elsewhere) }
        openRequestToken &+= 1
        let token = openRequestToken

        let result: VideoEditProjectIO.LoadResult
        do {
            // 载入要遍历素材、可能还要搜目录，别占着主线程。
            result = try await Task.detached(priority: .userInitiated) {
                try VideoEditProjectIO.load(from: url)
            }.value
        } catch {
            guard token == openRequestToken else { return }
            notice = error.localizedDescription
            // 文件是坏的或者版本太新 —— 那也还是个存在的文件，别从最近列表里踢掉；
            // 只有彻底找不到了才清理。
            if !FileManager.default.fileExists(atPath: url.path) {
                RecentProjects.forget(url)
            }
            return
        }

        // 载入期间用户又点开了别的工程：这份结果过期了，别拿它顶掉人家。
        guard token == openRequestToken else { return }
        guard await prepareToClose() == .ready else { return }
        // prepareToClose 等过盘、可能弹过模态框（跑嵌套 runloop），再验一次。
        guard token == openRequestToken else { return }
        closeCurrentDocument()

        replaceStateForDocument(result.timeline)
        // 行高跟着工程走（与时间线平级的一段），和 state 一样算「载入」不算改动。
        replaceRowHeightsForDocument(result.rowHeights)
        documentURL = url
        documentBookmark = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        mediaRecords = result.records
        missingMedia = result.missingMedia
        RecentProjects.note(url)
        scheduleRebuild()

        // 丢失的素材由预览区顶上的 MissingMediaBar 长期显示（那里还带重链接入口），
        // 不再往 notice 里塞一遍 —— 同一句话说两遍。

        // 素材是靠书签/相对路径找回来的：工程里记的路径已经过时，趁热存一次，
        // 下次打开就能走「原地命中」的快路径。
        if result.didRelink {
            noteUnsavedChange()
            saveSoon()
        } else {
            hasUnsavedChanges = false
        }

        if !result.stillsToRegenerate.isEmpty {
            let generation = documentGeneration
            trackImportTask(Task {
                await regenerateStills(result.stillsToRegenerate, generation: generation)
            })
        }

        // 音频库素材的最后一层：本地缓存里也没有，就去 R2 按 id 重新拉。
        // 放在最后、异步跑 —— 它要走网络，不该拖着工程打不开。
        WebMotionRecovery.start(for: self)
        recoverRemoteLibraryMedia()
    }

    /// 把「有 remoteKey、但本地文件不在了」的素材从音频库重新下回来。
    ///
    /// 这是 `remoteKey` 存在的**全部理由**：用户清过缓存、换了机器、工程发给
    /// 别人 —— 路径全都对不上，但 id 还在。没有这一步，v18 保住的就只是一个
    /// 没人读的字段，用户看到的还是「素材丢失」加一个指向缓存目录的死路径。
    ///
    /// 静默进行，不弹任何东西：成功的话用户根本不该察觉；失败的话那几条本来
    /// 就已经在 `missingMedia` 里，重链接条会照常显示。
    private func recoverRemoteLibraryMedia() {
        let wanted = state.allClips.compactMap { clip -> String? in
            guard let key = clip.remoteKey,
                  !FileManager.default.fileExists(atPath: clip.sourceURL.path)
            else { return nil }
            return key
        }
        guard !wanted.isEmpty else { return }

        let generation = documentGeneration
        trackImportTask(Task { [weak self] in
            guard let self else { return }
            // 两个库（音乐、音效）的清单都等到手（它们可能正好在拉）。拉不到就算了 —— 那几条会留在
            // missingMedia 里，用户还有手动重链接那条路。
            let loaded = await AudioLibraryLookup.load(AudioLibraryStore.all)
            if Task.isCancelled { return }
            let byID = Dictionary(loaded.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for key in Set(wanted) {
                guard isCurrentGeneration(generation), !Task.isCancelled else { return }
                guard let item = byID[key] else { continue }
                guard let url = try? await AudioLibraryCache.shared.download(item) else { continue }
                // 下载期间用户可能已经换了工程：这份素材是上一个工程的，别往新的里塞
                //（同 addVideos 那条代号守卫）。
                guard isCurrentGeneration(generation) else { return }
                relinkRecoveredRemoteMedia(key: key, to: url)
            }
        })
    }

    /// 把某条 remoteKey 对应的所有片段指到新下好的文件上，并把它移出丢失清单。
    private func relinkRecoveredRemoteMedia(key: String, to url: URL) {
        let stale = Set(
            state.allClips.filter { $0.remoteKey == key && $0.sourceURL != url }.map(\.sourceURL)
        )
        guard !stale.isEmpty else { return }
        perform { timeline in
            for old in stale { timeline.replaceMedia(old, with: url) }
        }
        missingMedia.removeAll { stale.contains($0) }
        // 路径变了立刻回存，跟打开工程时 didRelink 的处理一致。
        noteUnsavedChange()
        saveSoon()
    }

    // MARK: - 图片段的静帧

    /// 静帧缓存被系统清掉了就重转一遍。图片本身还在工程里记着，用户无感。Going back to a saved version uses it too (ProjectVersionStore).
    func regenerateStills(_ requests: [StillRegeneration], generation: Int) async {
        guard let ffmpeg = await awaitVideoEngine() else {
            guard isCurrentGeneration(generation) else { return }
            notice = L10n("The video engine isn’t available, so image clips couldn’t be prepared.")
            return
        }
        for request in requests {
            let image = request.image
            guard isCurrentGeneration(generation) else { return }
            guard let still = try? await StillImageClipFactory.stillVideo(
                for: image,
                ffmpeg: ffmpeg,
                nativeResolution: request.nativeResolution
            ) else { continue }
            guard isCurrentGeneration(generation) else { return }
            applyDocumentRepair { state in
                // 只认同政策的段，理由见 `attachStill`（纯值函数，自检里有回归）。
                VideoEditProjectIO.attachStill(
                    still,
                    forImage: image,
                    nativeResolution: request.nativeResolution,
                    in: &state
                )
            }
        }
    }

    /// 等 ffmpeg 就位。
    ///
    /// **不能直接取 `runtime`**：冷启动双击工程时，`application(_:open:)` 跑在
    /// 窗口出现之前，而 `resolveIfNeeded()` 要等 `onAppear` 才被调到 ——
    /// 那一刻 `runtime` 必然是 nil。以前在这里直接 return，图片段就永久停在
    /// 「待转换」，导出时还会被静默排除，图片从成片里凭空消失。
    private func awaitVideoEngine() async -> URL? {
        let toolchain = MediaToolchain.shared
        if let url = toolchain.runtime?.url { return url }
        toolchain.resolveIfNeeded()
        // 解析是查几个固定路径 + 跑一次 `ffmpeg -version`，20 秒足够有余。
        for _ in 0..<130 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return nil }
            if let url = toolchain.runtime?.url { return url }
            // 解析结束了还是没有，就是真没有，别干等。
            if !toolchain.isResolving { return nil }
        }
        return toolchain.runtime?.url
    }

    // MARK: - Finder

    func revealInFinder() {
        guard let documentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    // MARK: - 素材重链接

    /// 让用户指认一个丢失的素材。指完之后，**同一个目录下**其他丢失的素材按
    /// 文件名自动配上 —— 素材通常整批一起搬，一次别让人点十遍。
    func promptRelink(_ missing: URL) {
        let generation = documentGeneration
        FilePicker.chooseFiles(
            types: [], allowsMultiple: false, prompt: L10n("Relink"),
            message: String(format: L10n("Where is “%@”?"), missing.lastPathComponent)
        ) { [weak self] urls in
            // Not modal: the project may have been switched, or the file found again, while the window was open.
            guard let self, let replacement = urls.first, self.isCurrentGeneration(generation),
                  self.missingMedia.contains(missing) else { return }
            self.relink(missing, to: replacement)
        }
    }

    private func relink(_ missing: URL, to replacement: URL) {
        let directory = replacement.deletingLastPathComponent()
        var relinked: [URL: URL] = [missing: replacement]
        for other in missingMedia where other != missing {
            let candidate = directory.appendingPathComponent(other.lastPathComponent)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relinked[other] = candidate
            }
        }

        var pendingStills: [StillRegeneration] = []
        applyDocumentRepair { state in
            for (old, new) in relinked { state.replaceMedia(old, with: new) }
            // 重链接的要是图片，换掉的只是 `stillImageURL`，`sourceURL` 还指着
            // 那份多半已经不存在的静帧缓存。这里重新对一次，对不上的报出来重转。
            pendingStills = VideoEditProjectIO.refreshStillClips(in: &state)
        }
        missingMedia.removeAll { relinked[$0] != nil }

        // 定位表的键要跟着换成新路径，否则下次存盘按旧路径找不到旧记录，
        // 刚建立的书签又会丢。
        let projectDirectory = documentURL?.deletingLastPathComponent()
        for (old, new) in relinked {
            let previous = mediaRecords.removeValue(forKey: old.path)
            mediaRecords[new.path] = MediaRecord(
                url: new,
                projectDirectory: projectDirectory,
                previous: previous
            )
        }

        // 路径变了得赶紧记下来，别等下次打开又要重找一遍。
        noteUnsavedChange()
        saveSoon()

        if !pendingStills.isEmpty {
            let generation = documentGeneration
            trackImportTask(Task {
                await regenerateStills(pendingStills, generation: generation)
            })
        }
    }

    // MARK: - 运行中的素材核对

    /// 工程开着的时候素材也会在访达里被改名、挪走。以前只有**打开工程**才跑
    /// 四层线索，运行中失踪只会让预览重建时静默跳过那段 —— 黑屏零提示，轨道
    /// 缩略图还是缓存的旧画面，看着一切正常。这里把同一套线索在运行中也跑：
    /// 跟得上的当场改引用（轨道块名字随 `sourceURL` 现算，立刻显示新名字），
    /// 跟不上的进 `missingMedia` 亮出重链接条。App 激活和每次预览重建各触发
    /// 一次；素材都在原地时就是每素材一次 fileExists 的开销。
    func revalidateMediaLocations() {
        WebMotionRecovery.start(for: self)
        guard mediaRevalidateTask == nil else { return }
        guard !state.isEmpty else {
            if !missingMedia.isEmpty { missingMedia = [] }
            return
        }
        let urls = state.mediaURLs
        let records = mediaRecords
        let projectDirectory = documentURL?.deletingLastPathComponent()
        let generation = documentGeneration
        mediaRevalidateTask = Task { [weak self] in
            // 四层线索可能要翻目录，跟 openProject 一样别占主线程。
            let outcome = await Task.detached(priority: .utility) {
                VideoEditProjectIO.relocateMedia(
                    urls: urls,
                    records: records,
                    projectDirectory: projectDirectory
                )
            }.value
            guard let self else { return }
            // 先放开单飞再落账：落账会触发重建 → 重建又触发核对，那次要能起飞，
            // 它会核出「全部原地命中」从而收敛，不会循环。
            self.mediaRevalidateTask = nil
            guard self.isCurrentGeneration(generation) else { return }
            self.applyMediaRelocation(moved: outcome.moved, missing: outcome.missing)
        }
    }

    /// 把核对结果落回工程。**await 回来的世界可能已经变了**（编辑没停、
    /// 甚至换了素材）：只对此刻仍被时间线引用的路径动手。
    private func applyMediaRelocation(moved: [URL: URL], missing: [URL]) {
        let current = Set(state.mediaURLs)
        let applicable = moved.filter { current.contains($0.key) }

        if !applicable.isEmpty {
            var pendingStills: [StillRegeneration] = []
            applyDocumentRepair { state in
                for (old, new) in applicable { state.replaceMedia(old, with: new) }
                // 找回来的要是图片，静帧缓存要重新对一次（同 promptRelink）。
                pendingStills = VideoEditProjectIO.refreshStillClips(in: &state)
            }
            // 定位表跟 promptRelink 同一套账：键换成新路径，旧记录当兜底。
            let projectDirectory = documentURL?.deletingLastPathComponent()
            for (old, new) in applicable {
                let previous = mediaRecords.removeValue(forKey: old.path)
                mediaRecords[new.path] = MediaRecord(
                    url: new,
                    projectDirectory: projectDirectory,
                    previous: previous
                )
            }
            // 路径变了立刻回存，跟打开工程时 didRelink 的处理一致。
            if documentURL != nil {
                noteUnsavedChange()
                saveSoon()
            }
            if !pendingStills.isEmpty {
                let generation = documentGeneration
                trackImportTask(Task {
                    await regenerateStills(pendingStills, generation: generation)
                })
            }
        }

        // 丢失名单以本次核对为准：被挪回原位/找回来的自动消条。
        let stillMissing = missing.filter { current.contains($0) }
        if missingMedia != stillMissing { missingMedia = stillMissing }
    }
}
