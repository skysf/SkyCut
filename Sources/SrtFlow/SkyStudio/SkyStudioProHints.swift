import AppKit
import SwiftUI

// MARK: - 开通正式版怎么说：设置里那一行、导出面板上那一行
//
// 管什么：台数满了先管理 Mac，其余不是正式版时告诉用户怎么开通；链接不可用时给客服邮箱和「复制邮箱」。
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
            if license.isMachineLimited, let url = license.manageMachinesURL {
                Link("Manage Macs", destination: url)
                    .controlSize(.small)
                    .accessibilityIdentifier(isExport ? "export-manage-macs" : "skystudio-manage-macs")
                    .instantHelp("Open Sky Studio to manage the Macs using this account")
            } else if let url = license.proActivationURL {
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
        VStack(alignment: .leading, spacing: 4) {
            if license.isMachineLimited {
                machineLimitMessage
                if isExport { Text("The video will carry a Sky Studio watermark.") }
                if license.manageMachinesURL != nil {
                    Text("Remove a Mac in Sky Studio to use this account here.")
                } else {
                    Text("To use this account on this Mac, contact \(SkyStudioLinks.supportEmail).")
                }
            } else {
                if let message = license.unrecognizedPlanMessage { Text(verbatim: message) }
                activationMessage
            }
        }
    }

    @ViewBuilder
    private var machineLimitMessage: some View {
        if let limit = license.machineLimit, limit > 0 {
            if limit == 1 {
                Text("This account is already using SkyCut on 1 Mac. This Mac is using the free plan.")
            } else {
                Text("This account is already using SkyCut on \(limit) Macs. This Mac is using the free plan.")
            }
        } else {
            Text("This account has reached its Mac limit. This Mac is using the free plan.")
        }
    }

    @ViewBuilder
    private var activationMessage: some View {
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

/// 导出面板底栏：水印说明 + Pro 续约提醒。只出声音时不写水印，续约提醒仍显示。
/// 只订阅 SkyStudioAccount（授权变了提示跟着变），不读工程；台数优先级由共享 proNotice 处理。
struct ExportWatermarkNotice: View {
    let isAudioOnly: Bool
    @ObservedObject private var account = SkyStudioAccount.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let license = account.license
        VStack(alignment: .leading, spacing: 6) {
            if !isAudioOnly, WatermarkPolicy.required(byLicence: account.exportsWithWatermark) {
                SkyStudioContactRow(license: account.license, isExport: true)
                    .accessibilityIdentifier("export-watermark-notice")
            }
            if let notice = license.proNotice {
                SkyStudioProNoticeRow(notice: notice, isExport: true)
            }
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
