import AppKit
import SwiftUI

// MARK: - 开通正式版怎么说：设置里那一行、导出面板上那一行
//
// 管什么：不是正式版时告诉用户怎么开通：/me 有可用购买地址就打开它，否则照旧给客服邮箱和「复制邮箱」。
// 两处共用 SkyStudioContactRow：设置里「Sky Studio」一节的最后一行；导出面板底栏上「会带水印」那一行
//（ExportWatermarkNotice，**不拦导出**）。链接只来自服务器，不拼接购买页。
// 不管什么：带不带水印（WatermarkPolicy + SkyStudioAccount.exportsWithWatermark）、授权怎么算（SkyCutLicense）。

/// 设置 / 导出面板：怎么开通正式版。链接或邮箱由同一份此刻授权给出。
struct SkyStudioContactRow: View {
    let license: SkyCutLicense
    var isExport = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            message
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let url = license.proActivationURL {
                Link("Get SkyCut Pro", destination: url)
                    .controlSize(.small)
                    .accessibilityIdentifier(isExport ? "export-open-pro-purchase" : "skystudio-open-pro-purchase")
                    .instantHelp("Open Sky Studio to buy SkyCut Pro")
            } else {
                SkyStudioCopyEmailButton(identifier: isExport ? "export-copy-support-email" : "skystudio-copy-support-email")
            }
        }
    }

    @ViewBuilder
    private var message: some View {
        if license.proActivationURL != nil {
            if isExport {
                Text("The video will carry a Sky Studio watermark. Activate SkyCut Pro to export without it.")
            } else {
                Text("Activate SkyCut Pro to use AI editing and export without a watermark.")
            }
        } else if isExport {
            Text("The video will carry a Sky Studio watermark. To export without it, activate SkyCut Pro: email \(SkyStudioLinks.supportEmail) with the email address of your Sky Studio account.")
        } else {
            Text("To activate SkyCut Pro, email \(SkyStudioLinks.supportEmail) with the email address of your Sky Studio account.")
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
            SkyStudioContactRow(license: account.license, isExport: true)
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
