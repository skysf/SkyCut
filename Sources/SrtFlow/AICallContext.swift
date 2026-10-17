import Foundation

// MARK: - 这一次 AI 调用是谁、剪哪个工程（task-local）
//
// 管什么：路由在交给工具之前，把「哪个会话、哪个工程（短 id）」放进一个 task-local（`AICallContext.current`），工具里任何地方要问
// 「当前文件夹」「这个任务归谁」都按它去问 —— 几个会话、几个子代理并排调用时各是各的，七十多处用工作区的代码不用改签名。
// 不管什么：会话归属的规矩（AIProjectTargeting）、文件夹的规矩（AIWorkspace）。
//
// **只放「是谁」，不放会变的东西**：文件夹不抄进来 —— 调用当中 open_folder 换了这个会话的文件夹，同一个调用接着算成片放哪、
// 列表写给谁看，都要拿换过的那个（docs/bugfixes/2026-10-17-open-folder-reports-previous-output-folder.md）。
//
// 为什么（docs/plans/2026-10-17-multi-project-ai-editing.md D 节）：以前「当前文件夹」全 App 一份（`AIWorkspace.current`），
// 几个子代理各 `open_folder` 一个文件夹时，谁最后开的算谁的 —— 相对路径和成片放哪会串台。

struct AICallContext: Sendable {
    /// 哪个会话（小程序的随机号；老小程序不带时当成一个会话：`AIProjectSessions.anonymous`）。
    var session: String?
    /// 哪个客户端（横幅、拒绝的话里说「另一个 AI 会话（Codex）」用）。
    var client: String = "AI"
    /// 这一次落在哪个工程上（短 id）；不碰工程的调用是 nil。
    var project: String?
    /// 这一次起的任务在哪个工程上按停止时跟着停（方案 E 节）：碰工程的就是 `project`，不碰工程的是这个会话最后打开的那个（还没开过就是主窗口那个）。
    var stopsWith: String?

    @TaskLocal static var current: AICallContext?
}
