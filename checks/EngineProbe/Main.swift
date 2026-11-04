import Foundation

// 引擎短探测自检入口：只运行合成命令和单次定位检查，不启动 App、不读媒体或访问云端。
func L10n(_ text: String) -> String { text }

@main struct RuntimeProbeCheckMain {
    @MainActor static func main() async {
        guard Bundle.main.bundleURL.pathExtension != "app" else { fatalError("Isolated CLI required; do not inspect or repair an app bundle") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-probe-check-" + UUID().uuidString)
        var failures: [String] = []
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            phase("fixture " + root.path)
            phase("capture, limits and owned cleanup")
            let captures = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try RuntimeProbeChecks.captures(root: root) } }
            failures += try captures.get()
            phase("deferred native child reaping")
            let reaping = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try RuntimeProbeReapChecks.run() } }
            failures += try reaping.get()
            phase("candidate validation and shared deadline")
            let candidates = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try RuntimeProbeChecks.candidates(root: root) } }
            failures += try candidates.get()
            if failures.isEmpty {
                phase("single in-flight resolution")
                failures += try await RuntimeProbeChecks.singleFlight(root: root)
            } else {
                phase("single-flight skipped: broken synthetic prerequisite must not enter locate fallback")
            }
        } catch { failures.append("unexpected fixture error: \(error)") }
        for failure in failures { print("FAIL: \(failure)") }
        print("Engine probe: \(RuntimeProbeChecks.checks) checks, \(failures.count) failures")
        phase("all assertions finished")
        if failures.isEmpty { try? FileManager.default.removeItem(at: root) }
        phase("fixture cleanup finished; exit requested")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static let began = DispatchTime.now().uptimeNanoseconds
    static func phase(_ value: String) {
        let start = began
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        FileHandle.standardError.write(Data((String(format: "PROBE: %.3f s ", elapsed) + value + "\n").utf8))
    }
}
