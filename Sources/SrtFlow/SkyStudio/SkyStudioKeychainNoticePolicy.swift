import Foundation

// 授权提示的规则、给 AI 的下一步与进程内状态通知；不读钥匙串、不请求授权、不改变套餐。
struct SkyStudioKeychainNoticePolicy {
    static let permissionNeeded = Notification.Name("SrtFlow.skystudio.keychainPermissionNeeded")
    static let keyRead = Notification.Name("SrtFlow.skystudio.keychainRead")
    static let shownBuildsKey = "SrtFlow.skystudio.keychainNoticeBuilds.v1"
    static let aiNextStep = "Ask the user to click Allow… on SkyCut's notice, or open SkyCut Settings → Sky Studio and click Allow…. "
        + "In the macOS dialog, enter the Mac login password and choose Always Allow, then try again. "
        + "Choosing Allow only will ask again the next time SkyCut starts."

    let build: String?

    func shouldPresent(in defaults: UserDefaults) -> Bool {
        guard let build else { return false }
        return !(defaults.stringArray(forKey: Self.shownBuildsKey) ?? []).contains(build)
    }

    /// 真正呈现之后才记下；没有窗口时不消费这一构建的提示机会。
    func didPresent(in defaults: UserDefaults) {
        guard let build, shouldPresent(in: defaults) else { return }
        defaults.set((defaults.stringArray(forKey: Self.shownBuildsKey) ?? []) + [build], forKey: Self.shownBuildsKey)
    }
}
