import Foundation
import SrtFlowCore
@testable import SrtFlow

// 真实子进程的退出、双管道排空、失败与取消；不用媒体编码来掩盖进程生命周期的竞速。
// 看门狗独占普通线程，生产代码卡住时也必须非零退出；不改用户文件或启动用户 App。
@MainActor enum FFmpegProcessChecks {
    static func run(root: URL, require: (Bool, String) -> Void) async throws {
        let deadline = ProcessCheckDeadline()
        deadline.start()
        defer { deadline.finish() }
        let quick = URL(fileURLWithPath: "/usr/bin/true")
        print("PROCESS: serial immediate exits"); fflush(stdout)
        for _ in 0..<128 {
            try await FFmpegProcess().run(executable: quick, arguments: [], workingDirectory: nil)
        }
        require(true, "128 immediate child exits complete without a wait RunLoop race")
        print("PROCESS: concurrent immediate exits"); fflush(stdout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await FFmpegProcess().run(executable: quick, arguments: [], workingDirectory: nil)
                }
            }
            try await group.waitForAll()
        }
        require(true, "32 concurrent immediate exits finish")
        print("PROCESS: dual-pipe progress"); fflush(stdout)
        try await pipes(require: require)
        print("PROCESS: failures"); fflush(stdout)
        try await failures(root: root, require: require)
        print("PROCESS: cancellation"); fflush(stdout)
        require(await cancelled(beforeLaunch: true), "cancellation before launch completes as cancelled")
        require(await cancelled(beforeLaunch: false), "cancellation while running completes as cancelled")
    }

    private static func pipes(require: (Bool, String) -> Void) async throws {
        var final: FFmpegProgress?
        let script = """
        BEGIN {
            for (i=0; i<4096; i++) {
                print "stdout payload payload payload payload payload payload payload";
                print "stderr payload payload payload payload payload payload payload" > "/dev/stderr";
            }
            print "frame=7"; print "out_time_us=1000000"; print "progress=end";
        }
        """
        try await FFmpegProcess().run(executable: URL(fileURLWithPath: "/usr/bin/awk"), arguments: [script],
                                      workingDirectory: nil, onProgress: { final = $0 })
        for _ in 0..<100 where final?.finished != true { try await Task.sleep(nanoseconds: 10_000_000) }
        require(final?.finished == true && final?.frame == 7 && final?.outTimeSeconds == 1,
                "both pipes drain beyond capacity and the final progress batch is delivered")
    }

    private static func failures(root: URL, require: (Bool, String) -> Void) async throws {
        do {
            try await FFmpegProcess().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'process-check-tail\\n' >&2; exit 7"], workingDirectory: nil)
            require(false, "nonzero exit must fail")
        } catch FFmpegProcessError.exited(let code, let stderr) {
            require(code == 7 && stderr.contains("process-check-tail"), "nonzero exit retains stderr and status")
        }
        for _ in 0..<8 {
            do {
                try await FFmpegProcess().run(executable: root.appendingPathComponent("missing-executable"),
                                              arguments: [], workingDirectory: nil)
                require(false, "launch failure must throw")
            } catch FFmpegProcessError.launchFailed { require(true, "launch failure reports its distinct error") }
        }
    }

    private static func cancelled(beforeLaunch: Bool) async -> Bool {
        let process = FFmpegProcess()
        if beforeLaunch { process.cancel() }
        let running = Task {
            try await process.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], workingDirectory: nil)
        }
        if !beforeLaunch {
            try? await Task.sleep(nanoseconds: 100_000_000)
            process.cancel()
        }
        do { try await running.value; return false }
        catch FFmpegProcessError.cancelled { return true }
        catch { return false }
    }
}

private final class ProcessCheckDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func finish() { lock.lock(); done = true; lock.unlock() }
    private var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func start() {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 30)
            if !finished {
                FileHandle.standardError.write(Data("FAIL: child-process lifecycle exceeded 30 seconds\n".utf8))
                exit(1)
            }
        }
    }
}
