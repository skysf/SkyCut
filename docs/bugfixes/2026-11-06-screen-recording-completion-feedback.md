# 2026-11-06 录屏已保存，却没有清楚告知用户和 MCP

## 症状

AI 在没有窗口的后台工程中用 `record_screen` 录制，用户在左下角浮窗点 Stop 后，文件已写好并入 V1，
眼前的工程窗口却没有变化或提示。用户以为没录上，连续重录。随后 AI 再 Stop 得到
`Stopped before recording began; nothing was recorded.` / `cancelled`，但点名原 job 的 `get_job`
是 done、42.5 秒且有 clip id。这也是 [账本隔离修复](2026-11-06-screen-recording-manifest-cross-build.md) 中留下的旁查项。

## 根因

1. `importScreenRecording` 正常入轨时清空工程的 `notice`；失败的 `report()` 也只写目标工程。
   目标没有窗口时，用户根本看不到。成功没有交付提示，失败提示也没有跨工程的可见性保证。
2. `AIScreenRecordingTool.current` 同时承担活动尝试和完成历史。后一次重录尚未开录就替换它，
   空闲时 Stop 优先取消这次尝试，立即返回 cancelled；原来的完成 job 仍在，却没被用于回答。
   这不是该把一条 cancelled 文案翻成成功的问题，而是返回了另一个任务。
3. 没有记录停止的发起者和入口，也没有给原 AI 会话留停止通知；用户点了 Stop 后，AI 不主动查 job 就不知道。
4. 旁查还发现设置页关闭回调只查 `.configuring`，AI 也经过这个状态。没有显示的手动 sheet 不能有权取消它。
   对象回归可以直接触发这条错误边界；本次没有操作用户窗口追踪 SwiftUI 何时发该回调。

## 修复

- `ScreenRecordingCompletion` 清理前快照归属，结束后交出一份 `ScreenRecordingReceipt`，UI、AI job、晚到 Stop 和状态查询复用。
  AI 入轨的撤销、计数与自动保存保留；回执的工程名取自动保存后的名字。
- `ScreenRecordingFeedback` 保留全 App notice、原会话的最近录制以及一次性附言，`current` 仅表示最近尝试。
  后续未开录取消不覆盖真正录好的那段；重复回调不覆盖终态。晚到 Stop 保留原 job、路径、clip、轨道、停止来源。
  如果同时取消了另一条尚未开录的尝试，以 `cancelled_before_start_job_id` 单独说明，不能把原视频说成没录到。
- `ScreenRecordingNotice` 挂在主窗口和每个工程窗口的顶部，不随录制工程是否有窗口而隐藏。
  完整路径可选中复制、长内容可滚动；可「在访达中显示 / 打开录制工程」。只有用户点才切窗口，工程代号防止打开被替换的工程。
  手动残缺结果也在 notice 里选择入轨 / 仅保留文件，不再弹模态结果框；等待选择时不能关闭唯一的处置入口。
- 失败不只报一句错：按本次 journal 的提交阶段选择精确路径，真实探测视频 / 音频，分别说可用、不可读、未留下文件或卷不可达。
  `.writing` 的最终路径可能是用户原有文件，绝不拿它冒充本次产物。
- 首次停止锁定 `stopped_by / stop_method`，区分用户浮窗、MCP、自动时长、退出、横幅 / cancel_job、流 / writer / 磁盘错误。
  `get_job` 与 `get_status.screen_recording.last_recording` 都有文件和来源。
- 用户停止后，原会话下一次任意工具调用的结果前加附言，错误也带，原内容 / 图 / `isError` 不变；别的会话不能消费，已在执行的调用不抢走。
  录屏说明前 512 字交代晚到 Stop 和通知，压缩原文以保住整个目录 100,000 字限制，不抬上限。
- 所有新增界面键同时进入英 / 中 / 西表；设置页取消只认 `showsSetupSheet`。

长期合同见 [录屏生命周期](../architecture/screen-recording-lifecycle.md)「收尾回执、界面与 AI」和
[AI 接口](../architecture/ai-control-mcp.md) 第 45 条。

## 界面原文

后台工程成功示例，路径 / 工程名 / id / 轨道运行时替换：

```text
Recording saved
Saved to: <full file path>
Added to “Background” (p2), track V1.
This project is in the background and has no window.
[Show in Finder] [Open recorded project]
```

```text
录屏已保存
已保存到：<完整文件路径>
已放入「Background」（p2）的 V1 轨道。
此工程在后台运行，尚未打开窗口。
[在 Finder 中显示] [打开录制工程]
```

失败标题为 `Recording failed / 录屏失败`，原因前缀 `Reason: %@ / 原因：%@`；无可用文件时写
`No usable recording file was kept. / 未留下可用的录屏文件。`，并说明未加入时间线。
残缺标题为 `Recording saved with issues / 录屏已保存，但有异常`，同时显示原因和实际保留文件。

## 验证

- 新增 `scripts/check-screen-recording-feedback.sh`，链接真实 App 目标文件，在独立 bundle、临时目录和合成视频上测试。
  覆盖后台工程实际 clip / V1、真实 Stop / get_job / get_status、原会话下一次错误工具调用、失败停止收尾、journal 文件回读、残缺处置和三语文案。
  全程不捕获屏幕、不显示窗口、不运行用户 App；不把对象回归报告成真实 SCK / GUI 录制通过。
- **反向验证均确认非零退出，且为行为失败而非编译失败**：
  - 只恢复旧 Stop 函数：4 项失败，原 done 结果被未开录重试的 cancelled 顶替、路径与 clip 丢失、停止来源错误，与 get_job 不一致。
  - 只移除路由附言：3 项失败，原会话下一次调用收不到说明及文件 / 工程 / clip，内容块数量不符。
  - 只恢复旧 `.configuring` 取消条件：9 项失败，未呈现的设置页可以取消 AI 会话，后续完成归属与附言随之出错。
  - 只移除主窗口 notice 接线：`screen-recording-ai-wiring` 第 15 条红，点名主窗口缺提示。
  每次均在 `finally` 中恢复修复。
- `arch -arm64 /bin/bash scripts/check-local.sh screen-recording-feedback localization-coverage mcp`：全部扫描守卫、
  54 项生产对象回归、1079 条三语文案、3227 项 MCP 检查通过，退出码 0。最后补充“仅晚到 Stop 声明全局没有录制”后，
  再顺序运行 `scripts/check-local.sh screen-recording-feedback`：全部扫描守卫和 55 项生产对象回归通过，退出码 0。
- 第一轮 MCP 检查发现目录超过 100,000 字，已压缩本工具说明；同轮一个既有 listen 夹具的 2 秒截止超时，最终顺序检查重新验证，不把那轮报告为通过。
- 真实窗口位置、按钮点击和长路径排版在生命周期文档登记人工矩阵。本任务未动 `/Applications/SkyCut.app` 或 `SkyCut Beta.app`，不打测试版、不安装。

## 教训 / 防回归

1. 入轨成功不等于用户知道成功；后台工程的 notice 不能承担全 App 任务结果提示。
2. 活动尝试与完成历史是两份事实，晚到 Stop 不应从一个会被替换的指针猜历史；回执必须带能核对的原 job id。
3. 人操作后的异步事件要按发起时的会话交付，不能寄望代理下一步恰好调 get_job。
4. 路径只能来自本次提交记录，文件可用性要真实探测；卷不可达不能归为文件不存在。
5. 新反馈需要真实工具入口的对象回归和生产窗口接线守卫；纯文案断言不足以证明用户或 AI 收到了结果。
