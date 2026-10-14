import Darwin
import Foundation

// 排查用（不合并）：SIGBUS / SIGSEGV 时打出出错地址、寄存器、是哪条线程、调用栈。

nonisolated(unsafe) var crashProbeFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

func installCrashProbe() {
    let altSize = 1 << 17
    var alt = stack_t()
    alt.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: altSize, alignment: 16)
    alt.ss_size = altSize
    alt.ss_flags = 0
    sigaltstack(&alt, nil)
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = { signal, info, context in
        func say(_ text: String) { text.withCString { _ = write(2, $0, strlen($0)) } }
        let address = info.map { UInt(bitPattern: $0.pointee.si_addr) } ?? 0
        say("\n### crash probe: signal \(signal) at address 0x\(String(address, radix: 16)) code \(info?.pointee.si_code ?? -1) main=\(pthread_main_np()) thread=\(pthread_mach_thread_np(pthread_self()))\n")
        if let context = context?.assumingMemoryBound(to: ucontext_t.self), let machine = context.pointee.uc_mcontext {
            let ss = machine.pointee.__ss
            say("### pc 0x\(String(ss.__pc, radix: 16)) lr 0x\(String(ss.__lr, radix: 16)) fp 0x\(String(ss.__fp, radix: 16)) sp 0x\(String(ss.__sp, radix: 16))\n")
            let symbols = MainThreadStackCapture.symbolicate([UInt(ss.__pc), UInt(ss.__lr)])
            say("### pc = \(symbols[0])\n### lr = \(symbols[1])\n")
        }
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let size = UInt(pthread_get_stacksize_np(pthread_self()))
        say("### this thread's stack 0x\(String(top - size, radix: 16))..0x\(String(top, radix: 16))\n")
        let count = backtrace(crashProbeFrames, 128)
        backtrace_symbols_fd(crashProbeFrames, count, 2)
        _exit(97)
    }
    action.sa_flags = SA_SIGINFO | SA_ONSTACK
    sigaction(SIGBUS, &action, nil)
    sigaction(SIGSEGV, &action, nil)
}

func stage(_ text: String) {
    let line = "== \(text)\n"
    line.withCString { _ = write(2, $0, strlen($0)) }
}
