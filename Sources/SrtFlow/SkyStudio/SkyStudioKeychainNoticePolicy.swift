import Foundation

// 授权提示的规则、给 AI 的下一步与进程内状态通知；不读钥匙串、不请求授权、不改变套餐。
struct SkyStudioKeychainNoticePolicy {
    static let permissionNeeded = Notification.Name("SrtFlow.skystudio.keychainPermissionNeeded")
    static let keyRead = Notification.Name("SrtFlow.skystudio.keychainRead")
    static let shownBuildsKey = "SrtFlow.skystudio.keychainNoticeBuilds.v1"
    static let aiNextStep = "Ask the user to click Allow… on SkyCut's notice, or open SkyCut Settings → Sky Studio and click Allow…. "
        + "In the macOS dialog, enter the Mac login password and choose Always Allow, then try again. "
        + "Choosing Allow only will ask again the next time SkyCut starts."
    /// 钥匙串只是慢（期限内没回答、没有弹框）：先叫 AI 过几秒重试，不叫用户点 Allow…（2026-11-11 真实冒烟：负载 8 时重启后第一次读超了 3 秒，
    /// 重试一次就好）。重试时那次读还没回来，缓存改报要授权，那时才是上面那一句。
    static let aiSlowNextStep = "The macOS keychain has not answered SkyCut yet; it is busy and no permission dialog is involved. "
        + "Wait a few seconds and repeat the same call: SkyCut keeps reading and keeps the key when it arrives. "
        + "Do not ask the user to click Allow… unless the retry says SkyCut needs the user's permission."
    /// 后台 / 启动的静默读碰上慢：等这么久再静默读一次，再不行才挂「允许…」的提示。
    static let slowRetryDelay: Duration = .seconds(5)

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
