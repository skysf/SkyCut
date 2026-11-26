import Foundation

// MARK: - What Restart and Update waits for (pure)
//
// What it does: the running work a restart would cut short, as plain values; the rows the busy popover lists, in order;
// and whether the restart can go now. It waits for exports, the AI's round on any open project, the Compress / Burn In
// queue, subtitle generation and translation, and the Sky Studio tasks that would not survive a restart: every one except
// the voice library's design / enroll orders, which SkyStudioVoiceLibraryOrders follows across restarts. (A paid result
// still on its way is otherwise lost to the timeline: SkyCut does not take over earlier cloud tasks at launch,
// docs/architecture/sky-studio-jobs.md.) A screen recording blocks the restart as well: the popover's note line, not a row.
// What it doesn't: read the app's stores (AppUpdateBusyProbe), restart (AppUpdateRestart), the words (AppUpdatePopover).
// Rules: docs/architecture/app-updates.md "Restart and Update".

struct AppUpdateBusy: Equatable, Sendable {
    struct Export: Equatable, Sendable {
        var title: String
        var progress: Double?
    }

    struct AIEditing: Equatable, Sendable {
        var projectName: String
        /// The project of the window whose popover lists it ("The AI is editing this project").
        var isThisProject: Bool
    }

    var exports: [Export] = []
    var aiEditing: [AIEditing] = []
    var compressLeft = 0
    var burnInLeft = 0
    var generatingSubtitles = false
    var translatingSubtitles = false
    /// Sky Studio tasks running that a restart would cut off (`cloudTaskBlocksRestart`).
    var cloudTasks = 0
    /// A screen recording is running or settling (ScreenRecordingCoordinator.isBusy).
    var recording = false

    enum Row: Equatable, Sendable {
        case export(title: String, progress: Double?)
        case aiThisProject
        case aiProject(name: String)
        case compress(left: Int)
        case burnIn(left: Int)
        case generatingSubtitles
        case translatingSubtitles
        case cloudTasks(Int)
    }

    /// The popover's rows: exports, the AI (this window's project first), the queues, subtitles, Sky Studio.
    var rows: [Row] {
        var rows = exports.map { Row.export(title: $0.title, progress: $0.progress) }
        if aiEditing.contains(where: \.isThisProject) { rows.append(.aiThisProject) }
        rows += aiEditing.filter { !$0.isThisProject }.map { Row.aiProject(name: $0.projectName) }
        if compressLeft > 0 { rows.append(.compress(left: compressLeft)) }
        if burnInLeft > 0 { rows.append(.burnIn(left: burnInLeft)) }
        if generatingSubtitles { rows.append(.generatingSubtitles) }
        if translatingSubtitles { rows.append(.translatingSubtitles) }
        if cloudTasks > 0 { rows.append(.cloudTasks(cloudTasks)) }
        return rows
    }

    /// Nothing to wait for: the restart goes now (through the normal quit flow).
    var isIdle: Bool { rows.isEmpty && !recording }

    /// AIJobs kinds whose Sky Studio orders SkyCut follows across a restart (SkyStudioVoiceLibraryOrders, voice-library.md
    /// section 10 item 11): the restart does not wait for them.
    static let survivingCloudKinds: Set<String> = ["voice_design", "voice_enroll"]

    /// Whether a running Sky Studio task of this AIJobs kind holds the restart (nil: started outside the AI's jobs, so
    /// nothing follows it after a restart either).
    static func cloudTaskBlocksRestart(kind: String?) -> Bool {
        guard let kind else { return true }
        return !survivingCloudKinds.contains(kind)
    }
}

// MARK: - The Settings status line under the version (pure: which line; the view formats the time)

enum AppUpdateStatusLine: Equatable, Sendable {
    case checking
    case downloading(percent: Int?)
    case ready(AppUpdateVersion)
    case available(AppUpdateVersion)
    case checkedToday(Date)
    case checkedYesterday(Date)
    case checkedOn(Date)
    case checkFailed
    case notChecked

    /// `lastUpToDate`: when a check last found nothing newer (kept across launches).
    static func make(_ state: AppUpdateState, lastUpToDate: Date?, now: Date, calendar: Calendar) -> AppUpdateStatusLine {
        switch state.phase {
        case .downloading: return .downloading(percent: state.progress.map { Int(($0 * 100).rounded(.down)) })
        case .ready: return state.offer.map { .ready($0.version) } ?? .notChecked
        case .available: return state.offer.map { .available($0.version) } ?? .notChecked
        case .idle: break
        }
        if state.checking { return .checking }
        if state.lastCheckFailed { return .checkFailed }
        guard let last = lastUpToDate else { return .notChecked }
        if calendar.isDate(last, inSameDayAs: now) { return .checkedToday(last) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(last, inSameDayAs: yesterday) {
            return .checkedYesterday(last)
        }
        return .checkedOn(last)
    }
}
