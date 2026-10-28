import Foundation

// MARK: - 问不成 / 存不了 Key 时为什么
//
// 管什么：SkyStudioAccount 记下的「上一次出了什么事」。设置里「Sky Studio」一节最后那一行照它说，AI 被挡住时回给它的话也照它说
// （SkyCutGates.aiRefusal）。纯值，自检能单独编。
// 不管什么：一次失败怎么换成它（SkyStudioAccount.problem(for:)：没连上、回的不像话那两种要按界面语言写话）。

enum SkyStudioProblem: Equatable {
    /// Sky Studio 不认这把 Key（打错了、作废了、过期了）。
    case keyRejected(String)
    /// 这个 SkyCut 太老了，服务器要求先更新。
    case updateRequired(String, URL?)
    /// 没问成（断网、服务器出错、限频）：照旧用上一次的回答到 valid_until。
    case unreachable(String)
    /// 钥匙串要用户点一下「允许」才读得到 Key。
    case needsKeychainPermission
    /// 钥匙串拒绝了（存 / 读 / 删）。
    case keychain(String)
    /// 粘进来的不像一把 Sky Studio 的 Key。
    case notAKey
}
