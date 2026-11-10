import SwiftUI

// MARK: - 变声面板（sheet）：片段右键「换成我的声音…」
//
// 管什么（SkyCut 声音方案 5.5）：目标声音（共用的声音选择器 VoicePickerView：我的声音、设计的声音、预设排最后）、这一段多长、
// 「约 X 积分（最多 Y）」、「开始」。还没有自己的声音时顶上放「新建声音…」（设计的声音和预设照样能选）；超过一次的上限、没有声音：
// 说为什么、「开始」灰着；没有 Sky Studio 的 Key、声音库暂时用不了：说和声音库那一节同一句。
// 面板上的报价就是确认（和 upscale 面板同一个口径）；每日硬预算照样拦（那一行标红、按钮灰着）。按下之后这张就收起来，云端任务浮层里
// 看得见，做完自动落地（两条新音频轨、原声静音）、提示条说一句。
// 数和规矩在 VoiceChangePanelModel（和 AI 的 change_voice 同一条路）；这里只画。只订阅那一份、声音库和积分的账；不读工程、不订阅
// 播放器的时钟。本地化：sheet 不继承应用内语言，调用处套 `.appLanguage()`。

struct VoiceChangePanel: View {
    @StateObject private var model: VoiceChangePanelModel
    @ObservedObject private var store: VoiceLibraryStore
    @ObservedObject private var spend = SkyStudioSpendStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var creatingVoice = false

    /// `store`：面板背后那一份用的同一个声音库（生产是全 App 那一份；回归和离屏渲染给自己的）。
    init(model: VoiceChangePanelModel, store: VoiceLibraryStore) {
        _model = StateObject(wrappedValue: model)
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let overLimit = model.overLimit(spend: spend)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Change Voice").font(.title3).fontWeight(.semibold)
                Text(verbatim: model.clipName + " · " + VoiceReferenceSample.clock(model.clipSeconds))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text("Sky Studio separates the speech from the background and gives the speech the voice you pick. The new voice and the background go on two new audio tracks; the original sound is muted, not deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            libraryStatus
            if model.hasNoVoiceOfMine {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("You have no voice of your own yet. Create one from a recording to dub clips in your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("New Voice…") { creatingVoice = true }
                        .controlSize(.small)
                        .accessibilityIdentifier("voice-change-new-voice")
                        .instantHelp("Create a voice from a recording: record now or choose a file")
                }
            }
            VoicePickerView(selection: $model.selection, store: store)
                .frame(height: 280)
            if let note = VoiceChangeText.languageNote(spoken: model.spoken, target: model.target) {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            offer
            if let problem = model.problem {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(String(format: L10n("Spent today %@ of your %@-credit daily limit"), SkyStudioCredits.text(spend.spentToday()), SkyStudioCredits.text(spend.dailyLimit)))
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // 两个按钮不许被压缩（带价的那个最长）：左边那一句让它折行。
                Button("Cancel") { dismiss() }
                    .fixedSize()
                Button(VoiceChangeText.button(model.quote), action: start)
                .keyboardShortcut(.defaultAction)
                .disabled(model.quote == nil || overLimit)
                .fixedSize()
                .accessibilityIdentifier("voice-change-start")
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.open() }
        .onDisappear { model.close() }
        .smokeVoiceSheet(change: model, start: start)
        .sheet(isPresented: $creatingVoice) {
            NewVoiceSheet(mode: .create, store: store).appLanguage()
        }
    }

    /// 按「开始」：就是确认（VoiceChangePanelModel.start）；起了任务就收起。
    private func start() {
        if model.start() { dismiss() }
    }

    /// 没有 Key / 钥匙串要授权 / 声音库暂时用不了：和设置里声音库那一节同一句。
    @ViewBuilder
    private var libraryStatus: some View {
        switch store.phase {
        case .noKey:
            statusLine("Connect your Sky Studio account in Settings > Sky Studio to change voices.")
        case .needsPermission:
            statusLine("macOS needs your permission before SkyCut can read the key. Open Settings > Sky Studio and click Allow.")
        case .unavailable:
            statusLine("The voice library is not available right now. Try again later.")
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .idle, .loading, .ready:
            EmptyView()
        }
    }

    private func statusLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 报价那一行：这一段变不了的原因 / 在准备 / 还没选声音 / 在问 / 约多少（最多多少）/ 报不了价的原因。
    @ViewBuilder
    private var offer: some View {
        switch (model.source, model.offer) {
        case (.failed(let message), _):
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case (.preparing, _):
            progressLine("Preparing this clip's sound…")
        case (.ready, .none):
            Text("Pick a voice to see the price. The price comes from Sky Studio; a change that fails is refunded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case (.ready, .loading):
            progressLine("Asking Sky Studio for the price…")
        case (.ready, .ready(let quote)):
            Label(VoiceChangeText.offer(quote), systemImage: "waveform.badge.mic")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case (.ready, .failed(let message)):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func progressLine(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
