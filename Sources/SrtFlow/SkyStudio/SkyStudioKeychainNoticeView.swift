import SwiftUI

// 全 App 非模态提示：仅按钮触发系统授权，关闭不会打断工作或自动重弹。
struct SkyStudioKeychainNoticeView: View {
    @ObservedObject private var account = SkyStudioAccount.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        if account.keychainNoticeVisible {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Text("After this SkyCut update, allow access to your Sky Studio key once.")
                        .font(.headline)
                    Spacer()
                    Button { account.dismissKeychainNotice() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .instantHelp("Dismiss this message")
                }
                Text("In the macOS dialog, enter your Mac login password and choose Always Allow. Choosing Allow only will ask again the next time SkyCut starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow…") { Task { await account.allowKeychain() } }
                        .disabled(account.authorizingKeychain)
                        .accessibilityIdentifier("skystudio-notice-allow")
                    if account.authorizingKeychain { Text("Waiting for macOS permission…").font(.caption) }
                }
            }
            .padding(14)
            .frame(maxWidth: 680, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.4)))
            .shadow(radius: 6, y: 2)
            .padding(10)
            .onAppear { account.keychainNoticeDidAppear() }
            .accessibilityIdentifier("skystudio-keychain-notice")
        }
    }
}
