import SwiftUI

// MARK: - 设置里的「Sky Studio」一节
//
// 管什么：收费方案第 5 刀第一步的界面 —— 粘 Key（存进钥匙串、马上问一次）、是哪个账号、免费 / 体验还剩几天 / 正式到哪天、积分余额、
// 问不成时为什么；不是正式版就写一句怎么开通（SkyStudioContactRow，和导出面板上那一行放在一起：SkyStudioProHints.swift。2026-10-27 用户定：
// 先做 B 端，粘 Key、后台手动开通；C 端先只写一个邮箱、不开网页，浏览器里一键连接、网站上付款以后再做）。只订阅 SkyStudioAccount（一个小对象），不读工程。
// 不管什么：Key 怎么存、什么时候问（SkyStudioAccount）、授权怎么算（SkyCutLicense）。

struct SkyStudioSettingsSection: View {
    @ObservedObject private var account = SkyStudioAccount.shared
    @State private var keyText = ""

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let license = account.license
        Section("Sky Studio") {
            Text("Connect your Sky Studio account with an API key. Your plan decides whether AI apps can edit in SkyCut and whether exports carry a watermark; making images, video and upscales uses your Sky Studio credits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if account.hasKey {
                SkyStudioAccountRows(account: account, license: license)
            } else {
                keyRow
                Text("Create a key on skystudioai.com under Settings → SkyCut, then paste it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = account.problem {
                SkyStudioProblemLine(problem: problem, license: license)
            }
            if license.plan != .pro {
                SkyStudioContactRow()
            }
        }
    }

    private var keyRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                SecureField("sk-…", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                    .accessibilityIdentifier("skystudio-key-field")
                    .onSubmit(saveKey)
                Button("Save Key", action: saveKey)
                    .accessibilityIdentifier("skystudio-save-key")
                    .disabled(SkyStudioKey.normalized(keyText) == nil || account.checking)
                    .instantHelp("Store the key in the macOS keychain and check it with Sky Studio")
            }
            .controlSize(.small)
        } label: {
            Text("API key")
        }
    }

    private func saveKey() {
        let text = keyText
        Task {
            await account.saveKey(text)
            if account.hasKey { keyText = "" }
        }
    }
}

/// 存了 Key 之后的三行：账号、授权、积分。
private struct SkyStudioAccountRows: View {
    @ObservedObject var account: SkyStudioAccount
    let license: SkyCutLicense

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let me = account.stored?.me
        LabeledContent {
            HStack(spacing: 6) {
                Text(verbatim: me?.account.email ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Remove Key") { account.removeKey() }
                    .accessibilityIdentifier("skystudio-remove-key")
                    .instantHelp("Remove the Sky Studio key from the macOS keychain")
            }
            .controlSize(.small)
        } label: {
            Text("Account")
        }
        LabeledContent {
            HStack(spacing: 6) {
                planText
                Button("Check Again") { Task { await account.refresh(promptKeychain: true) } }
                    .accessibilityIdentifier("skystudio-check-again")
                    .disabled(account.checking)
                    .instantHelp("Ask Sky Studio again about this account")
            }
            .controlSize(.small)
        } label: {
            Text("Plan")
        }
        if license.basis == .server, license.plan == .free, license.trialUnavailable == "machine_used" {
            Text("This Mac has already had a SkyCut trial, so this account has no trial on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let me {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(verbatim: Self.balanceText(me.credits.balance)).monospacedDigit()
                    if let recharge = me.skycut.rechargeURL {
                        Link("Add Credits", destination: recharge)
                            .instantHelp("Open Sky Studio to add credits")
                    }
                }
                .controlSize(.small)
            } label: {
                Text("Sky Studio credits")
            }
        }
    }

    @ViewBuilder
    private var planText: some View {
        switch license.basis {
        case .noKey:
            Text("Free plan")
        case .notChecked:
            // 两个字面量各自成一个 Text：写成 `Text(a ? "…" : "…")` 会走不查表的 String 重载（docs/architecture/localization.md 第二节）。
            (account.checking ? Text("Checking…") : Text("Not checked yet")).foregroundStyle(.secondary)
        case .expired:
            Text("Free plan · could not check with Sky Studio").foregroundStyle(.orange)
        case .server:
            switch license.plan {
            case .pro?:
                if let until = license.paidUntil {
                    Text("Pro · until \(until, format: .dateTime.year().month().day())").foregroundStyle(.green)
                } else {
                    Text("Pro").foregroundStyle(.green)
                }
            case .trial?:
                switch license.trialDaysLeft(now: Date()) {
                case 1?: Text("Trial · 1 day left")
                case let days?: Text("Trial · \(days) days left")
                case nil: Text("Trial")
                }
            case .free?, nil:
                Text("Free plan")
            }
        }
    }

    /// 积分：整数就不带小数，不是整数留一位。
    static func balanceText(_ balance: Double) -> String {
        balance == balance.rounded() ? String(Int(balance)) : String(format: "%.1f", balance)
    }
}

/// 问不成、存不了时那一句（橙色），能自己解决的带一个按钮 / 链接。
private struct SkyStudioProblemLine: View {
    let problem: SkyStudioProblem
    let license: SkyCutLicense

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(alignment: .leading, spacing: 4) {
            switch problem {
            case .keyRejected(let message):
                Text(verbatim: message) + Text(verbatim: " ") + Text("Paste a new key.")
            case .updateRequired(let message, let download):
                Text(verbatim: message)
                if let download {
                    Link("Download SkyCut", destination: download)
                }
            case .unreachable(let message):
                Text(verbatim: message)
                if license.basis == .server, let until = license.validUntil {
                    Text("SkyCut keeps using the last answer until \(until, format: .dateTime.month().day().hour().minute()).")
                }
            case .needsKeychainPermission:
                Text("macOS needs your permission before SkyCut can read the key.")
                Button("Allow…") { Task { await SkyStudioAccount.shared.refresh(promptKeychain: true) } }
                    .controlSize(.small)
                    .instantHelp("Let macOS ask whether SkyCut may read the key")
            case .keychain(let message):
                Text(verbatim: message)
            case .notAKey:
                Text("That does not look like a Sky Studio key: it starts with sk-.")
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}
