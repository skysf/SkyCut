import SwiftUI

// MARK: - 打开「全部权限」时的说明（SkyCut 声音方案 5.6）
//
// 管什么：设置里选「全部权限」先弹这一张：打开以后 AI 不再先问、做完再说的几件事；声音的一次性费用价目（/models 读，读不到写「以报价为准」）；
// 每日额度照样是硬上限；打开即确认的那句长期授权（认识的版本显示译文，不认识的显示服务器给的英文原文）。
// 「同意并打开」把用户看到的那一版交回去（AIAccessSettingsSection 写 Store、记长期授权）；「取消」什么都不改。每次切到全部权限都弹。
// 不管什么：记 / 撤长期授权（SkyStudioVoiceStanding）、AI 那一路（set_settings 的问句，AISettingsApproval）。
struct FullAccessConsentSheet: View {
    /// 用户点了「同意并打开」：带上看到的那一句的版本。
    let onAgree: (String) -> Void
    let onCancel: () -> Void
    @State private var loaded: SkyStudioVoiceStandingNotice?

    /// `notice`：已经有的那一份就先照它显示（离屏渲染、预览用）；打开以后照样再读一次 /models。
    init(notice: SkyStudioVoiceStandingNotice? = nil, onAgree: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onAgree = onAgree
        self.onCancel = onCancel
        _loaded = State(initialValue: notice)
    }

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let notice = loaded ?? SkyStudioVoiceStandingNotice(catalog: nil, dailyLimit: SkyStudioSpendStore.shared.dailyLimit)
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn on Full access")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("With Full access, AI does these without asking you first and tells you afterwards:")
                bullet(Text("Read files outside the folders you opened, and move files to the Trash"))
                bullet(Text("Generate beyond the default specifications"))
                bullet(Text("Create voices from recordings, build MiniMax versions, design and delete voices"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("One-time voice fees (Sky Studio's quote decides):")
                if loaded == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if notice.fees.isEmpty {
                    bullet(Text("Sky Studio quotes each fee when it is needed."))
                } else {
                    fees(notice)
                }
                Text("The daily budget stays a hard limit (now \(SkyStudioCredits.text(notice.dailyLimit)) credits a day).")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("By turning it on, you confirm:")
                statement(notice.statement)
                    .italic()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Agree and Turn On") { onAgree(notice.statement.version) }
                    .accessibilityIdentifier("full-access-agree")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 480)
        // Esc = 取消（快捷键不许和提示分家，checks/instant-tooltip-wiring.sh；同 BurnInView 用 onExitCommand）。
        .onExitCommand(perform: onCancel)
        .task { loaded = await SkyStudioVoiceStanding.shared.notice() }
    }

    /// 设计按次收的写「约多少」，按字数收的（Sky Studio #247 起的 Qwen3）写「描述加试读句每开始 1,000 字多少」。
    @ViewBuilder
    private func fees(_ notice: SkyStudioVoiceStandingNotice) -> some View {
        if let fee = notice.fee(.designChinese) {
            let credits = SkyStudioCredits.text(fee.credits)
            bullet(fee.perThousandCharacters
                ? Text("Design a voice from a Chinese description (MiniMax): \(credits) credits for every 1,000 characters started (description + sample text)")
                : Text("Design a voice from a Chinese description (MiniMax): about \(credits) credits"))
        }
        if let fee = notice.fee(.designEnglish) {
            let credits = SkyStudioCredits.text(fee.credits)
            bullet(fee.perThousandCharacters
                ? Text("Design a voice from an English description (Qwen3): \(credits) credits for every 1,000 characters started (description + sample text)")
                : Text("Design a voice from an English description (Qwen3): about \(credits) credits"))
        }
        if let credits = notice.credits(.minimaxVersion) {
            bullet(Text("Build a voice's MiniMax version (once per language): about \(SkyStudioCredits.text(credits)) credits"))
        }
    }

    /// 那句长期授权：SkyCut 认识的版本显示译文（和 SkyStudioVoiceStandingNotice.knownStatement 同一句英文），不认识的显示服务器给的英文原文。
    private func statement(_ statement: SkyStudioVoiceConsentStatement) -> Text {
        guard statement.version == SkyStudioVoiceStandingNotice.knownStatement.version else { return Text(verbatim: statement.statement) }
        return Text("For every recording I later use to create a voice in SkyCut, I am the person speaking or I have their permission to create and use an AI copy of their voice.")
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
