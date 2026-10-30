import SwiftUI

// MARK: - 轻盈卡片内的一项任务
// 类型图标不随语言猜；状态与积分常驻，详情展开后才看完整说明和进一步动作，不提供取消入口。
struct CloudTaskRow<Status: View, Details: View>: View {
    let title: String
    let model: String
    let mediaKind: CloudTaskMediaKind
    let credits: Double?
    let issue: String?
    @ViewBuilder let status: () -> Status
    @ViewBuilder let details: () -> Details
    @State private var showsDetails = false
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 14)
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: mediaKind.systemImage)
                    .font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(Text(LocalizedStringKey(mediaKind.title)))
                    .instantHelp(LocalizedStringKey(mediaKind.title))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle).instantHelp(verbatim: title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Circle().fill(issue == nil ? Color.secondary : Color.orange).frame(width: 5, height: 5)
                            status().lineLimit(1).fixedSize()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 9) {
                        Text(verbatim: model).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).instantHelp(verbatim: model)
                        Spacer(minLength: 4)
                        if let credits, credits.isFinite, credits >= 0 {
                            Text(verbatim: String(format: L10n(issue == nil ? "%@ credits" : "Estimated %@ credits"), SkyStudioCredits.text(credits)))
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                        } else if issue == nil {
                            Text("Quote pending").font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        Button(LocalizedStringKey(showsDetails ? "Hide details" : "Details")) { showsDetails.toggle() }
                            .controlSize(.small).accessibilityIdentifier("cloud-task-details")
                    }
                    if let issue {
                        Text(verbatim: issue).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(showsDetails ? nil : 2).fixedSize(horizontal: false, vertical: true)
                            .instantHelp(verbatim: issue)
                    }
                    if showsDetails {
                        VStack(alignment: .leading, spacing: 9) {
                            LabeledContent("Media type") { Text(LocalizedStringKey(mediaKind.title)) }
                            details()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.bottom, 14)
    }
}
