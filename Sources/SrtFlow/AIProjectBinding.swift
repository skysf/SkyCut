import Foundation
import SrtFlowMCPKit

// MARK: - 几个 AI 会话共用一个 SrtFlow：改动只落在会话自己的工程上
//
// 管什么：哪些调用碰开着的工程（`usesProject`）、开着的是不是这个会话记着的那一个、不是的话怎么跟 AI 说（`refusal`）、
// 工程的代号怎么写（`token`）。纯值，自检直接测。
// 不管什么：会话记着哪一个（小程序的 MCPSessionProject）；什么时候查、谁换的工程记在哪（AIToolRouter：排到这个调用、
// 动窗口之前查；AI 的 open_project / new_project 做成时记下是哪个会话换的）。
//
// 为什么（docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md）：SrtFlow 一次只开一个工程，谁 open_project
// 谁说了算。2026-10-06 盲测里桌面版的会话把 App 切到了用户自己的工程，这边的会话接着改 —— 按 id 改的找不到 id 才没出事，
// 不按 id 的（放素材、加字、改画布）就会落进别人的工程。长期约束：docs/architecture/ai-control-mcp.md 第四节第 46 条。

enum AIProjectBinding {
    /// 这一次运行的代号：App 重启过，之前记着的工程就不算还开着（重启后开着的是空的 Untitled，或者用户自己开的别的）。
    static let runID = String(UUID().uuidString.prefix(8))

    static func token(generation: Int, run: String = runID) -> String {
        "\(run)-\(generation)"
    }

    /// 这次调用碰不碰开着的工程。**读也算**：看到的是别人的时间线，下一步就照着它改错了。
    /// open_project / new_project 是换工程的：不查，做成了小程序换成新的那一个。只碰文件、设置、任务的不查。
    static func usesProject(_ tool: MCPToolName, _ args: AIToolArguments) -> Bool {
        switch tool {
        case .getStatus, .setView, .openFolder, .readDocument, .recipes, .saveRecipe, .manageFiles, .findAudio,
             .generateMedia, .compressVideos, .burnSubtitles, .convertSubtitles, .getJob, .cancelJob,
             .openProject, .newProject:
            return false
        case .look:
            return !args.has("file") && !args.has("files")
        case .listen, .transcribe:
            return !args.has("file")
        case .addVoiceover:
            // 只是下载 SrtFlow 自己的声音，不碰工程。
            return (try? args.bool("download_voices")) != true
        case .recordScreen:
            // 录完进时间线的才碰工程：开录（除非只留文件）、处置上次的选「放进时间线」。停止只是停那一段录制。
            switch (try? args.string("action"))?.lowercased() {
            case "start": return (try? args.bool("add_to_timeline")) != false
            case "resolve": return (try? args.string("decision"))?.lowercased() == "add"
            default: return false
            }
        case .saveProject, .getTimeline, .upscaleClip, .addClips, .editClip, .setKeyframes, .setTrack, .splitClip,
             .freezeFrame, .cutSpeech, .cutToBeat, .deleteItems, .duplicateItems, .setTransition, .setText, .setShape,
             .setFilter, .setCanvas, .generateSubtitles, .translateSubtitles, .getSubtitles, .editSubtitles,
             .exportVideo, .undo, .seek:
            return true
        }
    }

    /// 谁把开着的工程换成了现在这个：AI 的 open_project / new_project 做成时记下（会话号、客户端名）；没记过 = 用户在界面上换的。
    struct Switch: Equatable {
        var session: String?
        var client: String
    }

    /// 开着的不是这个会话的工程时回给 AI 的话（这次调用不做）；是同一个工程、会话还没碰过工程、或者正是它自己刚换的
    /// （并排发来的几个调用，排在 open_project 后面的那几个），就是 nil。
    static func refusal(
        expected: MCPBridge.ProjectStamp?, current: MCPBridge.ProjectStamp, session: String?, switchedBy: Switch?,
        run: String = runID
    ) -> String? {
        guard let expected, !expected.isSameProject(as: current) else { return nil }
        if let switchedBy, let session, switchedBy.session == session { return nil }
        let why: String
        if !expected.token.hasPrefix(run + "-") {
            why = "SrtFlow was restarted after your last call"
        } else if let switchedBy {
            why = "another AI session (\(switchedBy.client)) switched SrtFlow to another project"
        } else {
            why = "the user switched SrtFlow to another project"
        }
        var text = "Not done: \(why), so the project you were working on is not open. Yours: \(describe(expected)). "
            + "Open now: \(describe(current)). Nothing was changed. SrtFlow has one project open at a time: ask the user "
            + "which one to work on before switching (someone may be using the open one)."
        if let path = expected.path {
            text += " To go back to yours, call open_project with path \"\(path)\"."
        } else {
            text += " Yours was never saved, so it cannot be opened again."
        }
        if let path = current.path {
            text += " To work on the open one instead, call open_project with path \"\(path)\"."
        } else {
            text += " The open one was never saved: to work on it, ask the user to save it first (Command-S), "
                + "then call open_project with its path."
        }
        return text
    }

    private static func describe(_ stamp: MCPBridge.ProjectStamp) -> String {
        guard let path = stamp.path else { return "\(stamp.name) (never saved)" }
        return "\(stamp.name) (\(path))"
    }
}
