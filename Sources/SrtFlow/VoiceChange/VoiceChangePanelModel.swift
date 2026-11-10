import Foundation

// MARK: - 变声面板背后的那一份
//
// 管什么（SkyCut 声音方案 5.5）：面板为一段打开时——
// 1. 取声音库（VoiceLibraryStore，选择器同一份）和一次最长多少秒（`/models`）；超了、没声音、静音了：说为什么，「开始」灰着。
// 2. 截出这一段的声音、定它说的是什么语言（VoiceChangeSource / VoiceChangeOrder，和 AI 的 change_voice 同一条路；收费之前、免费）。
// 3. 目标声音默认放「我的声音」：只有一个就默认它，有几个就默认上次用过的那个，一个都没有就不选（设计的声音和预设照样能选）。
// 4. 选了声音就问 Sky Studio 报价（`/quote`，免费、不建任务），显示「约 X 积分（最多 Y）」。报价对的是哪一份就交哪一份：换了声音，
//    手里的报价作废、重新问。
// 5. 按下「开始」**就是确认**（和 upscale 面板同一个口径，不走确认码）：照报价先过每日硬预算、记账、起任务（VoiceChangeJob，做完
//    自动落地、提示条说一句）。关掉面板不取消已经起的任务；没起任务就把截好的那段声音删掉。
// 视图只订阅这一份和声音库、试听、积分的账；工程只在这里的方法里读（开面板、按下「开始」那一下），视图的 body 不读。
// 不管什么：界面（VoiceChangePanel）、任务（VoiceChangeJob）、价（服务器的 /quote，这里不写数）。

@MainActor
final class VoiceChangePanelModel: ObservableObject {
    enum Source: Equatable {
        case preparing
        case ready(VoiceChangeSource.Prepared)
        /// 这一段变不了 / 读不了：那一句（照界面语言）。
        case failed(String)
    }

    enum Offer: Equatable {
        /// 还没选声音、或这一段还没准备好。
        case none
        case loading
        case ready(SkyStudioQuote)
        case failed(String)
    }

    let clipID: UUID
    let clipName: String
    /// 这一段用了素材多少秒（面板上显示、按它判上限）。
    let clipSeconds: Double

    /// 选中的声音（`voice_…` / `gemini:<名字>`）。
    @Published var selection: String? { didSet { if selection != oldValue { requote() } } }
    @Published private(set) var source: Source = .preparing
    /// 这一段说的是什么语言（检测出来的；检测不出来是 nil）。
    @Published private(set) var spoken: String?
    @Published private(set) var offer: Offer = .none
    /// 按下去之后出的错（每日额度不够、这一段没了…）。
    @Published private(set) var problem: String?

    /// 回归换成假的：检测、槽、临时文件夹。发请求和读 Key 走声音库那一份（`store`）。
    var services = VoiceChangeServices()

    private let project: VideoEditProject
    private let store: VoiceLibraryStore
    /// 截好的那段声音放哪（开面板时才定：`services.workFolder` 下面一个只属于这一次的文件夹）。
    private var folder: URL?
    private var quoted: (draft: SkyStudioJobRequest, target: VoiceChangeTarget, key: String)?
    private var asking: Task<Void, Never>?
    private var started = false
    private var opened = false

    /// 这一段不在了、没有声音、已经静音：不摆面板（菜单项本来也只给能变的段）。
    init?(project: VideoEditProject, clipID: UUID, store: VoiceLibraryStore? = nil) {
        guard let clip = project.state.clip(with: clipID), VoiceChangeSource.refusal(for: clip) == nil else { return nil }
        self.project = project
        self.clipID = clipID
        self.store = store ?? VoiceLibraryStore.shared
        clipName = clip.name
        clipSeconds = clip.sourceDuration
    }

    // MARK: 给界面读的

    /// 选中的那个声音是谁（声音库里的、或预设）；没选、找不到是 nil。
    var target: VoiceChangeTarget? { Self.target(selection, voices: store.voices, catalog: store.catalog) }

    var quote: SkyStudioQuote? {
        if case .ready(let quote) = offer { return quote }
        return nil
    }

    /// 报价加上今天已花的超没超每日额度（超了按钮灰着、那一行标红）。
    func overLimit(spend: SkyStudioSpendStore) -> Bool {
        guard let quote else { return false }
        return spend.spentToday() + quote.credits > spend.dailyLimit + 0.0005
    }

    /// 还没有自己的声音（用录音建的）：面板顶上放「新建声音…」。
    var hasNoVoiceOfMine: Bool { store.canEdit && !store.voices.contains { $0.source != "design" } }

    // MARK: 纯值

    /// 默认选哪个：我的声音（用录音建的）只有一个就是它，有几个就是上次用过的那个（还在的话），一个都没有就不选。
    nonisolated static func defaultSelection(voices: [SkyStudioVoice], last: String?) -> String? {
        let mine = voices.filter { $0.source != "design" }
        if mine.count == 1 { return mine[0].id }
        guard let last, mine.contains(where: { $0.id == last }) else { return nil }
        return last
    }

    nonisolated static func target(_ id: String?, voices: [SkyStudioVoice], catalog: SkyStudioVoiceCatalog?) -> VoiceChangeTarget? {
        guard let id else { return nil }
        if let voice = voices.first(where: { $0.id == id }) { return VoiceChangeTarget(voice: voice) }
        return catalog?.preset(id).map(VoiceChangeTarget.init(preset:))
    }

    // MARK: 动作

    /// 面板出现时调一次：取声音库和上限、截声音、定语言、默认选一个、问价。
    func open() async {
        guard !opened else { return }
        opened = true
        await store.refresh()
        guard !Task.isCancelled else { return }
        if selection == nil {
            selection = Self.defaultSelection(voices: store.voices, last: VoiceChangeActivity.shared.lastVoiceID)
        }
        guard let clip = project.state.clip(with: clipID) else {
            return source = .failed(L10n("This clip is no longer on the timeline."))
        }
        services.voice.api = store.api
        if case .success(let key) = await store.currentKey(),
           let catalog = try? await SkyStudioCatalogCache.shared.catalog(key: key, api: store.api),
           let problem = VoiceChangeSource.tooLong(clip, limit: VoiceChangeOrder.maxSourceSeconds(in: catalog)) {
            return source = .failed(VoiceChangeText.message(problem))
        }
        let folder = services.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.folder = folder
        do {
            let prepared = try await VoiceChangeSource.prepare(clip, folder: folder)
            let language = try await VoiceChangeOrder.spokenLanguage(given: nil, source: prepared, services: services)
            guard !Task.isCancelled else { return }
            spoken = language
            source = .ready(prepared)
        } catch is CancellationError {
            return
        } catch {
            source = .failed(VoiceChangeText.message(error))
        }
        requote()
    }

    /// 按下「开始」：过每日硬预算、记账、起任务。起了回 true（面板关掉）。
    func start() -> Bool {
        guard case .ready(let quote) = offer, let quoted, case .ready(let prepared) = source else { return false }
        guard let clip = project.state.clip(with: clipID), VoiceChangeSource.refusal(for: clip) == nil else {
            problem = L10n("This clip is no longer on the timeline.")
            return false
        }
        guard !VoiceChangeActivity.shared.isChanging(clipID) else {
            problem = L10n("This clip's voice is already being changed.")
            return false
        }
        guard let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: quote.credits) else {
            problem = L10n("Daily AI budget reached. Raise the daily budget in Settings > Sky Studio to continue.")
            return false
        }
        _ = VoiceChangeOrder.start(clip: clip, source: prepared, draft: quoted.draft, quote: quote, target: quoted.target, key: quoted.key,
                                   reservation: reservation, project: project, notifies: true, services: services)
        VoiceChangeActivity.shared.lastVoiceID = quoted.target.id
        started = true
        return true
    }

    /// 面板关掉：不再问价；没起任务就把截好的那段声音删掉（起了的由任务删）。
    func close() {
        asking?.cancel()
        if !started, let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: 内部

    private func requote() {
        asking?.cancel()
        problem = nil
        quoted = nil
        guard case .ready(let prepared) = source, let target,
              let draft = try? VoiceChangeOrder.draft(target: target, seconds: prepared.seconds, spoken: spoken) else {
            if offer != .none { offer = .none }
            return
        }
        if offer != .loading { offer = .loading }
        asking = Task { [weak self] in await self?.ask(draft, target: target) }
    }

    private func ask(_ draft: SkyStudioJobRequest, target: VoiceChangeTarget) async {
        let key: String
        switch await store.currentKey() {
        case .success(let found): key = found
        case .failure(let issue):
            guard !Task.isCancelled else { return }
            offer = .failed(VoiceLibraryText.keyProblem(issue))
            return
        }
        do {
            let quote = try await store.api.quote(draft, key: key)
            guard !Task.isCancelled else { return }
            quoted = (draft, target, key)
            offer = .ready(quote)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            offer = .failed(VoiceLibraryText.message(error))
        }
    }
}
