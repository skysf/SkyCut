import Foundation

// MARK: - What is running right now, for Restart and Update (reads the app's own stores)
//
// What it does: fills AppUpdateBusy from the stores that already know: the exporter (one for the whole App), each open
// project's AI round and the AI's running jobs on it, the Compress and Burn In queues, subtitle generation and translation,
// the Sky Studio tasks in the toolbar's cloud list (the voice library's design / enroll orders excepted: they survive a
// restart), and the screen recording. Main actor, cheap: AppUpdater asks it once a second while a restart waits, the busy
// popover whenever it redraws.
// What it doesn't: decide (AppUpdateBusy.isIdle) or restart (AppUpdater, AppUpdateRestart).
// Rules: docs/architecture/app-updates.md "Restart and Update".

@MainActor
enum AppUpdateBusyProbe {
    /// `project`: the window asking ("The AI is editing this project"); nil when only whether anything runs matters.
    static func current(for project: VideoEditProject?) -> AppUpdateBusy {
        var busy = AppUpdateBusy()
        let exporter = VideoEditExporter.shared
        if exporter.isExporting || exporter.isDelivering {
            busy.exports = [.init(title: exporter.owner?.name ?? "", progress: exporter.isExporting ? exporter.progress : nil)]
        }
        let jobs = AIJobs.shared.running.filter { AppUpdateBusy.cloudTaskBlocksRestart(kind: $0.kind.rawValue) }
        for open in OpenProjects.shared.all {
            let working = AISession.shared.round(for: open).phase == .working
            guard working || jobs.contains(where: { $0.stopsWith == open.shortID }) else { continue }
            busy.aiEditing.append(.init(projectName: open.projectName, isThisProject: open === project))
        }
        busy.compressLeft = remaining(EncodeQueue.compress)
        busy.burnInLeft = remaining(EncodeQueue.burnIn)
        if #available(macOS 26.0, *) { busy.generatingSubtitles = TranscriptionTask.shared.isRunning }
        busy.translatingSubtitles = TranslationJobCoordinator.shared.isBusy
        busy.cloudTasks = cloudTasks()
        if #available(macOS 15.0, *) { busy.recording = ScreenRecordingCoordinator.shared.isBusy }
        return busy
    }

    private static func remaining(_ queue: EncodeQueue) -> Int {
        guard queue.isRunning else { return 0 }
        return queue.items.filter { [.waiting, .probing, .running].contains($0.status) }.count
    }

    /// Running Sky Studio tasks a restart would cut off: generations (and voiceovers, voice changes, characters) still
    /// without a result, and running upscales; not the voice library's orders, which SkyStudioVoiceLibraryOrders follows.
    private static func cloudTasks() -> Int {
        let generations = SkyStudioGenerationActivity.shared.runs.filter { run in
            guard run.issue == nil else { return false }
            let kind = run.aiJobID.flatMap { AIJobs.shared.job($0)?.kind.rawValue }
            return AppUpdateBusy.cloudTaskBlocksRestart(kind: kind)
        }
        let upscales = UpscaleActivity.shared.jobs.filter { job in
            if case .running = job.state { return true }
            return false
        }
        return generations.count + upscales.count
    }
}
