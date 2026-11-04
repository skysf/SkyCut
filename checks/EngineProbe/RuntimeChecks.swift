import Darwin
import Foundation

// 只跑临时合成命令，不碰真实 ffmpeg/媒体/云服务；生产 probe 和 toolchain 都直接编入台架。
enum RuntimeProbeChecks {
    static func script(_ body: String, name: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(name + ".sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    static func captures(root: URL) throws -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label) }; checks += 1 }
        let normal = try script("printf 'normal\\n'; printf 'diagnostic\\n' >&2", name: "normal", root: root)
        check(FFmpegRuntimeProbe.output(url: normal, arguments: []) == "normal\ndiagnostic\n", "stdout/stderr drain together before success")
        let nonzero = try script("printf 'ffmpeg version fake\\n'; exit 7", name: "nonzero", root: root)
        check(FFmpegRuntimeProbe.output(url: nonzero, arguments: []) == nil, "valid-looking text from nonzero exit fails")
        let signaled = try script("kill -TERM $$", name: "signaled", root: root)
        let signalResult: String? = {
            var blocked: sigset_t = 0, previous: sigset_t = 0
            sigemptyset(&blocked); sigaddset(&blocked, SIGTERM)
            guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { return "mask fixture failed" }
            defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
            return FFmpegRuntimeProbe.output(url: signaled, arguments: [])
        }()
        check(signalResult == nil, "child resets inherited blocked signals and signal termination is not normal zero exit")
        let noInput = try script("if IFS= read -r item; then exit 7; fi\nprintf 'input-eof'", name: "no-input", root: root)
        check(FFmpegRuntimeProbe.output(url: noInput, arguments: []) == "input-eof", "probe stdin is /dev/null")
        let privateFD = open(root.appendingPathComponent("unrelated-open-file").path, O_CREAT | O_RDWR, 0o600)
        guard privateFD >= 0, fcntl(privateFD, F_SETFD, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(privateFD) }
        let descriptors = try script("if [ -e /dev/fd/\(privateFD) ]; then printf 'inherited'; else printf 'closed'; fi", name: "descriptors", root: root)
        check(FFmpegRuntimeProbe.output(url: descriptors, arguments: []) == "closed", "unrelated parent descriptors do not leak into the probe")
        check(FFmpegRuntimeProbe.output(url: root.appendingPathComponent("missing"), arguments: []) == nil, "launch failure returns without leaked pipe wait")
        let descriptorsBefore = (3..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        for _ in 0..<24 { _ = FFmpegRuntimeProbe.output(url: root.appendingPathComponent("missing"), arguments: []) }
        let descriptorsAfter = (3..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        check(descriptorsAfter == descriptorsBefore, "failed launches close every parent pipe descriptor")
        let oversized = try script("printf '%s' " + quote(String(repeating: "x", count: 8192)), name: "oversized", root: root)
        check(FFmpegRuntimeProbe.output(url: oversized, arguments: [], maximumBytes: 1024) == nil, "stdout cap rejects excessive finite output")
        let combined = try script("printf '%s' " + quote(String(repeating: "o", count: 700)) + "; printf '%s' " + quote(String(repeating: "e", count: 700)) + " >&2", name: "combined", root: root)
        check(FFmpegRuntimeProbe.output(url: combined, arguments: [], maximumBytes: 1024) == nil, "stderr counts toward the same output cap")
        let quick = try script("printf 'ok'", name: "quick", root: root)
        RuntimeProbeCheckMain.phase("24 immediate exits")
        for _ in 0..<24 { check(FFmpegRuntimeProbe.output(url: quick, arguments: []) == "ok", "immediate process exit completes") }

        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["5"]
        sentinel.standardOutput = FileHandle.nullDevice
        sentinel.standardError = FileHandle.nullDevice
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() } }
        for (name, trap) in [("hung", ""), ("ignore-term", "trap '' TERM\n")] {
            RuntimeProbeCheckMain.phase(name + " timeout and cleanup")
            let pidFile = root.appendingPathComponent(name + ".pid")
            let command = try script(trap + "printf '%s' $$ > " + quote(pidFile.path) + "\nexec /bin/sleep 60", name: name, root: root)
            let began = DispatchTime.now().uptimeNanoseconds
            check(FFmpegRuntimeProbe.output(url: URL(fileURLWithPath: "/bin/sh"), arguments: [command.path], timeout: 0.5) == nil, "\(name) times out")
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            check(elapsed < 1.5, "\(name) respects deadline plus bounded cleanup")
            let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            check(pid.map { Darwin.kill($0, 0) == -1 && errno == ESRCH } ?? false, "\(name) owned child is gone after cleanup")
            check(sentinel.isRunning, "cleanup leaves unrelated owned sentinel running")
        }
        let inherited = try script("(/bin/sleep 0.5) &\nprintf 'parent-exited'\nexit 0", name: "inherited", root: root)
        RuntimeProbeCheckMain.phase("inherited stdout after parent exit")
        let began = DispatchTime.now().uptimeNanoseconds
        check(FFmpegRuntimeProbe.output(url: URL(fileURLWithPath: "/bin/sh"), arguments: [inherited.path], timeout: 0.1) == nil, "inherited stdout cannot keep drain alive past deadline")
        check(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000 < 0.8, "inherited stdout returns without waiting for descendant EOF")
        return failures
    }

    static func candidates(root: URL) throws -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label) }; checks += 1 }
        let originalOverride = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        setenv("SRTFLOW_FFMPEG", bundled.deletingLastPathComponent().appendingPathComponent("../Helpers/ffmpeg").path, 1)
        let candidates = FFmpegRuntime.candidates()
        if let originalOverride { setenv("SRTFLOW_FFMPEG", originalOverride, 1) } else { unsetenv("SRTFLOW_FFMPEG") }
        check(Set(candidates.map { $0.0.standardizedFileURL.path }).count == candidates.count, "same standardized path is probed at most once")
        check(candidates.first?.1 == .environmentOverride && candidates.first?.0.standardizedFileURL.path == bundled.standardizedFileURL.path,
              "deduplication preserves the first explicit override priority")
        let good = try script("if [ \"$2\" = -version ]; then printf 'ffmpeg version synthetic\\n'; else printf ' T.. subtitles V->V Synthetic\\n'; fi", name: "candidate-good", root: root)
        let result = FFmpegRuntime.probe(url: good, source: .environmentOverride)
        check(result?.url == good && result?.canBurnInSubtitles == true, "both successful native probes produce usable runtime")
        let noLibass = try script("if [ \"$2\" = -version ]; then printf 'ffmpeg version synthetic\\n'; else printf ' T.. scale V->V Synthetic\\n'; fi", name: "candidate-no-libass", root: root)
        check(FFmpegRuntime.probe(url: noLibass, source: .environmentOverride)?.canBurnInSubtitles == false, "successful filter listing may truthfully lack libass")
        let badFilters = try script("if [ \"$2\" = -version ]; then printf 'ffmpeg version synthetic\\n'; else printf ' subtitles '; exit 8; fi", name: "candidate-bad-filters", root: root)
        check(FFmpegRuntime.probe(url: badFilters, source: .environmentOverride) == nil, "failed filter probe cannot masquerade as usable engine")
        let shared = try script("/bin/sleep 0.3\nif [ \"$2\" = -version ]; then printf 'ffmpeg version synthetic\\n'; else printf ' subtitles '; fi", name: "candidate-shared-deadline", root: root)
        check(FFmpegRuntime.probe(url: shared, source: .environmentOverride, timeout: 2) != nil, "both delayed synthetic commands succeed with a sufficient shared budget")
        check(FFmpegRuntime.probe(url: shared, source: .environmentOverride, timeout: 0.5) == nil, "version and filters share one candidate deadline")
        return failures
    }

    @MainActor static func singleFlight(root: URL) async throws -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label) }; checks += 1 }
        let calls = root.appendingPathComponent("resolve-calls.txt"), release = root.appendingPathComponent("resolve-release")
        let command = try script("printf 'probe\\n' >> " + quote(calls.path) + "\nwhile [ ! -f " + quote(release.path) + " ]; do /bin/sleep 0.02; done\nif [ \"$2\" = -version ]; then printf 'ffmpeg version synthetic\\n'; else printf ' subtitles '; fi", name: "resolve-once", root: root)
        let previous = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
        setenv("SRTFLOW_FFMPEG", command.path, 1)
        defer { if let previous { setenv("SRTFLOW_FFMPEG", previous, 1) } else { unsetenv("SRTFLOW_FFMPEG") } }
        let toolchain = MediaToolchain.shared
        for _ in 0..<24 { toolchain.resolveIfNeeded() }
        var count = 0
        for _ in 0..<100 where count == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            count = await MediaReadQueue.run(on: MediaReadQueue.detail) { callCount(calls) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        count = await MediaReadQueue.run(on: MediaReadQueue.detail) { callCount(calls) }
        check(count == 1 && toolchain.isResolving, "24 callers start exactly one in-flight version probe")
        let released = await MediaReadQueue.run(on: MediaReadQueue.detail) { (try? Data().write(to: release)) != nil }
        check(released, "synthetic probe release barrier is written")
        // 即使反向撤掉单飞、24份 locate 都已排上，也先等它们离开再恢复环境变量，绝不滑到真实引擎兜底。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            MediaReadQueue.analysis.addBarrierBlock { continuation.resume() }
        }
        for _ in 0..<200 where toolchain.isResolving { try await Task.sleep(nanoseconds: 10_000_000) }
        check(!toolchain.isResolving && toolchain.runtime?.url == command, "single lookup publishes its successful runtime")
        for _ in 0..<24 { toolchain.resolveIfNeeded() }
        count = await MediaReadQueue.run(on: MediaReadQueue.detail) { callCount(calls) }
        check(count == 2, "resolved toolchain does not start more version/filter probes")
        return failures
    }

    static func callCount(_ file: URL) -> Int {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    nonisolated(unsafe) static var checks = 0 // 台架三段严格串行；不与被测异步任务共享计数器。
}
