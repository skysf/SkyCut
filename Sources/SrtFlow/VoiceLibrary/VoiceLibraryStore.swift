import Foundation

// MARK: - 界面上的声音库：我的声音、预设名单，和改名 / 删除
//
// 管什么（SkyCut 声音方案 5.1、5.2）：设置里「声音库」一节、声音选择器、新建 / 设计声音的对话框订阅的那一份：
// - 取：Key 只静默读（打开设置不弹钥匙串框；没存、要授权各是一种样子）、`/models` 的预设和授权那一句（SkyStudioCatalogCache，10 分钟
//   一份）、`GET /voices`。声音库用不了（503 `voice_library_unavailable`）是单独一种样子：预设照样有，新建 / 设计 / 改名 / 删除都灰着。
// - 改名（`PATCH`）、删除（SkyStudioVoiceDeletion：存储一时不可用再发一次；删了立刻从列表消失）。
// - 试听我的声音：临时链接（1 小时）没过期就用手里的，过期了重取那一个声音（`GET /voices/{id}`），**只留在内存里、不存盘**。
// - 听「声音库变了」（SkyStudioVoiceLibraryChange：AI 建的、删的、设计好的也算）：有人看过就再取一遍。
// 请求只经 SkyStudioAPI，规则都是声音 PR 6 那一套（AI 的 list_voices / manage_voices 用的同一份接口和删除）。
// 只有声音库的几个视图订阅它；不读工程、不订阅播放器的时钟。
// 不管什么：建声音（NewVoiceModel）、设计（DesignVoiceModel）、试听怎么放（VoiceAudition）、话怎么说（VoiceLibraryText）。

@MainActor
final class VoiceLibraryStore: ObservableObject {
    static let shared = VoiceLibraryStore()

    enum Phase: Equatable {
        /// 还没人看过。
        case idle
        case loading
        case ready
        case noKey
        /// 钥匙串要用户点「允许…」（设置 → Sky Studio）。
        case needsPermission
        /// 服务器那边的声音库暂时用不了：预设照常。
        case unavailable
        /// 别的毛病（断网、Key 不对…）：那一句（已经照界面语言写好）。
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var voices: [SkyStudioVoice] = []
    /// `/models` 的预设、授权那一句；还没读到是 nil。
    @Published private(set) var catalog: SkyStudioVoiceCatalog?
    /// 正在改名 / 删除的那几个（那一行的按钮先灰着）。
    @Published private(set) var working: Set<String> = []
    /// 正在设计的声音的名字（做完进列表；失败了从这里拿掉并说一句）。
    @Published private(set) var designing: [String] = []
    /// 上一个动作出的错（照界面语言）；下一次成功的动作清掉。
    @Published var notice: String?

    /// 回归换成假的：读 Key、发请求。
    var readKey: @MainActor () async -> Result<String, SkyStudioJobKey.Problem> = { await SkyStudioJobKey.key(.silent) }
    var api = SkyStudioAPI()

    private var key: String?
    private var round = 0
    /// 正在取的有几遍（「声音库变了」和界面自己要的可能叠在一起；后起的那一遍说了算）。回归等它归零再看结果。
    private(set) var refreshing = 0
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: SkyStudioVoiceLibraryChange.name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase != .idle else { return }
                await self.refresh()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 新建、设计、加录音、改名、删除现在能不能做（声音库取到了）。
    var canEdit: Bool { phase == .ready }

    /// 建声音时要勾的那一句（读不到就建不了）。
    var consentStatement: SkyStudioVoiceConsentStatement? { catalog?.perRecordingConsent }

    /// 取一遍。手里有旧的就先照旧显示，取到了再换。
    func refresh() async {
        round += 1
        let mine = round
        refreshing += 1
        defer { refreshing -= 1 }
        if phase == .idle { phase = .loading }
        let found: String
        switch await readKey() {
        case .success(let value): found = value
        case .failure(let problem):
            guard mine == round else { return }
            key = nil
            set(voices: [])
            switch problem {
            case .noKey: set(.noKey)
            case .needsPermission: set(.needsPermission)
            // 钥匙串只是慢、没弹框：「暂时用不了、稍后再试」，不叫用户去点 Allow…（迟到的 Key 会缓存，下次刷新就有）。
            case .keychainSlow: set(.unavailable)
            case .keychain: set(.failed(VoiceLibraryText.keyProblem(problem)))
            }
            return
        }
        key = found
        // 预设和授权那一句：声音库用不了也要有（预设照样能浏览、试听）。
        let models = try? await SkyStudioCatalogCache.shared.catalog(key: found, api: api).voices
        guard mine == round else { return }
        if let models, models != catalog { catalog = models }
        do {
            let page = try await api.voices(key: found)
            guard mine == round else { return }
            set(voices: page.voices)
            set(.ready)
        } catch is CancellationError {
            return
        } catch {
            guard mine == round else { return }
            if SkyStudioVoiceLibraryErrors.isUnavailable(error) {
                set(voices: [])
                set(.unavailable)
            } else {
                set(.failed(VoiceLibraryText.message(error)))
            }
        }
    }

    /// 改名；成了回 true。
    func rename(_ voice: SkyStudioVoice, to name: String) async -> Bool {
        guard let key, canEdit, !working.contains(voice.id) else { return false }
        working.insert(voice.id)
        defer { working.remove(voice.id) }
        do {
            adopt(try await api.renameVoice(voice.id, to: name, key: key))
            notice = nil
            SkyStudioVoiceLibraryChange.post()
            return true
        } catch {
            notice = VoiceLibraryText.message(error)
            return false
        }
    }

    /// 删除（立刻全删、不能恢复；界面上先确认过一句）。
    func delete(_ voice: SkyStudioVoice) async {
        guard let key, canEdit, !working.contains(voice.id) else { return }
        working.insert(voice.id)
        defer { working.remove(voice.id) }
        VoiceAudition.shared.stop()
        do {
            try await SkyStudioVoiceDeletion.run(voice.id, key: key, api: api)
            set(voices: voices.filter { $0.id != voice.id })
            notice = nil
        } catch {
            notice = VoiceLibraryText.message(error)
            await refresh()
        }
    }

    /// 新建 / 加了录音之后：把服务器回的那个声音放进列表（有就换掉）。
    func adopt(_ voice: SkyStudioVoice) {
        var list = voices
        if let index = list.firstIndex(where: { $0.id == voice.id }) { list[index] = voice } else { list.append(voice) }
        set(voices: list)
    }

    /// 试听我的声音用的临时链接：没过期（还剩一分钟以上）就用手里的，否则重取这个声音。取不到是 nil。
    func previewURL(voice id: String, language: String, now: Date = Date()) async -> URL? {
        if let entry = voices.first(where: { $0.id == id })?.language(language), let url = entry.previewURL,
           let expires = entry.previewExpiresAt, expires.timeIntervalSince(now) > 60 {
            return url
        }
        guard let key else { return nil }
        do {
            let fresh = try await api.voice(id, key: key)
            adopt(fresh)
            return fresh.language(language)?.previewURL
        } catch {
            notice = VoiceLibraryText.message(error)
            return nil
        }
    }

    /// 给建声音 / 设计那两步用：这一轮读到的 Key（没读到就再静默读一次）。
    func currentKey() async -> Result<String, SkyStudioJobKey.Problem> {
        if let key { return .success(key) }
        let result = await readKey()
        if case .success(let found) = result { key = found }
        return result
    }

    // MARK: 正在设计的

    func designStarted(_ name: String, job: AIJobs.Job) {
        designing.append(name)
        notice = nil
        Task { [weak self] in
            // 设计要几十秒到几分钟：任务结束（成了、失败、取消）就从「正在设计」里拿掉；成了的那一下任务自己会叫「声音库变了」。
            while job.status == .running { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self else { return }
            if let index = self.designing.firstIndex(of: name) { self.designing.remove(at: index) }
            // 为什么没做成用任务自己的那一句（服务器 / SkyCut 的原话，英文）：钱退没退它说得准，这里不另编。
            if job.status == .failed {
                self.notice = String(format: L10n("Designing “%@” did not finish. %@"), name, job.message ?? "")
            }
        }
    }

    // MARK: 内部（没变就不写：订阅它的视图不白算一遍）

    private func set(_ next: Phase) {
        if phase != next { phase = next }
    }

    private func set(voices next: [SkyStudioVoice]) {
        if voices != next { voices = next }
    }
}
