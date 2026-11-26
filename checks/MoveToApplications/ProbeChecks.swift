import Foundation

// RunningBundleProbe on real processes (scripts/check-move-to-applications.sh). "Open" is the app itself: a process whose
// executable is in the bundle's Contents/MacOS/. A helper running from Contents/Helpers/ (as an AI client's skycut-mcp
// does, SkyCut open or not) is not open, and the move goes ahead over it with the live probe, the helper still running
// afterwards. The app's executable running is open, by any letter case, until it exits; a sibling folder's app is not.
// The executables are copies of /bin/sleep.

enum ProbeChecks {
    static func run(in root: URL, check: (Bool, String) -> Void) throws {
        check(RunningBundleProbe.isInside("/Applications/SkyCut.app/Contents/MacOS/SkyCut", "/Applications/SkyCut.app"),
              "inside: the app's own executable")
        check(RunningBundleProbe.isInside("/Applications/skycut.app/Contents/Helpers/skycut-mcp", "/Applications/SkyCut.app/"),
              "inside: another letter case, a trailing slash")
        check(!RunningBundleProbe.isInside("/Applications/SkyCut.app", "/Applications/SkyCut.app"), "inside: not the folder itself")
        check(!RunningBundleProbe.isInside("/Applications/SkyCut.app 2/Contents/MacOS/SkyCut", "/Applications/SkyCut.app"),
              "inside: not a sibling whose name starts the same")

        let folder = root.appendingPathComponent("probe")
        let bundle = folder.appendingPathComponent("SkyCut.app")
        let sibling = folder.appendingPathComponent("SkyCut.app 2")
        let helperPath = bundle.appendingPathComponent("Contents/Helpers/skycut-mcp")
        let appPath = bundle.appendingPathComponent("Contents/MacOS/SkyCut")
        let siblingApp = sibling.appendingPathComponent("Contents/MacOS/SkyCut")
        for executable in [helperPath, appPath, siblingApp] {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        }
        check(!RunningBundleProbe.isRunning(bundle), "live: nothing runs from the bundle yet")

        let outside = try start(siblingApp)
        defer { outside.terminate() }
        check(waitUntil { RunningBundleProbe.isRunning(sibling) }, "live: the sibling folder's app is seen")
        check(!RunningBundleProbe.isRunning(bundle), "live: a sibling folder's app doesn't count")

        let helper = try start(helperPath)
        defer { helper.terminate() }
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        check(waitUntil { RunningBundleProbe.processes(under: helpers).contains(helper.processIdentifier) }, "live: the helper is seen running")
        check(!RunningBundleProbe.isRunning(bundle), "live: only a helper running: not open (an AI client's skycut-mcp)")

        let app = try start(appPath)
        check(waitUntil { RunningBundleProbe.isRunning(bundle) }, "live: the app's own executable running: open")
        check(RunningBundleProbe.processes(inside: bundle) == [app.processIdentifier], "live: the app's process, not the helper's")
        check(RunningBundleProbe.isRunning(folder.appendingPathComponent("SKYCUT.app")), "live: the bundle named in another letter case: still open")
        app.terminate()
        app.waitUntilExit()
        check(waitUntil { !RunningBundleProbe.isRunning(bundle) }, "live: not open once the app exits, the helper still running")
        try moveOverRunningHelper(root, check: check)
    }

    /// The live probe in the mover: a helper running from the app in Applications doesn't stop the move; the old app goes
    /// to the (scratch) Trash under it, and the helper keeps running. The app's own executable running does stop it.
    private static func moveOverRunningHelper(_ root: URL, check: (Bool, String) -> Void) throws {
        let scene = try MoveScene(root, name: "probe-helper")
        let original = try Fixture.app(in: scene.source, marker: "new")
        let existing = try Fixture.app(in: scene.applications, marker: "old")
        let helperPath = existing.appendingPathComponent("Contents/Helpers/skycut-mcp")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: helperPath.path)
        var mover = scene.mover()
        mover.isRunning = RunningBundleProbe.isRunning
        let helper = try start(helperPath)
        defer { helper.terminate() }
        check(waitUntil { RunningBundleProbe.processes(under: existing.appendingPathComponent("Contents/Helpers")).contains(helper.processIdentifier) },
              "move over a helper: the helper is running")
        let outcome = mover.move(original)
        check(MoverChecks.plain(outcome) == MoverChecks.plain(.moved(existing)), "move over a helper: the move goes ahead (got \(outcome))")
        check(Fixture.marker(of: existing) == "new" && Fixture.marker(of: scene.trash.appendingPathComponent("SkyCut.app")) == "old",
              "move over a helper: the new app in place, the old one in the Trash")
        check(helper.isRunning, "move over a helper: the helper keeps running from the Trash")

        let blocked = try MoveScene(root, name: "probe-app")
        let blockedOriginal = try Fixture.app(in: blocked.source, marker: "new")
        let open = try Fixture.app(in: blocked.applications, marker: "old")
        let openPath = open.appendingPathComponent("Contents/MacOS/sleeper")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: openPath.path)
        var blockedMover = blocked.mover()
        blockedMover.isRunning = RunningBundleProbe.isRunning
        let running = try start(openPath)
        defer { running.terminate() }
        check(waitUntil { RunningBundleProbe.isRunning(open) }, "move over the open app: it is seen open")
        let refused = blockedMover.move(blockedOriginal)
        check(MoverChecks.plain(refused) == MoverChecks.plain(.runningAtDestination(open)), "move over the open app: refused (got \(refused))")
        check(Fixture.marker(of: open) == "old" && Fixture.contents(of: blocked.trash).isEmpty, "move over the open app: untouched")
    }

    private static func start(_ executable: URL) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        return process
    }

    /// Polls for up to 3 s: true as soon as the condition holds.
    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }
}
