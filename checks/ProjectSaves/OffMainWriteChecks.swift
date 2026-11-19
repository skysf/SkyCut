import Foundation
import SrtFlowCore
@testable import SrtFlow

// Two more writes that must not wait on a user's drive on the main thread
// (docs/bugfixes/2026-11-19-subtitle-and-version-saves-touch-drives-on-main.md):
// - the subtitle editor's Save / Export As (SubtitleFileSave): the drive held, the main thread stays free, the answer is
//   "not responding" at the deadline, and the write that lands later still tells the request that asked; two requests at
//   once each hear their own end;
// - a saved version around an AI round (ProjectVersionStore): its media may be on a sleeping drive, and asking a media
//   file anything there takes a second here — saving the version asks nothing, so the main thread stays free.
@MainActor enum OffMainWriteChecks {
    static func run(_ checks: Checks, root: URL) async {
        await subtitleWrite(checks, root: root)
        await subtitleRequests(checks, root: root)
        versionMedia(checks, root: root)
    }

    private static let subtitle = SubtitleFileSave.data(
        SubtitleDocumentModel(cues: [SubtitleCue(start: 0, end: 1, text: "Written late")]), format: .srt
    )

    private static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// A subtitle file on a drive that holds the write: "not responding" at the deadline, main thread free, the late
    /// landing told to its request.
    private static func subtitleWrite(_ checks: Checks, root: URL) async {
        let drive = HeldDrive()
        let perform = SubtitleFileSave.perform
        SubtitleFileSave.perform = { data, url, replacing in
            drive.hold()
            return try NewFileClaim.write(data, to: url, replacing: replacing)
        }
        let url = root.appendingPathComponent("Held.srt")
        var landed: [SubtitleFileSave.Answer] = []
        let meter = MainThreadGap()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let answer = await SubtitleFileSave.write(subtitle, to: url, replacing: true, deadline: 0.5) { landed.append($0) }
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        checks.require(answer == .notResponding && waited < 1.5 && landed.isEmpty,
                       "a subtitle write on a drive that does not answer says so at the deadline: \(answer), \(waited) s")
        checks.require(gap < 0.5, "the main thread is free while a subtitle file waits on its drive: longest gap \(gap) s")
        drive.open()
        let ended = await until(5) { !landed.isEmpty }
        checks.require(ended && landed == [.written] && text(url).contains("Written late"),
                       "the write that lands after the deadline still tells the request that asked: \(landed)")
        SubtitleFileSave.perform = perform
    }

    /// Two writes asked at once, one to a folder that does not exist: each request hears its own end.
    private static func subtitleRequests(_ checks: Checks, root: URL) async {
        let good = root.appendingPathComponent("Answered.srt")
        let bad = root.appendingPathComponent("No such folder", isDirectory: true).appendingPathComponent("Answered.srt")
        var heard: [String: SubtitleFileSave.Answer] = [:]
        let first = Task { await SubtitleFileSave.write(subtitle, to: good, replacing: false) { heard["good"] = $0 } }
        let second = Task { await SubtitleFileSave.write(subtitle, to: bad, replacing: false) { heard["bad"] = $0 } }
        let answers = (await first.value, await second.value)
        var badFailed = false
        if case .failed = answers.1, case .failed? = heard["bad"] { badFailed = true }
        checks.require(answers.0 == .written && heard["good"] == .written && badFailed,
                       "two subtitle writes at once: each request hears its own end (\(answers), \(heard))")
    }

    /// A saved version of a project whose media sits on a slow drive: no media file is asked anything on the main thread.
    private static func versionMedia(_ checks: Checks, root: URL) {
        let project = makeProject("Version of slow media", in: root)
        let media = root.appendingPathComponent("On a sleeping drive.mov")
        _ = project.perform(rebuildsPreview: false) { state in
            state.mainClips = [EditClip(sourceURL: media, sourceDuration: 2, timelineStart: 0)]
        }
        project.fileWriter.cancelAutosave()
        let lookUp = MediaRecord.lookUp
        let asked = AskedCount()
        MediaRecord.lookUp = { url in
            // Only the main thread's questions are slow here: the project's own file is written off it.
            guard Thread.isMainThread else { return lookUp(url) }
            asked.add()
            Thread.sleep(forTimeInterval: 1)
            return lookUp(url)
        }
        let meter = MainThreadGap()
        meter.start()
        let saved = ProjectVersionStore.for(project).save(project.state, kind: .beforeRound)
        let gap = meter.stop()
        MediaRecord.lookUp = lookUp
        checks.require(saved.version != nil, "the version is saved (\(saved))")
        checks.require(asked.count == 0 && gap < 0.5,
                       "saving a version asks no media file anything on the main thread (asked \(asked.count), longest gap \(gap) s)")
        let file = saved.version.map { text($0.url) } ?? ""
        checks.require(file.contains(media.lastPathComponent), "the version still names its media")
        _ = OpenProjects.shared.close(project)
    }
}

/// A drive that holds each write until the check opens it (at most 3 s).
final class HeldDrive: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false

    func hold() {
        condition.lock()
        let end = Date().addingTimeInterval(3)
        while !opened, condition.wait(until: end) {}
        condition.unlock()
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

/// How many questions reached the slow media drive on the main thread.
final class AskedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
