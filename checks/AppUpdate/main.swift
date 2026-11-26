import Foundation

// scripts/check-app-update.sh: SkyCut's updater. The pure rules (versions, the feed, who updates, the state machine, the
// retry record, what a restart waits for), then the real flow against scratch folders: a loopback feed and DMG, real
// images, the pipeline, the install at quit with fixture bundles, a loop of swaps killed at random instants, what a launch
// reads and cleans, and the relaunch shell. Never the network, the real /Applications, the person's Trash or a running
// SkyCut: every destination, Trash, opener and running probe is injected.
// Usage: check-app-update <scratch folder> <loopback base URL> <the server's folder>
//        check-app-update --swap-loop <a> <b> <count>   (the kill test's child)

@main
struct AppUpdateChecks {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 5, arguments[1] == "--swap-loop", let count = Int(arguments[4]) {
            exit(InstallChecks.swapLoop(URL(fileURLWithPath: arguments[2]), URL(fileURLWithPath: arguments[3]), count: count))
        }
        guard arguments.count == 4, let base = URL(string: arguments[2]), base.host == "127.0.0.1" else {
            fatalError("usage: check-app-update <scratch folder> <loopback base URL> <server folder>")
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let server = LoopbackServer(base: base, folder: URL(fileURLWithPath: arguments[3], isDirectory: true))
        let tally = Tally()
        let check: (Bool, String) -> Void = { condition, message in tally.record(condition, message) }
        FeedChecks.run(check: check)
        EligibilityChecks.run(check: check)
        StateChecks.run(check: check)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await FlowChecks.run(server: server, root: root.appendingPathComponent("flow"), check: check)
            try InstallChecks.run(root: root.appendingPathComponent("install"), binary: arguments[0], check: check)
            try LaunchChecks.run(root: root.appendingPathComponent("launch"), check: check)
        } catch {
            check(false, "fixture: \(error)")
        }
        print("app-update: \(tally.checks) checks, \(tally.failures) failed")
        exit(tally.failures == 0 ? 0 : 1)
    }
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var checks = 0
    private(set) var failures = 0

    func record(_ condition: Bool, _ message: String) {
        lock.withLock {
            checks += 1
            if !condition {
                failures += 1
                print("FAIL: \(message)")
            }
        }
    }
}
