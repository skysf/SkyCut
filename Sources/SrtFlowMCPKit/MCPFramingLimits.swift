import Foundation

// MCP 特有的取景输入范围；App 的解析 / 关键帧与发现 schema 共用。
// 素材、声音、时长的限制由 App 的生产模型返回 edit_limits，不在协议库复制数值。
public enum MCPFramingLimits {
    public static let center = -2.0...3.0
    public static let scale = 0.05...6.0
    public static let keyframeScale = 0.02...8.0
}
