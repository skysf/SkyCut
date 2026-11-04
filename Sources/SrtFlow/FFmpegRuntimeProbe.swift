import Darwin
import Foundation

// 引擎短探测专用：共享截止时间、合流输出上限，父进程独占 waitpid；不接转码或通用命令。
// 只在 MediaReadQueue 上调用。原生启动若卡在 OS 内无法强制超时；启动返回后的读取/收尾都有界。
enum FFmpegRuntimeProbe {
    static let timeout: TimeInterval = 5
    static let outputLimit = 256 * 1024
    private static let stopGrace: TimeInterval = 0.2

    static func output(url: URL, arguments: [String], timeout: TimeInterval = timeout,
                       maximumBytes: Int = outputLimit) -> String? {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { return nil }
        return output(url: url, arguments: arguments, deadline: .now() + timeout, maximumBytes: maximumBytes)
    }

    static func output(url: URL, arguments: [String], deadline: DispatchTime, maximumBytes: Int = outputLimit) -> String? {
        guard deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds,
              maximumBytes > 0, maximumBytes <= 1024 * 1024, let pipe = openPipe() else { return nil }
        defer { close(pipe.read) }
        guard let pid = launch(url: url, arguments: arguments, pipe: pipe) else { close(pipe.write); return nil }
        // launch 之后没有 Foundation Process 或其它组件回收这个 PID；未 waitpid 就不能被复用。
        var child: pid_t? = pid
        defer { if let child { stop(child) } }
        close(pipe.write)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        var endOfFile = false
        var exitStatus: Int32?
        while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
            if !endOfFile {
                let count = Darwin.read(pipe.read, &buffer, buffer.count)
                if count > 0 {
                    guard count <= maximumBytes - data.count else { return nil }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { endOfFile = true }
                else if errno == EINTR { continue }
                else if errno != EAGAIN && errno != EWOULDBLOCK { return nil }
            }
            if child != nil {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { child = nil; exitStatus = status }
                else if result == -1 && errno != EINTR {
                    if errno == ECHILD { child = nil }
                    return nil
                }
            }
            if let exitStatus, endOfFile {
                // Darwin 正常退出码在高八位，低七位为信号；全零才是正常零退出。
                return exitStatus == 0 ? String(data: data, encoding: .utf8) : nil
            }
            // 子进程已退出但后代仍持写端时，也只等到同一截止时间，不建排空线程。
            usleep(10_000)
        }
        return nil
    }

    private static func openPipe() -> (read: Int32, write: Int32)? {
        var pair: [Int32] = [-1, -1]
        guard Darwin.pipe(&pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        // 即使调用进程关闭过标准流，动作里的 /dev/null 和 dup2 也不能覆盖管道本身。
        let reader = fcntl(pair[0], F_DUPFD_CLOEXEC, 3), writer = fcntl(pair[1], F_DUPFD_CLOEXEC, 3)
        guard reader >= 0, writer >= 0 else {
            if reader >= 0 { close(reader) }; if writer >= 0 { close(writer) }
            return nil
        }
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else { close(reader); close(writer); return nil }
        return (reader, writer)
    }

    private static func launch(url: URL, arguments: [String], pipe: (read: Int32, write: Int32)) -> pid_t? {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask: sigset_t = 0, defaults: sigset_t = 0
        sigemptyset(&mask); sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
        // 不继承调用线程屏蔽/忽略的信号；否则子进程的 TERM 生命周期会取决于启动它的线程。
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, pipe.write, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, pipe.write, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, pipe.read) == 0,
              posix_spawn_file_actions_addclose(&actions, pipe.write) == 0 else { return nil }
        let argumentStrings = [url.path] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map { $0.key + "=" + $0.value }
        var argv = argumentStrings.map { strdup($0) }, envp = environmentStrings.map { strdup($0) }
        defer { for value in argv + envp { free(value) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { return nil }
        argv.append(nil); envp.append(nil)
        var pid: pid_t = 0
        return posix_spawn(&pid, url.path, &actions, &attributes, &argv, &envp) == 0 ? pid : nil
    }

    private static func stop(_ pid: pid_t) {
        // 这里只有一个 waitpid owner；升级信号前未回收 PID，也不查进程名或杀进程组。
        for signal in [SIGTERM, SIGKILL] {
            _ = Darwin.kill(pid, signal)
            let deadline = DispatchTime.now() + stopGrace
            while DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno != EINTR) { return }
                usleep(10_000)
            }
        }
        reapOnExit(pid)
    }

    // OS 尚未交付退出时交出唯一回收权，不延长调用、不占永久 wait 线程，也不再发信号。
    static func reapOnExit(_ pid: pid_t) { ProbeDeferredReap(pid).start() }
}

/// 只处理探测停止宽限期之外的 OS 退出交付；注册和退出回调在同一串行队列上且只回收一次。
private final class ProbeDeferredReap: @unchecked Sendable {
    private let pid: pid_t
    private let queue = DispatchQueue(label: "SrtFlow.EngineProbe.reap", qos: .utility)
    private var source: DispatchSourceProcess?
    init(_ pid: pid_t) { self.pid = pid }
    func start() {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source?.setRegistrationHandler { self.reap() } // 注册前已经退出的 zombie 也当场回收。
        source?.setEventHandler { self.reap() }
        source?.resume()
    }
    private func reap() {
        guard let source else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return } // 注册成功时仍在跑，接下来只等 exit 事件。
        if result == -1 && errno == EINTR {
            queue.async { self.reap() }
            return
        }
        source.cancel()
        source.setRegistrationHandler {}
        source.setEventHandler {}
        self.source = nil
    }
}
