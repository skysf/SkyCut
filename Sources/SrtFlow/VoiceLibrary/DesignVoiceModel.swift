import Foundation

// MARK: - 设计声音：对话框背后的那一份
//
// 管什么（SkyCut 声音方案 5.4）：描述、名字、可选的试读句；填好了停一下就问 Sky Studio 报价（`/quote`，免费、不建任务），显示用哪家的
// 模型、约多少积分（最多多少）；按下「设计（最多 Y 积分）」**就是确认**：照报价的那个数判每日硬预算、记上账、起任务
// （SkyStudioVoiceDesignOrder：和 AI 的 manage_voices design 同一份核对、同一个任务；AI 那一路的确认码这里不用）。
// 设计是任务：关掉对话框不取消，云端任务浮层里看得见，做完进声音库。
// 报价对的是哪一份就交哪一份：改了任何一个字，手里的报价作废、重新问，按钮先灰着。
// 不管什么：界面（DesignVoiceSheet）、任务（SkyStudioVoiceLibraryJob）、价（服务器的 /quote，这里不写数）。

@MainActor
final class DesignVoiceModel: ObservableObject {
    enum Offer: Equatable {
        /// 还没填够（描述、名字）。
        case none
        case loading
        case ready(SkyStudioQuote)
        /// 报不了价：那一句。
        case failed(String)
    }

    @Published var prompt = "" { didSet { if prompt != oldValue { fieldsChanged() } } }
    @Published var name = "" { didSet { if name != oldValue { fieldsChanged() } } }
    @Published var sampleText = "" { didSet { if sampleText != oldValue { fieldsChanged() } } }
    @Published private(set) var offer: Offer = .none
    /// 按下去之后出的错（每日额度不够…）。
    @Published private(set) var problem: String?

    /// 停多久再问报价（回归改短）。
    var quoteDelay: Double = 0.6
    /// 状态行挂在哪个工程的任务浮层里（设置窗口不属于哪个工程：菜单作用的那一个）。
    var project: @MainActor () -> VideoEditProject? = { OpenProjects.shared.focused }

    private let store: VoiceLibraryStore
    private var quoted: SkyStudioJobRequest?
    private var asking: Task<Void, Never>?

    init(store: VoiceLibraryStore? = nil) {
        self.store = store ?? VoiceLibraryStore.shared
    }

    /// 描述、名字、试读句各自还行不行（界面在框下面说差什么）。
    var promptTooLong: Bool { prompt.unicodeScalars.count > SkyStudioVoiceDesignOrder.maxDescription }
    var sampleTooLong: Bool { sampleText.unicodeScalars.count > SkyStudioVoiceDesignOrder.maxSampleText }

    var quote: SkyStudioQuote? {
        if case .ready(let quote) = offer { return quote }
        return nil
    }

    /// 报价加上今天已花的超没超每日额度（超了按钮灰着、那一行标红）。
    func overLimit(spend: SkyStudioSpendStore) -> Bool {
        guard let quote else { return false }
        return spend.spentToday() + quote.credits > spend.dailyLimit + 0.0005
    }

    /// 按下「设计」：判每日硬预算、记账、起任务。起了回 true（对话框关掉）。
    func design() -> Bool {
        guard case .ready(let quote) = offer, let draft = quoted, store.canEdit else { return false }
        guard let key = lastKey else { return false }
        guard let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: quote.credits) else {
            problem = L10n("Daily AI budget reached. Raise the daily budget in Settings > Sky Studio to continue.")
            return false
        }
        let job = SkyStudioVoiceDesignOrder.start(draft, quote: quote, key: key, reservation: reservation, project: project(), api: store.api)
        store.designStarted(draft.params["name"]?.stringValue ?? name, job: job)
        return true
    }

    func close() {
        asking?.cancel()
    }

    // MARK: 内部

    private var lastKey: String?

    private func fieldsChanged() {
        asking?.cancel()
        problem = nil
        quoted = nil
        guard let draft = try? SkyStudioVoiceDesignOrder.draft(description: prompt, name: name, sampleText: sampleText) else {
            if offer != .none { offer = .none }
            return
        }
        if offer != .loading { offer = .loading }
        let delay = quoteDelay
        asking = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.ask(draft)
        }
    }

    private func ask(_ draft: SkyStudioJobRequest) async {
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
            lastKey = key
            quoted = draft
            offer = .ready(quote)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            offer = .failed(VoiceLibraryText.message(error))
        }
    }
}
