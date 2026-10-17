import Foundation

// MARK: - AI 给的相对路径按哪个文件夹解析（2026-10-17 起：几个工程、几个子代理）
//
// 管什么：一个调用里 AI 给的相对路径（add_clips 的 path、look 的 file……）落到哪个文件上。纯值，自检直接测
// （checks/MCP/ProjectTargetingChecks.swift）。
// 不管什么：记哪个文件夹（AIWorkspace：每个工程打开 / 新建时点名的那个、每个会话最后点名的那个）；调用落在哪个工程（AIProjectTargeting）。
//
// 规矩（docs/plans/2026-10-17-multi-project-ai-editing.md D 节）：碰工程的调用**先按这个工程的文件夹**解析 —— 几个子代理各 open_folder 一个
// 文件夹时，「最后点名的那个」是别的子代理的，同名的素材（相机的 C0001.MP4）会串台。那里没有这个文件、而这个会话后来点名的文件夹里有，
// 就用后来点名的那个：一个 AI 先建好工程、再 open_folder 第二个素材文件夹、照它列出来的相对路径放素材，以前（只有一个「打开的文件夹」）
// 是这么用的，不能因为多了工程就找不到。两边都有同名文件时仍按工程的（宁可和以前不一样，也不串到别的子代理的文件夹里）。
// 要写的新文件（成片的 path）不存在，永远按工程的文件夹。

enum AIPathResolution {
    /// `preferred`：这个工程的文件夹（没有就是这个会话最后点名的）；`fallback`：这个会话最后点名的文件夹。
    static func resolve(_ path: String, preferred: URL?, fallback: URL?, exists: (URL) -> Bool) -> URL {
        let url = AIFormat.url(fromPath: path, relativeTo: preferred)
        guard let fallback, fallback.standardizedFileURL != preferred?.standardizedFileURL, !exists(url) else { return url }
        let other = AIFormat.url(fromPath: path, relativeTo: fallback)
        return exists(other) ? other : url
    }
}
