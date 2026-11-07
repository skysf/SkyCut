import SwiftUI

// 复用主窗口与所有工程窗口的 notice 挂点：全 App 提示纵向排开，不互相覆盖、不抢焦点。
struct AppNotices: View {
    var body: some View {
        let _ = PerfCounters.body(Self.self)
        VStack(spacing: 0) {
            SkyStudioKeychainNoticeView()
            ScreenRecordingNotice()
        }
    }
}
