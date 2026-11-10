import SwiftUI

// MARK: - 原生设置里的操作权限；与 MCP 使用同一个 Store。
// 选「全部权限」先弹说明（FullAccessConsentSheet，SkyCut 声音方案 5.6），按「同意并打开」才写 Store 并记长期授权；
// 切回请求批准立刻写 Store、撤掉长期授权（SkyStudioVoiceStanding）。长期授权没记上时下面写一行。
struct AIAccessSettingsSection: View {
    @ObservedObject private var access = AIAccessStore.shared
    @ObservedObject private var standing = SkyStudioVoiceStanding.shared
    @State private var explainingFullAccess = false

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Section("AI permissions") {
            Picker("Permission mode", selection: Binding(get: { access.mode }, set: choose)) {
                ForEach(AIAccessMode.allCases, id: \.rawValue) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode)
                }
            }
            .accessibilityIdentifier("ai-access-mode")
            Text("Start with low-cost drafts in both modes. Ask for approval pauses before exceeding defaults. Full access proceeds and reports what it did. Daily budgets remain hard limits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("AI can change this mode only after asking you and receiving your explicit approval, including when Full access is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if access.mode == .full, case .notRecorded = standing.status {
                Text("Your voice consent is not recorded on Sky Studio yet, so AI asks once before the first voice recording, voice design or MiniMax version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $explainingFullAccess) {
            FullAccessConsentSheet(onAgree: agree, onCancel: { explainingFullAccess = false })
                .appLanguage()
        }
    }

    /// 选了哪种：全部权限先弹说明，别的立刻改并撤掉长期授权。
    private func choose(_ mode: AIAccessMode) {
        guard mode != access.mode else { return }
        if mode == .full {
            explainingFullAccess = true
            return
        }
        access.setMode(mode)
        Task { await SkyStudioVoiceStanding.shared.modeChanged(to: mode, statementVersion: SkyStudioVoiceStandingNotice.knownStatement.version) }
    }

    /// 「同意并打开」：写 Store，记用户看到的那一版（记不上照样打开，声音那几件事第一次还会问一次）。
    private func agree(_ statementVersion: String) {
        explainingFullAccess = false
        access.setMode(.full)
        Task { await SkyStudioVoiceStanding.shared.modeChanged(to: .full, statementVersion: statementVersion) }
    }
}
