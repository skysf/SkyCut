import Foundation

// The web-motion renderer checks (scripts/check-web-motion.sh). This program stands in for SkyCut: it renders through
// the production API and runner with the real helper (`SRTFLOW_WEB_MOTION_HELPER`), and its main-thread heartbeat must
// keep beating through every hostile page. docs/architecture/web-motion-renderer.md.

Task { @MainActor in
    guard !Fixture.helper.isEmpty, FileManager.default.isExecutableFile(atPath: Fixture.helper) else {
        print("✗ SRTFLOW_WEB_MOTION_HELPER does not point at the built skycut-web-motion (scripts/check-web-motion.sh sets it)")
        exit(1)
    }
    let started = ProcessInfo.processInfo.systemUptime
    // `SRTFLOW_WEB_MOTION_CHECKS=reach,clock` runs only those groups (reverse verification); unset runs all of them.
    let only = Set((ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_CHECKS"] ?? "").split(separator: ",").map(String.init))
    func wanted(_ group: String) -> Bool { only.isEmpty || only.contains(group) }
    if wanted("pure") { PureChecks.run() }
    if wanted("clock") { await ClockChecks.run() }
    // From here on everything goes through SkyCut's API: its main thread must keep beating (the clock group above drives
    // its own WKWebView on the main thread, which SkyCut never does).
    let heartbeat = Heartbeat()
    heartbeat.start()
    if wanted("normal") { await NormalChecks.run() }
    if wanted("alpha") { await AlphaChecks.run() }
    if wanted("hostile") { await HostileChecks.run() }
    if wanted("reach") { await ReachChecks.run() }
    if wanted("memory") { await MemoryChecks.run() }
    if wanted("load-memory") { await LoadMemoryChecks.run() }
    heartbeat.stop()
    section("SkyCut stayed responsive")
    check(heartbeat.longestGap < 1, "the main thread never stalled while hostile pages were rendered (longest gap "
        + String(format: "%.3f", heartbeat.longestGap) + " s)")
    try? FileManager.default.removeItem(at: Fixture.folder)
    let tally = Tally.shared
    print("")
    print("web-motion: \(tally.passed) passed, \(tally.failures.count) failed in " + String(format: "%.0f", elapsed(since: started)) + " s")
    if !tally.failures.isEmpty {
        tally.failures.forEach { print("✗ \($0)") }
        exit(1)
    }
    print("All checks passed")
    exit(0)
}
RunLoop.main.run()
