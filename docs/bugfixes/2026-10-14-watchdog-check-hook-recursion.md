# 2026-10-14 看门狗自检在 CI 上偶发 Bus error：malloc 钩子的回调自己递归爆栈

## 症状

`scripts/check-main-thread-watchdog.sh`（CI 第 3 组）偶尔红一次：`Bus error: 10`，进程在第 6 组打出结果之前就死了，什么输出都没有；
重跑就绿。2026-10-14 一天撞上两次（#165 合进 main 之后的那次 main 上的 CI、#173 第一次跑），本机连跑 20 遍一次都不崩。
看门狗是正式版默认开着的，所以先要弄清楚：崩的是 App 也会跑的抓栈代码，还是自检自己。

## 根因

崩在自检第 6 组自己装的 `malloc_logger` 钩子里，**和 App 的抓栈代码无关**（App 不装这个钩子）。

在不合并的草稿 PR（#175）上让 CI 把自检连跑最多 120 遍、崩了就打出系统的崩溃报告：第 3 遍就崩了，崩溃报告里有一条线程
递归了 670 层：

```
swift_beginAccess
closure #1 in … SuspendedAllocationProbe.logger        ← NoAllocationWhileSuspended.swift:38
_malloc_zone_malloc_instrumented_or_legacy
swift_slowAlloc
swift::runtime::SwiftTLSContext::get()
swift_beginAccess
closure #1 in … SuspendedAllocationProbe.logger
… （同样的五层重复 670 次）
find_zone_and_free
_pthread_tsd_cleanup ← _pthread_exit ← +[NSThread exit]
```

钩子装着的时候，进程里**任何线程**分配 / 释放都会进回调。回调第一行就读 `SuspendedAllocationProbe.watchedThread`（`static var`）：
读写 Swift 的全局变量要做动态独占检查（`swift_beginAccess`，自检是没优化的构建，优化构建里一样有），它要用这条线程的 Swift TLS。
一条还没有 TLS 的线程 —— 这次是正在退出、TSD 刚被拆掉的线程（`_pthread_tsd_cleanup` 里 free 进了回调），GCD 刚起的线程也一样 ——
在回调里去建它：建 TLS 要分配 → 又进回调 → 又要建 TLS → 无限递归，把这条线程 512 KB 的栈撑爆，写到守护页上（Data Abort）→ Bus error。

撞不撞得上要看钩子装着的那几毫秒里有没有这种线程在分配：抓栈线程 `done.signal()` 之后马上退出、和主线程摘钩子赛跑；
CI 的虚拟机上线程调度慢，赛输的时候多。

2026-10-06 写这一组时已经知道「回调里不许分配、不许碰导入的 C 结构类型」（那次是用了 `thread_basic_info` 类型 → 现场取元数据 →
分配又进回调），可读写 Swift 全局变量也会碰 TLS 这一条没想到：回调里的状态都放在 `static var` 里。

## 修复

只改自检（`checks/MainThreadWatchdog/NoAllocationWhileSuspended.swift`），App 的代码不动：

- 回调的全部状态放进一块裸内存的槽位（`static let slots: UnsafeMutablePointer<Int>`）：`let` 的全局只读不改、不做独占检查，
  槽位按下标裸读写。线程号改用 `pthread_mach_thread_np`（C 函数，不经过泛型的 `UInt(bitPattern:)`）。
- 抓栈线程抓完先等主线程把钩子摘掉再退出（让这一组只数抓栈本身；防递归靠上一条，不靠它）。
- 新加一条**确定性**的回归：钩子装着时起一条裸线程（`pthread_create`，没有 Swift 的 TLS）分配、退出。

约束写进 [挂起主线程抓栈](../architecture/main-thread-stack-capture.md) 第三节。

## 验证

- 本机：旧的回调加上「裸线程在钩子装着时分配」这一条，连跑 3 遍 3 遍都 Bus error（status 138）；新的回调连跑 5 遍全绿（26 项），
  第 6 组照样数得出抓栈线程的分配（2416 次）。
- 第 6 组没被改瞎：在 `walkWhileSuspended` 挂起期间插一个一个元素的数组，第 6 组照样红（挂起期间 600 次）。
- 反向验证（守卫留着、换回旧的回调）：见 PR 描述（不合并的草稿 PR，CI 上跑）。

## 教训 / 防回归

- **钩子回调里「不分配」的清单要包括 Swift 运行时替你做的事**：读写全局变量的独占检查、泛型的元数据、TLS，都可能在第一次用时分配。
  回调里只碰 `let` 指着的裸内存和 C 函数。
- **只在 CI 上偶发、本机不复现的崩溃，先让 CI 自己把现场打出来**：连跑 + 崩了就打出系统的崩溃报告，第三遍就拿到了递归的栈；
  猜了半天的「抓栈读到坏的帧指针」完全不沾边。
- **诊断工具出事先分清是工具还是被测的东西**：看门狗正式版默认开着，弄清楚崩的不是 App 的抓栈代码之前，不能当偶发放过去。
