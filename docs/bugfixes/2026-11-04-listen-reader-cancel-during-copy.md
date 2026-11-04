# 2026-11-04 取消 listen 时跨线程拆掉正在读的 reader

## 症状

MCP 全量检查在真实活动音频读取的取消用例中发生 `SIGSEGV`，没有普通断言失败。
单独再跑同一个二进制可以通过，不能因此当作性能偶发或已验证无问题。
实际用户在取消文件区间 `listen`，或读取达到截止时间时，也会经过这一条生产路径。

## 根因

`AIListenReadControl.stop` 在任务取消线程或 timer 线程直接调用 `reader.cancelReading()`，
并接着对同一个 asset 调 `cancelLoading()`；同时 `MediaReadQueue.analysis` 上的同步读取体
正在 `copyNextSampleBuffer()`。读取体的 defer 和调用方的 `finish` 还会再次取消 reader。

本机崩溃报告 `mcpcheck-2026-11-04-133023.ips`（PID 67757）给出了两侧栈：

- thread 0：`checkActiveListenReadEnds → task.cancel → AIListenReadControl.stop →
  AVAssetReader.cancelReading → _tearDownFigAssetReader → AudioConverterDispose`。
- faulting thread 3，`SrtFlow.MediaRead.analysis`：`AIListenAudioWindow.read →
  copyNextSampleBuffer → FigSemaphoreWaitRelative → FigSimpleMutexUnlock`，`EXC_BAD_ACCESS`。

这违反了 Apple SDK `AVFoundation.framework/Headers/AVAssetReader.h:222` 对
`cancelReading` 的明确限制：不能与输出的 `copyNextSampleBuffer` 并发。
[Apple API 说明](https://developer.apple.com/documentation/avfoundation/avassetreader/cancelreading%28%29)
所说的取消后台预读，不能解释成允许跨线程拆卸正在返回样本的 reader。
崩溃时间是否稳定、日志里是否还有其他系统提示，都不改变这个已经确认的调用违约。

## 修复

`AIListenReadControl` 不再保存 reader。外部取消只保存 failure、取消尚未开始的 operation；
metadata 阶段仍可立即取消属性加载，进入 operation 时在同一把锁内结束该阶段，之后不再
对正在使用的 asset 调 `cancelLoading`。每次异步加载返回后都先核对停止信号。

`AIListenAudioWindow` 的同步读取体独占 reader；每次 copy 前后查停止信号，只在一个 defer
里取消。control 的 analysis operation 在 autorelease pool 内完成读取和原生释放，随后才
恢复 continuation。阻塞读取仍全部位于 `MediaReadQueue.analysis`，没有搬进 Swift 协作池。

活动读取的截止时间是“本次 native copy 返回后停止”，无法承诺硬中断任意不返回的原生调用。
不能用跨线程取消换取表面上准时，也不提前返回成功或半份统计。

## 验证

新增 `ListenReaderLifecycleChecks` 走真实生产读取入口，使用记录生命周期的原生 reader
子类，在 `started` 探针处暂停 analysis，**尚未进入 copy**，再从调用方取消。这样既能
确定地证明旧实现跨线程且多次取消，又不必靠重现系统内存崩溃来判红。
守卫核对外部取消时尚未拆卸、恰好一次取消、取消和释放都在 analysis、收尾后才回结果。
另用 asset 探针检查 metadata 仍立即取消、operation 移交后不再取消其加载。

既有 `ListenRangeChecks` 继续实测正在解码时的取消/截止时间、排队超时、取消后重新读取、
压缩音频与实际采样范围。`listen-wiring.sh` 钉住生产调用、reader 单点所有权和 autorelease
收尾，避免只有探针通过却生产没接上。

已执行的定向证据：

- 独立冷启动的生产 `ListenRangeChecks` **49 项通过、0 失败**，包括新增的 10 条生命周期
  检查与真正活动读取的取消/超时。临时阶段计时显示首个 WAV metadata/入队约 63ms，
  同进程随后读取约 1ms；这些插桩只在临时副本，不进入产品。
- 安全反向仅在 `/private/tmp` 副本恢复旧 control 与 reader attachment，真实编译成功后
  **10 项中 5 项失败**：移交后仍取消 asset、外部线程拆 reader、取消 3 次而非 1 次、
  取消队列错误、释放队列错误。原生 reader 始终暂停在首次 copy 之前，没有故意触发系统崩溃。
- 接线守卫恢复旧 control 副本后明确变红，点名禁止从 control 调 `cancelReading`；
  实际仓库修复来源绿。阻塞读取守卫、文件体积和文档索引守卫也通过。

首次完整 MCP 运行 **1/3170 失败**，是既有成功读取用例的 2 秒 deadline；后续与其他
编译重叠的固定来源运行又触发该 deadline 和 15 秒独立 watchdog。这两次均未计为通过，
也未以“flaky”忽略；metadata 计时不足以解释 native 读取/收尾延迟，因此没有放宽阈值。
全量验收需在不重叠编译的窗口独立完成，结果在提交前补齐。

## 教训 / 防回归

原生对象的取消也是生命周期操作，锁住“取到 reader 指针”不代表锁住了后续 copy 和销毁。
取消处理器应发信号，由同步读取体自己收尾；排队取消、metadata 取消、正在读的取消需要
明确分阶段。不能把一次再跑绿用于掩盖已获得原生栈和 SDK 合同的并发 bug。
长期约束与人工边界见[阻塞的媒体读取](../architecture/blocking-media-reads.md#读取中的取消与释放)。
