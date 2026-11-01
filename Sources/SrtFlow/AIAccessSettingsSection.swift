import SwiftUI

// MARK: - 原生设置里的操作权限；与 MCP 使用同一个 Store。
struct AIAccessSettingsSection: View {
    @ObservedObject private var access = AIAccessStore.shared

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        Section("AI permissions") {
            Picker("Permission mode", selection: Binding(get: { access.mode }, set: { access.setMode($0) })) {
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
        }
    }
}
