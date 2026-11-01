import Foundation
import Combine
import SrtFlowMCPKit

// MARK: - 设置窗口与 MCP 共用的 AI 权限
// 管什么：默认请求批准、持久化模式、本项目同规格的明确放行；权限变更的确认由 AISettingsApproval 负责。
// 不管什么：系统权限、套餐授权、硬预算和服务端结算；全部权限不会跳过这些执行条件。
@MainActor
final class AIAccessStore: ObservableObject {
    static let shared = AIAccessStore()
    static let modeKey = "SrtFlow.ai.accessMode.v1"
    private static let grantsKey = "SrtFlow.ai.projectApprovals.v1"
    @Published private(set) var mode: AIAccessMode
    private var grants: [String: [String: Double]]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(AIAccessMode.init(rawValue:)) ?? .ask
        grants = defaults.data(forKey: Self.grantsKey).flatMap { try? JSONDecoder().decode([String: [String: Double]].self, from: $0) } ?? [:]
    }

    func setMode(_ next: AIAccessMode) {
        mode = next
        defaults.set(next.rawValue, forKey: Self.modeKey)
    }

    func approvedPrice(project: String?, profile: String) -> Double? {
        project.flatMap { grants[$0]?[profile] }
    }

    func allows(project: String?, profile: String, credits: Double) -> Bool {
        guard credits.isFinite, credits >= 0, let project, let ceiling = grants[project]?[profile] else { return false }
        return credits <= ceiling
    }

    func approve(project: String, profile: String, credits: Double) {
        guard credits.isFinite, credits >= 0 else { return }
        grants[project, default: [:]][profile] = max(grants[project]?[profile] ?? 0, credits)
        if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: Self.grantsKey) }
    }
}
