import Foundation

// MARK: - 变声的界面状态：面板为哪一段开着、哪几段正在变
//
// 管什么（SkyCut 声音方案 5.5）：片段右键「换成我的声音…」只往这里写一个目标（块不读工程、不做 IO），面板由 VoiceChangePresenter 摆出来；
// 正在变声的那几段记在这里，同一段不起第二单（AI 的 change_voice 和面板都先看一眼）；上次用的是哪个声音记在 UserDefaults
// （身份类的键沿用 SrtFlow 前缀，docs/architecture/product-name.md），面板下次默认选它。
// 只有摆面板的那个小视图订阅它；任务的阶段在云端任务浮层那一行（SkyStudioMediaStatus），不在这里。
// Clips whose last change stopped because Sky Studio's separation failed (2026-11-21) are remembered for this run of the App:
// the panel opened again on such a clip says so and starts with the direct option on, so a retry is one click. A change of
// that clip that lands forgets it.
// 不管什么：任务怎么跑（VoiceChangeJob）、面板里面（VoiceChangePanel / VoiceChangePanelModel）。

/// 面板要为哪一段打开。
struct VoiceChangePanelTarget: Identifiable, Equatable {
    let id: UUID
}

@MainActor
final class VoiceChangeActivity: ObservableObject {
    static let shared = VoiceChangeActivity()
    static let lastVoiceKey = "SrtFlow.voiceChange.lastVoiceID"

    @Published var panel: VoiceChangePanelTarget?
    /// 正在变声的那几段（片段的 id）。不发给界面：只在起任务之前问一句。
    private(set) var inFlight: Set<UUID> = []

    func present(panelFor clipID: UUID) { panel = VoiceChangePanelTarget(id: clipID) }

    func isChanging(_ clipID: UUID) -> Bool { inFlight.contains(clipID) }
    func began(_ clipID: UUID) { inFlight.insert(clipID) }
    func ended(_ clipID: UUID) { inFlight.remove(clipID) }

    /// Clips whose last change failed at the separation (not published: the panel reads it once when it opens).
    private var separationFailures: Set<UUID> = []

    func separationFailed(_ clipID: UUID) -> Bool { separationFailures.contains(clipID) }
    func noteSeparationFailed(_ clipID: UUID) { separationFailures.insert(clipID) }
    func noteLanded(_ clipID: UUID) { separationFailures.remove(clipID) }

    /// The AI job id of the change last started for each clip in each opening of a project (2026-11-26): the panel opened again on
    /// that clip offers its Download again while Sky Studio's result is held (SkyStudioPanelHeldDownload). Found by the job's own
    /// clip, never by a request's parameters.
    private var lastJobs: [String: String] = [:]

    func noteJob(_ jobID: String, clip clipID: UUID, generation: Int) { lastJobs["\(generation):\(clipID)"] = jobID }
    func lastJob(for clipID: UUID, generation: Int) -> String? { lastJobs["\(generation):\(clipID)"] }

    /// 上次变声用的那个声音（`voice_…` / `gemini:<名字>`）；没用过是 nil。
    var lastVoiceID: String? {
        get { UserDefaults.standard.string(forKey: Self.lastVoiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastVoiceKey) }
    }
}
