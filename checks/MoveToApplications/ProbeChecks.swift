import Foundation

// RunningBundleProbe on real processes (scripts/check-move-to-applications.sh): a process whose executable lies inside a
// scratch bundle (a helper, as an AI client's skycut-mcp would be) makes the bundle count as running, by any letter case,
// and stops counting once it exits; a process in a sibling folder whose name only starts the same doesn't count. The
// executables are copies of /bin/sleep.

enum ProbeChecks {
    static func run(in root: URL, check: (Bool, String) -> Void) throws {
        check(RunningBundleProbe.isInside("/Applications/SkyCut.app/Contents/MacOS/SkyCut", "/Applications/SkyCut.app"),
              "inside: the app's own executable")
        check(RunningBundleProbe.isInside("/Applications/skycut.app/Contents/Helpers/skycut-mcp", "/Applications/SkyCut.app/"),
              "inside: a helper, another letter case, a trailing slash")
        check(!RunningBundleProbe.isInside("/Applications/SkyCut.app", "/Applications/SkyCut.app"), "inside: not the folder itself")
        check(!RunningBundleProbe.isInside("/Applications/SkyCut.app 2/Contents/MacOS/SkyCut", "/Applications/SkyCut.app"),
              "inside: not a sibling whose name starts the same")

        let folder = root.appendingPathComponent("probe")
        let bundle = folder.appendingPathComponent("SkyCut.app")
        let sibling = folder.appendingPathComponent("SkyCut.app 2")
        for (place, name) in [(bundle.appendingPathComponent("Contents/Helpers"), "skycut-mcp"),
                              (sibling.appendingPathComponent("Contents/MacOS"), "SkyCut")] {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: place.appendingPathComponent(name).path)
        }
        check(!RunningBundleProbe.isRunning(bundle), "live: nothing runs from the bundle yet")

        let outside = try start(sibling.appendingPathComponent("Contents/MacOS/SkyCut"))
        defer { outside.terminate() }
        check(waitUntil { RunningBundleProbe.isRunning(sibling) }, "live: the sibling folder's process is seen")
        check(!RunningBundleProbe.isRunning(bundle), "live: a process in a sibling folder doesn't count")

        let helper = try start(bundle.appendingPathComponent("Contents/Helpers/skycut-mcp"))
        check(waitUntil { RunningBundleProbe.isRunning(bundle) }, "live: a helper running from the bundle counts")
        check(RunningBundleProbe.processes(inside: bundle).contains(helper.processIdentifier), "live: by its process")
        let otherCase = folder.appendingPathComponent("SKYCUT.app")
        check(RunningBundleProbe.isRunning(otherCase), "live: the bundle named in another letter case")
        helper.terminate()
        helper.waitUntilExit()
        check(waitUntil { !RunningBundleProbe.isRunning(bundle) }, "live: it stops counting once the process exits")
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
