# 2026-11-03 短导出已排空输出，后台退出等待仍卡在 RunLoop

## 症状

MCP 说明 PR 的 CI 连续两次在既有矩形取景验收中超时，分别停在不同的导出场景；
本机同一套 223 条像素断言通过，收紧协作线程的复测也通过。不能把这种差异当作像素检查成功或已知偶发直接略过。

独立诊断 PR 增加导出子阶段和超时前的原生线程采样后，第三次 CI 明确停在 `EXPORT: running ffmpeg`。
两条管道读取线程已经离开，只有 `FFmpegProcess.swift` 的 `waitUntilExit()` 仍在后台线程的
`NSConcreteTask → CFRunLoop` 中等待；主线程空闲，没有卡在 AVFoundation 取帧。
日志见 [CI 诊断运行](https://github.com/skysf/SkyCut/actions/runs/41497525974)。

## 根因

`Process.run()` 在异步调用所在的线程启动，旧实现再派另一个 GCD worker 调 `waitUntilExit()`。
这不是单纯的 `waitpid`：Apple 的[说明](https://developer.apple.com/documentation/foundation/process/waituntilexit%28%29)
明确它会轮询调用线程当前的 RunLoop；[退出通知](https://developer.apple.com/documentation/foundation/process/didterminatenotification)
则由启动任务的线程发出。我们把跨线程等待当成了与执行上下文无关的退出屏障。
本次栈和短进程回归证明这条接法会漏掉收尾；没有进一步断言 Foundation 内部哪条事件竞速出了问题。

原来只有真实媒体矩阵的总超时，既没分清规划 / 编码 / 取帧，也没有单独压短进程退出这个窗口。
因此很容易误判为编解码器或 CI 图形会话的问题。

## 修复

- 启动前注册 `terminationHandler` 并先登记退出这一份计数；回调、stdout、stderr 三者都完成后才恢复 continuation。
  两条管道继续并行排空，最后的 stderr 和进度不会因退出回调先到而丢失；不再开第三条线程跑 `waitUntilExit()`。
- 启动抛错时解除回调、归还退出计数并关闭两个写端，让读线程收到 EOF，不留无子进程会关闭的管道。
- `checks/ExportProfile/ProcessChecks.swift` 使用生产 `FFmpegProcess` 跑真实子进程：128 次串行立即退出、
  32 次并发退出、双管道超过缓冲容量、末批进度、非零退出尾日志、启动失败、启动前 / 运行中取消。
  看门狗使用独立普通线程，卡住也以非零退出，不靠同一并发线程池自救。
- 保留取景检查的三个导出子阶段标记和 240 秒超时前采样；不延长截止时间、不跳过像素断言。

长期合同见[阻塞媒体读取中的子进程退出](../architecture/blocking-media-reads.md)。

## 验证

- 新回归加到旧实现上：30 秒后失败；采用回调后 `check-export-profile` **39 条断言通过**。
- 反向验证：临时恢复旧 `FFmpegProcess`，同一新增守卫在 `PROCESS: serial immediate exits` 卡住、30 秒后退出 1；
  已恢复修复代码。不是只凭原来的 CI 超时声称回归有效。
- 超时诊断分支另用一个故意阻塞的独立子进程验证，采样确实写出，包装仍退出 1。
- 修复后的完整本地 `check-all` 为 **82 项通过、0 项失败**；全部 `check-guards` 扫描通过。
  [PR #292 的 CI `check-all`](https://github.com/skysf/SkyCut/actions/runs/41505687423) 全绿后，以 merge commit `ec05128` 合并；没有以本机结果代替 CI。

## 教训 / 防回归

等待方法依赖的执行上下文也属于接口合同。管道结束不等于整个异步调用已经收尾，
媒体矩阵的总超时也不能替代进程生命周期回归。先分清阻塞子阶段、留下原生栈，再改实际被证实有问题的接法。
