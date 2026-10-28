import AppKit
import SwiftUI

// MARK: - 开通正式版怎么说：设置里那一行、导出面板上那一行
//
// 管什么：不是正式版时告诉用户怎么开通：发邮件到客服邮箱，写上 Sky Studio 账号的邮箱（正式版由 Sky Studio 后台按账号手动开；
// 2026-10-27 用户定：软件里只写一个邮箱，不开网页）。两处：设置里「Sky Studio」一节的最后一行（SkyStudioContactRow）；
// 导出面板底栏上「会带水印」那一行（ExportWatermarkNotice，收费方案第 5 刀第二步，**不拦导出**）。两处共用「复制邮箱」。
// 不管什么：带不带水印（WatermarkPolicy + SkyStudioAccount.exportsWithWatermark）、授权怎么算（SkyCutLicense）。

/// 设置里：怎么开通正式版。邮箱能选中，也给一个「复制」。
struct SkyStudioContactRow: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("To activate SkyCut Pro, email \(SkyStudioLinks.supportEmail) with the email address of your Sky Studio account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            SkyStudioCopyEmailButton(identifier: "skystudio-copy-support-email")
        }
    }
}

/// 导出面板底栏：这次导出的视频会带 Sky Studio 水印，开通正式版写哪个邮箱。只出声音时面板不放它（没有画面）。
/// 只订阅 SkyStudioAccount（授权变了这一行跟着变），不读工程。
struct ExportWatermarkNotice: View {
    @ObservedObject private var account = SkyStudioAccount.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if WatermarkPolicy.required(byLicence: account.exportsWithWatermark) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("The video will carry a Sky Studio watermark. To export without it, activate SkyCut Pro: email \(SkyStudioLinks.supportEmail) with the email address of your Sky Studio account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                SkyStudioCopyEmailButton(identifier: "export-copy-support-email")
            }
            .accessibilityIdentifier("export-watermark-notice")
        }
    }
}

/// 「复制邮箱」。不做成点了就打开「邮件」的链接：用网页邮箱的人一点，跳出来的是系统「邮件」的设置向导。
struct SkyStudioCopyEmailButton: View {
    let identifier: String
    @State private var copied = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SkyStudioLinks.supportEmail, forType: .string)
            copied = true
        } label: {
            copied ? Text("Copied") : Text("Copy Address")
        }
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
        .instantHelp("Copy the support email address")
    }
}
