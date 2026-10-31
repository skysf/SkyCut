import AppKit
import SwiftUI

// MARK: - AI 状态徽章的不透底背景
// 标题栏下的原生分栏线可能延伸到徽章后面：先铺不透明的系统底色，再叠浅金色 / 中性灰。
// 不能只画半透明颜色，否则小窗口里分栏线会透过徽章，穿过文字；圆角外仍保持透明。
struct AIActivityBadgeBackground: View {
    let isWorking: Bool

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isWorking ? Color.yellow.opacity(0.22) : Color.primary.opacity(0.06))
            }
    }
}
