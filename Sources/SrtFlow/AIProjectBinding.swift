import Foundation
import SrtFlowMCPKit

// MARK: - 哪些调用碰工程、工程的代号怎么写
//
// 管什么：哪些调用碰开着的工程（`usesProject`）、工程身份章里的代号（`token`）。纯值，自检直接测。
// 不管什么：落在哪个工程、归谁、什么时候拒（AIProjectTargeting / AIProjectSessions，2026-10-17 起一个会话一组工程）；
// 什么时候查（AIToolRouter：排到这个调用、动窗口之前）。
//
// 由来（docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md）：几个会话共用一个 App 时，改动只许落在会话自己的工程上。
// 长期约束：docs/architecture/ai-control-mcp.md 第四节第 46 条。

enum AIProjectBinding {
    /// 这一次运行的代号：App 重启过，之前记着的工程就不算还开着（重启后开着的是空的 Untitled，或者用户自己开的别的）。
    static let runID = String(UUID().uuidString.prefix(8))

    static func token(generation: Int, run: String = runID) -> String {
        "\(run)-\(generation)"
    }

    /// 这次调用碰不碰开着的工程。**读也算**：看到的是别人的时间线，下一步就照着它改错了。
    /// open_project / new_project / close_project 是开、关工程的：另走一条（AIProjectOpenTools），做成了小程序跟着记。只碰文件、设置、任务的不查。
    static func usesProject(_ tool: MCPToolName, _ args: AIToolArguments) -> Bool {
        switch tool {
        case .getStatus, .getSettings, .setSettings, .openFolder, .readDocument, .recipes, .saveRecipe, .manageFiles, .findAudio,
             .generateMedia, .compressVideos, .burnSubtitles, .convertSubtitles, .getJob, .cancelJob,
             .openProject, .newProject, .closeProject:
            return false
        case .setView:
            // 带 project 只改那一个（要核对是这个会话的）；不带改这个会话的默认和它开着的工程，不落在某一个上。
            return args.has("project")
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
             .exportVideo, .exportSubtitles, .undo, .seek:
            return true
        }
    }
}
