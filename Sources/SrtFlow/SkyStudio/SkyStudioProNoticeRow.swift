import SwiftUI

// MARK: - 设置 / 导出共用的 Pro 续约提醒
//
// 管什么：按 SkyCutProNotice 显示本地化提醒、续约 / 更新付款方式链接或可选中、可复制的客服邮箱。
// 不管什么：提醒条件、天数、商务来源和台数的优先级（SkyCutProNotice）；功能授权、网络和支付。

struct SkyStudioProNoticeRow: View {
    let notice: SkyCutProNotice
    var isExport = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                message
                if notice.actionURL == nil {
                    switch notice.kind {
                    case .expiring:
                        Text("To renew, contact \(SkyStudioLinks.supportEmail).")
                    case .paymentGrace:
                        Text("For help updating your payment method, contact \(SkyStudioLinks.supportEmail).")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 8)
            action.fixedSize()
        }
        .accessibilityIdentifier(isExport ? "export-pro-notice" : "skystudio-pro-notice")
    }

    @ViewBuilder
    private var message: some View {
        switch notice.kind {
        case .expiring(days: 1):
            Text("Pro expires in 1 day and will not renew automatically.")
        case .expiring(let days):
            Text("Pro expires in \(days) days and will not renew automatically.")
        case .paymentGrace(let until):
            Text("The renewal payment failed. Pro is kept until \(until, format: .dateTime.year().month().day()). Please update your payment method.")
        }
    }

    @ViewBuilder
    private var action: some View {
        if let url = notice.actionURL {
            switch notice.kind {
            case .expiring:
                Link("Renew SkyCut Pro", destination: url)
                    .controlSize(.small)
                    .accessibilityIdentifier(isExport ? "export-renew-pro" : "skystudio-renew-pro")
                    .instantHelp("Open Sky Studio to renew SkyCut Pro")
            case .paymentGrace:
                Link("Update Payment Method", destination: url)
                    .controlSize(.small)
                    .accessibilityIdentifier(isExport ? "export-update-payment" : "skystudio-update-payment")
                    .instantHelp("Open Sky Studio to update your payment method")
            }
        } else {
            SkyStudioCopyEmailButton(identifier: isExport ? "export-copy-support-email" : "skystudio-copy-support-email")
        }
    }
}
