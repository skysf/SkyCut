import Foundation

// MARK: - 变声的界面状态：面板为哪一段开着、哪几段正在变
//
// 管什么（SkyCut 声音方案 5.5）：片段右键「换成我的声音…」只往这里写一个目标（块不读工程、不做 IO），面板由 VoiceChangePresenter 摆出来；
// 正在变声的那几段记在这里，同一段不起第二单（AI 的 change_voice 和面板都先看一眼）；上次用的是哪个声音记在 UserDefaults
// （身份类的键沿用 SrtFlow 前缀，docs/architecture/product-name.md），面板下次默认选它。
// 只有摆面板的那个小视图订阅它；任务的阶段在云端任务浮层那一行（SkyStudioMediaStatus），不在这里。
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

    /// 上次变声用的那个声音（`voice_…` / `gemini:<名字>`）；没用过是 nil。
    var lastVoiceID: String? {
        get { UserDefaults.standard.string(forKey: Self.lastVoiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastVoiceKey) }
    }
}
