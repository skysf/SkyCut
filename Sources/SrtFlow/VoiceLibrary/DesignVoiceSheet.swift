import SwiftUI

// MARK: - 设计声音（sheet）
//
// 管什么（SkyCut 声音方案 5.4）：描述（多行）、名字、可选的试读句；报价回来写「将用 MiniMax / Qwen3 设计 · 约 X 积分（最多 Y）」，
// 按钮「设计（最多 Y 积分）」——按下就是确认（一次性费用，和 upscale 面板同一个口径）；超过每日额度那一行标红、按钮灰着。
// 下过单按钮就灰着（`model.ordered`）：双击、回车键按着不放连发都只下一单。
// 设计是任务：按下之后这张就收起来，云端任务浮层里看得见，做完的声音出现在声音库那一节，能试听样音。
// 数和规矩在 DesignVoiceModel（和 AI 的 manage_voices design 同一份核对、同一个任务）；价只从 Sky Studio 的报价来，这里不写数。
// 本地化：sheet 不继承应用内语言，调用处套 `.appLanguage()`。不读工程、不订阅播放器的时钟。

struct DesignVoiceSheet: View {
    @StateObject private var model: DesignVoiceModel
    @ObservedObject private var spend = SkyStudioSpendStore.shared
    @Environment(\.dismiss) private var dismiss

    init(store: VoiceLibraryStore) {
        self.init(model: DesignVoiceModel(store: store))
    }

    /// 给一份现成的（回归和离屏渲染先把它摆到某个样子）。
    init(model: DesignVoiceModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let overLimit = model.overLimit(spend: spend)
        VStack(alignment: .leading, spacing: 12) {
            Text("Design a Voice").font(.title3).fontWeight(.semibold)
            Text("Describe the voice you want: who is speaking, their age, tone and pace. A description in Chinese is designed with MiniMax, any other language with Qwen3; the price below comes from Sky Studio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field("Description") {
                TextEditor(text: $model.prompt)
                    .font(.body)
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                    .accessibilityIdentifier("design-voice-description")
                if model.promptTooLong {
                    Text("The description is too long (at most 2,000 characters).").font(.caption).foregroundStyle(.orange)
                }
            }
            field("Name") {
                TextField("Warm narrator", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("design-voice-name")
            }
            field("Sample sentence (optional)") {
                TextField("A sentence for the voice to read as its sample", text: $model.sampleText)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier("design-voice-sample")
                if model.sampleTooLong {
                    Text("The sample sentence is too long (at most 500 characters).").font(.caption).foregroundStyle(.orange)
                }
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
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                Button(VoiceLibraryText.designButton(model.quote), action: order)
                .keyboardShortcut(.defaultAction)
                .disabled(model.quote == nil || overLimit || model.ordered)
                .accessibilityIdentifier("design-voice-submit")
            }
        }
        .padding(20)
        .frame(width: 500)
        .onDisappear { model.close() }
        .smokeVoiceSheet(design: model, order: order)
    }

    /// 按「设计（最多 Y 积分）」：就是确认（DesignVoiceModel.design）；起了任务就收起。
    private func order() {
        if model.design() { dismiss() }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
    }

    /// 报价那一行：还没填够 / 在问 / 用哪家、约多少（最多多少）/ 报不了价的原因。
    @ViewBuilder
    private var offer: some View {
        switch model.offer {
        case .none:
            Text("Fill in the description and the name to see the price. A design is a one-time fee in Sky Studio credits; a failed design is refunded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking Sky Studio for the price…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let quote):
            Label(VoiceLibraryText.designOffer(quote), systemImage: "wand.and.stars")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
