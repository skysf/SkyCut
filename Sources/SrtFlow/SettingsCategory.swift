import Foundation

// MARK: - 统一设置窗口的分类
//
// 管什么：分类的稳定代号、标题与图标。窗口和 MCP 用同一份分类名。
// 不管什么：设置值和读写；它们仍由各功能原有的 Store 持有。

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case ai
    case editing
    case cache
    case skyStudio = "sky_studio"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .ai: return "Connect AI"
        case .editing: return "Editing & Voices"
        case .cache: return "Media Cache"
        case .skyStudio: return "Sky Studio"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .ai: return "cpu"
        case .editing: return "film.stack"
        case .cache: return "internaldrive"
        case .skyStudio: return "person.crop.circle"
        }
    }
}
