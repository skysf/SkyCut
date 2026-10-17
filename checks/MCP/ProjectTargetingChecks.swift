import Foundation
import SrtFlowMCPKit

// 一个碰工程的调用落在哪个工程、归谁、什么时候拒（`AIProjectTargeting` / `AIProjectOwnership`，2026-10-17 起一个会话一组工程，
// docs/plans/2026-10-17-multi-project-ai-editing.md 板 1、7 和 B 节）：
// - 没开过工程的会话：主窗口那个（没人剪就收下；别的会话还在剪就拒，安静 5 分钟以上算放手）；
// - 带 project 的是那一个；没带的是这个会话最后打开的；别的会话的 id 一律拒；关掉了的 / 不认识的 id 拒并列出自己的；
// - App 重启过（身份章的运行代号不一样）拒；主窗口那个的内容被用户换掉了（代号变了），原来剪它的会话拒；
// - open_project 一个已经开着的文件：自己的 / 没人剪的用它，别的会话还在剪就拒，安静久了接手；
// - 归属：收下 / 接手 / 关掉，最后打开的那个怎么退；到顶时列出能关的；
// - 相对路径：先按工程的文件夹，那里没有、会话后来点名的文件夹里有才用后来的（AIPathResolution）。

func runProjectTargetingChecks() {
    runDecideChecks()
    runOwnershipChecks()
    runOpenChecks()
    runPathResolutionChecks()
}

private let run = "run1"
private func stamp(_ id: String, generation: Int, name: String, path: String?) -> MCPBridge.ProjectStamp {
    MCPBridge.ProjectStamp(token: "\(run)-\(generation)", path: path, name: name, id: id)
}
private let main1 = AIOpenProject(id: "p1", stamp: stamp("p1", generation: 1, name: "Untitled", path: nil), isPrimary: true)
private let wedding = AIOpenProject(id: "p2", stamp: stamp("p2", generation: 2, name: "Wedding", path: "/tmp/t/Wedding.srtflowproj"), isPrimary: false)
private let trip = AIOpenProject(id: "p3", stamp: stamp("p3", generation: 3, name: "Trip", path: "/tmp/t/Trip.srtflowproj"), isPrimary: false)
private let now = Date(timeIntervalSince1970: 1_000_000)

private func decide(
    _ explicit: String?, session: String = "s1", remembered: MCPBridge.ProjectStamp? = nil,
    open: [AIOpenProject] = [main1, wedding, trip], ownership: AIProjectOwnership
) -> AIProjectTargeting.Decision {
    AIProjectTargeting.decide(explicitID: explicit, remembered: remembered, session: session, open: open,
                              ownership: ownership, now: now, run: run)
}

private func refusalText(_ decision: AIProjectTargeting.Decision) -> String {
    if case .refuse(let text) = decision { return text }
    return ""
}

private func runDecideChecks() {
    var owners = AIProjectOwnership()
    checkEqual(decide(nil, ownership: owners), .adopt("p1"), "a session that never touched a project takes the free main-window project")

    owners.noteCall(session: "s1", at: now)
    owners.own("p1", session: "s1", client: "Claude Code", token: main1.stamp.token)
    checkEqual(decide(nil, ownership: owners), .use("p1"), "then calls without project go to it")
    owners.own("p2", session: "s1", client: "Claude Code", token: wedding.stamp.token)
    checkEqual(decide(nil, ownership: owners), .use("p2"), "after opening p2, calls without project go to p2 (the last opened)")
    checkEqual(decide("p1", ownership: owners), .use("p1"), "project=p1 still reaches p1")

    // 别的会话的工程：带它的 id 来一律不做。
    owners.noteCall(session: "s2", at: now)
    owners.own("p3", session: "s2", client: "Codex", token: trip.stamp.token)
    let held = refusalText(decide("p3", ownership: owners))
    check(held.contains("another AI session (Codex)") && held.contains("only that session"), "another session's project is refused: \(held)")
    check(held.contains("Nothing was changed"), "says nothing was changed")
    check(held.contains("Your open projects: p1 Untitled (never saved); p2 Wedding (/tmp/t/Wedding.srtflowproj)"),
          "lists the caller's own projects")
    check(held.contains("open_project or new_project"), "says how to get a project of its own")

    // 主窗口那个被别的会话收下了：那个会话还在剪就不给；安静 5 分钟以上算放手了，接手。
    var mainHeld = AIProjectOwnership()
    mainHeld.noteCall(session: "s2", at: now.addingTimeInterval(-60))
    mainHeld.own("p1", session: "s2", client: "Claude", token: main1.stamp.token)
    let busy = refusalText(decide(nil, session: "s1", ownership: mainHeld))
    check(busy.contains("another AI session (Claude)"), "the main window's project held by an active session is refused: \(busy)")
    mainHeld.noteCall(session: "s2", at: now.addingTimeInterval(-AIProjectOwnership.releaseAfter - 1))
    checkEqual(decide(nil, session: "s1", ownership: mainHeld), .adopt("p1"),
               "after the other session was quiet for \(Int(AIProjectOwnership.releaseAfter / 60)) minutes, the main-window project is taken over")
    checkEqual(refusalText(decide("p1", session: "s1", ownership: mainHeld)).isEmpty, false,
               "but naming another session's id is never a takeover")

    // 不认识 / 关掉了的 id。
    let missing = refusalText(decide("p9", ownership: owners))
    check(missing.contains("no project p9 is open") && missing.contains("Your open projects"), "an unknown id is refused with the caller's list")
    let closedCurrent = refusalText(decide(nil, open: [main1, trip], ownership: owners))
    check(closedCurrent.contains("no project p2 is open"), "the last opened was closed (by the user): calls without project are refused, not moved")

    // App 重启过：小程序记着的身份章是上一次运行的。
    let old = MCPBridge.ProjectStamp(token: "run0-7", path: "/tmp/t/Wedding.srtflowproj", name: "Wedding", id: "p2")
    let restarted = refusalText(decide("p2", remembered: old, ownership: owners))
    check(restarted.contains("restarted") && restarted.contains("start again at p1"), "an older run's project: SrtFlow was restarted")
    check(restarted.contains("open_project with path \"/tmp/t/Wedding.srtflowproj\""), "says how to get it back")

    // 主窗口那个的内容被用户换掉了：代号变了，原来剪它的会话不能接着改。
    let replacedMain = AIOpenProject(id: "p1", stamp: stamp("p1", generation: 9, name: "Other", path: "/tmp/t/Other.srtflowproj"), isPrimary: true)
    let replaced = refusalText(decide("p1", open: [replacedMain, wedding], ownership: owners))
    check(replaced.contains("the user opened another project"), "the main window's content was replaced: refused: \(replaced)")
}

private func runOwnershipChecks() {
    var owners = AIProjectOwnership()
    owners.own("p2", session: "s1", client: "A", token: "t2")
    owners.own("p3", session: "s1", client: "A", token: "t3")
    checkEqual(owners.current(of: "s1"), "p3", "the last opened is the current one")
    owners.release("p3")
    checkEqual(owners.current(of: "s1"), "p2", "closing the current one falls back to the most recently opened of the rest")
    owners.own("p2", session: "s2", client: "B", token: "t2")
    check(owners.current(of: "s1") == nil && owners.current(of: "s2") == "p2", "a takeover moves the project to the new session's list")
    owners.retoken("p2", token: "t9")
    checkEqual(owners.owners["p2"]?.token, "t9", "the owner's own reload keeps the project with the new token")
    check(owners.isActive("s2", at: now) == false, "a session that never called is not active")
    owners.noteCall(session: "s2", at: now)
    check(owners.isActive("s2", at: now.addingTimeInterval(AIProjectOwnership.releaseAfter - 1)), "active within five minutes")
    check(!owners.isActive("s2", at: now.addingTimeInterval(AIProjectOwnership.releaseAfter + 1)), "released after five minutes")

    let cap = AIProjectTargeting.capReached(limit: 8, closable: [wedding.stamp])
    check(cap.contains("8 projects open") && cap.contains("close_project") && cap.contains("p2 Wedding"),
          "the cap message lists what can be closed: \(cap)")
}

private func runOpenChecks() {
    var owners = AIProjectOwnership()
    checkEqual(AIProjectTargeting.decideOpen(existing: wedding, session: "s1", ownership: owners, now: now), .adopt("p2"),
               "opening a file nobody edits takes it")
    owners.own("p2", session: "s1", client: "A", token: wedding.stamp.token)
    checkEqual(AIProjectTargeting.decideOpen(existing: wedding, session: "s1", ownership: owners, now: now), .use("p2"),
               "opening your own open file gives you its id")
    owners.noteCall(session: "s1", at: now)
    let refused = AIProjectTargeting.decideOpen(existing: wedding, session: "s2", ownership: owners, now: now)
    check(refusalText(refused).contains("editing it right now"), "another session editing it right now: refused")
    let later = now.addingTimeInterval(AIProjectOwnership.releaseAfter + 1)
    checkEqual(AIProjectTargeting.decideOpen(existing: wedding, session: "s2", ownership: owners, now: later), .adopt("p2"),
               "after five quiet minutes the other session lets go and the file is taken over")
}

private func runPathResolutionChecks() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-path-resolution-\(getpid())", isDirectory: true)
    let projectFolder = root.appendingPathComponent("Wedding", isDirectory: true)
    let laterFolder = root.appendingPathComponent("B-roll", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        for folder in [projectFolder, laterFolder] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for file in [projectFolder.appendingPathComponent("C0001.MP4"), laterFolder.appendingPathComponent("C0001.MP4"),
                     laterFolder.appendingPathComponent("drone.mp4")] {
            try Data([0]).write(to: file)
        }
    } catch {
        check(false, "path resolution fixtures could not be written: \(error)")
        return
    }
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    func resolve(_ path: String, _ preferred: URL?, _ fallback: URL?) -> String {
        AIPathResolution.resolve(path, preferred: preferred, fallback: fallback, exists: exists).path
    }
    let wedding = projectFolder.standardizedFileURL.path
    let broll = laterFolder.standardizedFileURL.path
    checkEqual(resolve("C0001.MP4", projectFolder, laterFolder), wedding + "/C0001.MP4",
               "a name in both folders resolves in the project's own folder (another sub-agent's folder never wins)")
    checkEqual(resolve("drone.mp4", projectFolder, laterFolder), broll + "/drone.mp4",
               "a file only in the folder the session opened later is found there (one AI, a second media folder)")
    checkEqual(resolve("Exports/cut.mp4", projectFolder, laterFolder), wedding + "/Exports/cut.mp4",
               "a file that does not exist yet (an output) stays in the project's folder")
    checkEqual(resolve("drone.mp4", laterFolder, laterFolder), broll + "/drone.mp4", "one folder: plain resolution")
    checkEqual(resolve("/tmp/x.mp4", projectFolder, laterFolder), "/tmp/x.mp4", "an absolute path is used as given")
}
