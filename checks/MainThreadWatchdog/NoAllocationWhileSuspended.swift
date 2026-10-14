import Darwin
import Foundation

// 第 6 组：挂起主线程期间，抓栈的那条线程一次都不许分配或释放内存（确定性的守卫）。
//
// 由来（docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md）：主线程被挂起的那一刻可能正握着分配器
// 的锁，挂起方这时再分配，就永远等那把锁、主线程永远不会被恢复。原来的写法在挂起期间建 `[UInt]`、`append`
// 扩容，南极工程导出两次卡死。约束本身见 docs/architecture/main-thread-stack-capture.md。
//
// 做法：把 libmalloc 的 `malloc_logger` 钩子（MallocStackLogging / Instruments 记分配用的那个全局函数指针）临时指向
// 这里的回调。抓栈线程每分配 / 释放一次，回调就问内核主线程此刻的挂起计数：挂起着还分配 = 违规。跟分配器的锁、
// 两条线程落在哪组核上都无关，每一次抓栈都查得到（只靠压力去撞，同样的原写法 10 轮里只撞上 5 轮，见第 7 组）。
//
// 回调自己也要守同样的规矩：不分配，也不碰导入的 C 结构类型 —— 没优化的构建里第一次碰它要现场取类型元数据，
// 会分配、会加锁（2026-10-06 探针：回调里用 `thread_basic_info` 类型 → 分配又进回调 → 递归加锁崩掉）。
// **也不碰 Swift 的 `var` 全局**：读写全局变量要做动态独占检查（`swift_beginAccess`），它要用这条线程的 Swift TLS；
// 钩子装着时任何线程分配都会进回调，一条还没有 TLS 的线程（刚起的、正在退出拆 TSD 的）就在回调里去建它 → 分配 →
// 又进回调 → 无限递归、爆栈（2026-10-14：CI 上偶发的 Bus error，崩溃报告里递归了 670 层，
// docs/bugfixes/2026-10-14-watchdog-check-hook-recursion.md）。所以全部状态放在一块裸内存里（`static let` 指着它，
// 只读不改的常量不做独占检查），线程号、缓冲区、偏移都在装钩子之前备好，回调里只做裸读写和系统调用。

/// 钩子回调读写的全部状态：一块裸内存的槽位。装钩子之前在主线程上写好，回调里只做裸读写。
enum SuspendedAllocationProbe {
    /// 槽位：盯着的线程（mach 端口）、主线程、看到几次、其中主线程挂起着几次、thread_info 的字数、suspend_count 的偏移、
    /// thread_info 的缓冲区（地址）。
    enum Slot: Int, CaseIterable {
        case watchedThread, mainThread, seen, whileSuspended, infoWordCount, suspendCountOffset, infoBuffer
    }
    static let slots: UnsafeMutablePointer<Int> = {
        let slots = UnsafeMutablePointer<Int>.allocate(capacity: Slot.allCases.count)
        slots.initialize(repeating: 0, count: Slot.allCases.count)
        return slots
    }()

    /// reverse check: a Swift `var` global the hook reads, as the old hook did.
    nonisolated(unsafe) static var legacyWatched = 0

    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// libmalloc 的 `malloc_logger`（`RTLD_DEFAULT` 里找）。找不到 = 这一组查不了，调用方必须报红，不许当通过。
    static func loggerSlot() -> UnsafeMutablePointer<Logger?>? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)
    }

    /// 每次分配 / 释放都会调到这里（所有线程）。只数被盯着的那条线程；**这里不许分配、不许碰导入的 C 结构类型、
    /// 不许碰 Swift 的 `var` 全局**（槽位按下标裸读写：0 盯着的线程、1 主线程、2 看到几次、3 挂起着几次、4 字数、5 偏移、6 缓冲区）。
    static let logger: Logger = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE = 2、MALLOC_LOG_TYPE_DEALLOCATE = 4：释放也要拿分配器的锁，一样算。
        guard type & 6 != 0, SuspendedAllocationProbe.legacyWatched >= 0 else { return }  // reverse check: reads a Swift var global again
        let slots = SuspendedAllocationProbe.slots
        guard slots[0] != 0, Int(pthread_mach_thread_np(pthread_self())) == slots[0],
              let info = UnsafeMutablePointer<integer_t>(bitPattern: slots[6]) else { return }
        slots[2] += 1
        var words = mach_msg_type_number_t(slots[4])
        guard thread_info(thread_act_t(slots[1]), thread_flavor_t(THREAD_BASIC_INFO), info, &words) == KERN_SUCCESS
        else { return }
        if UnsafeRawPointer(info).load(fromByteOffset: slots[5], as: integer_t.self) > 0 { slots[3] += 1 }
    }
}

/// **在主线程上调**：另一条线程连抓 `captures` 次主线程的栈，钩子数它在主线程被挂起期间分配 / 释放了几次 —— 必须是 0。
/// 钩子装着的时候再起一条裸线程分配、退出：它没有 Swift 的 TLS，回调要是碰了 Swift 的全局变量就递归爆栈（确定性地崩）。
func checkNoAllocationWhileSuspended(captures: Int) {
    guard let slot = SuspendedAllocationProbe.loggerSlot() else {
        check(false, "找不到 libmalloc 的 malloc_logger 钩子：第 6 组查不了，不许当通过 —— 换个办法数挂起期间的分配")
        return
    }
    let capture = MainThreadStackCapture()
    let wordCount = MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size
    let info = UnsafeMutablePointer<integer_t>.allocate(capacity: wordCount)
    defer { info.deallocate() }
    let slots = SuspendedAllocationProbe.slots
    slots[SuspendedAllocationProbe.Slot.mainThread.rawValue] = Int(mach_thread_self())
    slots[SuspendedAllocationProbe.Slot.infoBuffer.rawValue] = Int(bitPattern: info)
    slots[SuspendedAllocationProbe.Slot.infoWordCount.rawValue] = wordCount
    slots[SuspendedAllocationProbe.Slot.suspendCountOffset.rawValue] = MemoryLayout<thread_basic_info>.offset(of: \.suspend_count)!
    slots[SuspendedAllocationProbe.Slot.seen.rawValue] = 0
    slots[SuspendedAllocationProbe.Slot.whileSuspended.rawValue] = 0
    let logger = SuspendedAllocationProbe.logger  // 装钩子之前把它的懒初始化做掉

    let ready = DispatchSemaphore(value: 0)
    let go = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    let capturer = Thread {
        slots[SuspendedAllocationProbe.Slot.watchedThread.rawValue] = Int(pthread_mach_thread_np(pthread_self()))
        ready.signal()
        go.wait()
        for _ in 0..<captures { _ = capture.capture() }
        done.signal()
        // 钩子摘掉之前不退出：线程退出时拆 TSD 也会分配 / 释放（只是让这一组只数抓栈本身，不是靠它防递归）。
        released.wait()
    }
    capturer.start()
    ready.wait()
    let previous = slot.pointee
    slot.pointee = logger
    // 一条没有 Swift TLS 的裸线程在钩子装着时分配、退出（GCD 随时会起这种线程）：回调不许因此递归爆栈。
    var raw: pthread_t?
    pthread_create(&raw, nil, { _ in free(malloc(64)); return nil }, nil)
    if let raw { pthread_join(raw, nil) }
    go.signal()
    done.wait()
    slot.pointee = previous
    slots[SuspendedAllocationProbe.Slot.watchedThread.rawValue] = 0
    released.signal()

    let seen = slots[SuspendedAllocationProbe.Slot.seen.rawValue]
    let whileSuspended = slots[SuspendedAllocationProbe.Slot.whileSuspended.rawValue]
    print("  第 6 组：\(captures) 次抓栈，抓栈线程分配 / 释放 \(seen) 次，其中主线程被挂起期间 \(whileSuspended) 次")
    check(raw != nil, "钩子装着时起一条裸线程分配、退出：该起得来（回调碰 Swift 全局变量时这里递归爆栈）")
    check(seen > 0, "钩子该看到抓栈线程在挂起之外的分配（不然钩子没生效，这一组是空跑）：\(seen) 次")
    check(whileSuspended == 0,
          "主线程被挂起期间，抓栈线程分配 / 释放了 \(whileSuspended) 次内存：碰上主线程握着分配器的锁就永远卡死（docs/architecture/main-thread-stack-capture.md）")
}
