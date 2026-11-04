import Darwin
import Foundation

// 明确制造注册前/后退出两个窗口；waitid(WNOWAIT) 只观察 zombie，不抢被测组件的回收权。
enum RuntimeProbeReapChecks {
    static func run() throws -> [String] {
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label) }; RuntimeProbeChecks.checks += 1 }
        for alreadyExited in [false, true] {
            let pid = try spawn(alreadyExited ? "exit 0" : "exec /bin/sleep 0.1")
            var handedOver = false
            defer {
                if !handedOver { _ = Darwin.kill(pid, SIGKILL); FFmpegRuntimeProbe.reapOnExit(pid) }
            }
            if alreadyExited {
                let deadline = DispatchTime.now() + 1
                var observed = false
                while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                    var information = siginfo_t()
                    let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                    if result == 0, information.si_pid == pid { observed = true; break }
                    usleep(10_000)
                }
                check(observed, "deferred reaper fixture is an observed unreaped exited child")
                guard observed else { continue }
            }
            FFmpegRuntimeProbe.reapOnExit(pid)
            handedOver = true
            let deadline = DispatchTime.now() + 1
            var gone = false
            while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                if Darwin.kill(pid, 0) == -1, errno == ESRCH { gone = true; break }
                usleep(10_000)
            }
            check(gone, alreadyExited ? "registering after exit still reaps the child" : "registering before exit reaps the child when it exits")
        }
        return failures
    }

    private static func spawn(_ command: String) throws -> pid_t {
        let arguments = ["/bin/sh", "-c", command]
        var argv = arguments.map { strdup($0) }
        defer { for value in argv { free(value) } }
        argv.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, &argv, &environment)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return pid
    }
}
