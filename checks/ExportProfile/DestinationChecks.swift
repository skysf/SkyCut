import Foundation
@testable import SrtFlow

// The export destination is only ever touched off the main thread, with a deadline, and the finished video is handed
// over off the main thread (docs/bugfixes/2026-11-18-export-folder-chooser-freezes-app.md): real folders for the
// plain cases (there, missing, a file, no permission), a fake drive that never answers or is read-only for the rest,
// and one real export whose delivery is slowed down to see where it runs.
@MainActor enum DestinationChecks {
    static func run(root: URL, state: TimelineState, project: VideoEditProject, require: (Bool, String) -> Void) async {
        await realFolders(root: root, require: require)
        await stuckDrive(require: require)
        await panelState(root: root, require: require)
        typedPaths(require: require)
        await delivery(root: root, state: state, project: project, require: require)
    }

    private static func realFolders(root: URL, require: (Bool, String) -> Void) async {
        let probe = ExportDestinationProbe.shared
        let folder = root.appendingPathComponent("destination", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("Taken.mp4").path, contents: Data())
        let ready = await probe.inspect(folder, writeTest: true, deadline: 10)
        require(ready.problem == nil, "a writable folder passes: \(String(describing: ready.problem))")
        require(ready.contains("Taken.mp4") && ready.contains("taken.MP4") && !ready.contains("Free.mp4"),
                "taken names come from the listing, compared like the default macOS volumes")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".SrtFlow-write-check") }
        require(leftovers.isEmpty, "the write test leaves nothing behind: \(leftovers)")
        let missing = await probe.inspect(folder.appendingPathComponent("gone"), writeTest: false, deadline: 10)
        require(missing.problem == .missing, "a folder that is not there says so")
        let file = await probe.inspect(folder.appendingPathComponent("Taken.mp4"), writeTest: false, deadline: 10)
        require(file.problem == .notAFolder, "a file is not a folder")
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o555)
        defer { chmod(locked.path, 0o755) }
        let looked = await probe.inspect(locked, writeTest: false, deadline: 10)
        let written = await probe.inspect(locked, writeTest: true, deadline: 10)
        require(looked.problem == nil, "looking does not write (a redraw never creates files)")
        var refused = false
        if case .notWritable = written.problem { refused = true }
        require(refused, "a folder SkyCut may not write into is found out before the export: \(String(describing: written.problem))")
    }

    /// A drive that never answers, one that is read-only, and the cap on checks left stuck on one drive.
    private static func stuckDrive(require: (Bool, String) -> Void) async {
        let calls = Counter()
        var fake = ExportDestinationProbe.FileSystem.live
        fake.kind = { url in
            calls.add()
            // Longer than everything below together: the stuck checks are all still out when the fourth one comes.
            if url.path.hasPrefix("/Volumes/Stuck") { Thread.sleep(forTimeInterval: 8) }
            return .folder
        }
        fake.names = { _ in [] }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        fake.writeTest = { _ in calls.add(); return nil }
        let probe = ExportDestinationProbe(fileSystem: fake)

        let meter = MainThreadGapMeter()
        meter.start()
        let asked = ProcessInfo.processInfo.systemUptime
        let stuck = await probe.inspect(URL(fileURLWithPath: "/Volumes/Stuck/Videos"), writeTest: false, deadline: 0.5)
        let waited = ProcessInfo.processInfo.systemUptime - asked
        let gap = meter.stop()
        require(stuck.problem == .noResponse, "a drive that does not answer is reported as not responding")
        require(waited < 2, "and the answer comes at the deadline, not when the drive wakes: \(waited) s")
        require(gap < 0.5, "the main thread is free while the drive is stuck: longest gap \(gap) s")

        let readOnly = await probe.inspect(URL(fileURLWithPath: "/Volumes/ReadOnly/Videos"), writeTest: true, deadline: 5)
        require(readOnly.problem == .readOnlyVolume, "a read-only drive (NTFS) is said before the export")

        // Three checks are already out on the stuck drive (one above, two more now): the next one does not add a thread.
        calls.reset()
        async let second = probe.inspect(URL(fileURLWithPath: "/Volumes/Stuck/A"), writeTest: false, deadline: 4)
        async let third = probe.inspect(URL(fileURLWithPath: "/Volumes/Stuck/B"), writeTest: false, deadline: 4)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let fourth = await probe.inspect(URL(fileURLWithPath: "/Volumes/Stuck/C"), writeTest: false, deadline: 4)
        let other = await probe.inspect(URL(fileURLWithPath: "/Volumes/Fine/Videos"), writeTest: false, deadline: 4)
        _ = await (second, third)
        require(fourth.problem == .noResponse && calls.value == 3,
                "at most three checks wait on one stuck drive; the next answers at once (calls \(calls.value))")
        require(other.problem == nil, "a stuck drive does not hold up checks of another drive")
    }

    /// What the panel shows: remembered folder or the start folder; chosen / dropped folders taken only after a check.
    private static func panelState(root: URL, require: (Bool, String) -> Void) async {
        let start = root.appendingPathComponent("destination", isDirectory: true)
        let gone = root.appendingPathComponent("unplugged", isDirectory: true)
        let state = ExportDestinationState(folder: gone)
        await state.resolve(remembered: gone, fallback: start)
        require(state.folder == start, "a remembered folder that is gone falls back to the start folder")

        var fake = ExportDestinationProbe.FileSystem.live
        fake.kind = { url in
            if url.path.hasPrefix("/Volumes/Asleep") { Thread.sleep(forTimeInterval: 2) }
            return url.path.hasPrefix("/Volumes/Asleep") || url.path.hasPrefix("/Volumes/ReadOnly") ? .folder : FileSystemKind.live(url)
        }
        fake.isReadOnlyVolume = { $0.path.hasPrefix("/Volumes/ReadOnly") }
        fake.names = { url in url.path.hasPrefix("/Volumes/") ? [] : ExportDestinationProbe.FileSystem.live.names(url) }
        let asleep = URL(fileURLWithPath: "/Volumes/Asleep/Videos", isDirectory: true)
        let sleepy = ExportDestinationState(folder: asleep, probe: ExportDestinationProbe(fileSystem: fake),
                                            lookDeadline: 0.5, writeDeadline: 1)
        await sleepy.resolve(remembered: asleep, fallback: start)
        require(sleepy.folder == asleep && sleepy.report?.problem == .noResponse,
                "a remembered drive that does not answer is kept (it may be asleep) and said to be not responding")
        require(sleepy.windowStart.path == NSHomeDirectory() && state.windowStart == state.folder,
                "the macOS folder window never starts on a drive that does not answer")

        let dropped = start.appendingPathComponent("Taken.mp4")
        let problem = await state.use(dropped)
        require(problem == nil && state.folder.standardizedFileURL.path == start.standardizedFileURL.path,
                "a dropped file means the folder it is in")
        let readOnly = await sleepy.use(URL(fileURLWithPath: "/Volumes/ReadOnly/Videos", isDirectory: true))
        require(readOnly == .readOnlyVolume && sleepy.folder == asleep, "a read-only folder is refused and the old one kept")
        let before = await state.checkBeforeWriting()
        require(before.problem == nil && before.contains("Taken.mp4"), "the check before writing looks and writes again")
    }

    private static func typedPaths(require: (Bool, String) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cases: [(String, String?)] = [
            ("'/Volumes/My Passport/芹'", "/Volumes/My Passport/芹"),
            ("  \"/Volumes/My Passport/芹\"\n", "/Volumes/My Passport/芹"),
            ("/Volumes/My\\ Passport/Videos", "/Volumes/My Passport/Videos"),
            ("~/Movies", home + "/Movies"),
            ("file:///Volumes/My%20Passport/Videos/", "/Volumes/My Passport/Videos"),
            ("Movies", nil),
            ("", nil)
        ]
        for (typed, expected) in cases {
            let path = ExportDestinationState.url(typed: typed)?.path
            require(path == expected, "typed path \(typed.debugDescription) → \(String(describing: path)), expected \(String(describing: expected))")
        }
    }

    /// One real export; the delivery is held for 1.2 s on its own queue. The main thread must stay free meanwhile.
    private static func delivery(root: URL, state: TimelineState, project: VideoEditProject, require: (Bool, String) -> Void) async {
        let output = root.appendingPathComponent("delivered.mp4")
        let observed = DeliveryObservation()
        ExportDelivery.beforeMoveForChecks = {
            let meter = MainThreadGapMeter()
            meter.start()
            Thread.sleep(forTimeInterval: 1.2)
            observed.record(onMain: Thread.isMainThread, gap: meter.stop())
        }
        defer { ExportDelivery.beforeMoveForChecks = nil }
        let exporter = VideoEditExporter.shared
        exporter.export(for: project, state: state, to: output, subtitleStyle: .default, subtitleFontURL: nil)
        var sawDelivering = false
        for _ in 0..<1200 where exporter.isExporting {
            sawDelivering = sawDelivering || exporter.isDelivering
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = observed.value
        require(!exporter.isExporting && exporter.errorMessage == nil && FileManager.default.fileExists(atPath: output.path),
                "the slowed export still delivers: \(exporter.errorMessage ?? "")")
        require(result.ran && !result.onMain, "the finished video is moved onto the destination off the main thread")
        require(result.gap < 0.5, "the main thread stays free while the video is copied: longest gap \(result.gap) s")
        require(sawDelivering && !exporter.isDelivering, "the panel can say the video is being saved, and stops saying it")
    }
}

/// `FileManager` kind of a real path (the fakes fall back to it for real folders).
enum FileSystemKind {
    static func live(_ url: URL) -> ExportDestinationProbe.FileSystem.Kind {
        ExportDestinationProbe.FileSystem.live.kind(url)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
    var value: Int { lock.withLock { count } }
}

final class DeliveryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = (ran: false, onMain: false, gap: TimeInterval(0))
    func record(onMain: Bool, gap: TimeInterval) { lock.withLock { stored = (true, onMain, gap) } }
    var value: (ran: Bool, onMain: Bool, gap: TimeInterval) { lock.withLock { stored } }
}
