# 2026-11-06 另一个构建启动，把正在录的账本当崩溃残留接管

## 症状

用户实测：SkyCut Beta 0.18.60（`com.srtflow.SrtFlow.beta`）通过 MCP `record_screen`
录内建屏时，第一次打开刚装好的正式版 0.18.60（`com.srtflow.SrtFlow`）。约 30 秒后
Beta 的任务失败，`get_job` 报 `The screen recording failed: The recording has no usable video.`。
把账本文件挪开后，同一流程录制正常。

## 根因

`ScreenRecordingCoordinator` 无论自己的 bundle id 是什么，都把 `ScreenRecordingManifestStore`
放在 `Application Support/SrtFlow/active-recording-manifest.json`。正式版、Beta、Dev、冒烟构建
设置和 MCP socket 已经分开，录屏账本却仍是同一份。

`recoverIfNeeded()` 只验证本进程 `.idle`、没有内存里的 manifest，再从 store 读取。
这个条件只能保护本进程的活动录制，不能排除别的 App 正在写盘。新 App 读到另一个构建的
`.writing` 账本后，按崩溃残留探测媒体、提示恢复、清账，甚至删除对方还在写的临时文件。
同样，共用路径上的开录持久化也可能覆盖对方的账。

## 修复

- 账本改为 `Application Support/<完整 bundle id>/active-recording-manifest.json`，与 MCP socket
  的正常位置同目录。正式版和 Beta 仍用原身份，不引入 SkyCut 前缀、不更改 bundle id。
- `ScreenRecordingManifestStore` 独立成文件，增加显式的 `applicationSupport:bundleIdentifier:`
  入口，协调者用自己的 `Bundle.main.bundleIdentifier` 构造唯一 store。恢复、未结账检查、
  写入、清账继续复用这一份。既有原子写与清账裁决不变。
- **旧共用账本保留原样，彻底不读**：不回退、不迁移、不删除、不探它点名的媒体。
  旧格式没有构建归属，不能证明那是崩溃残留；本机没有外部用户，不为这份历史文件加迁移机制。
  代价是旧共用账本不自动恢复，确有需要时等录制全部停止后人工处理。
- 持久化自检从超长的 `ScreenRecordingChecks.swift` 拆出，新增四种身份的真实磁盘回归；
  更新文件体积基线。`product-name` 守卫改为钉原 bundle id，AI 录屏接线守卫钉生产入口。

长期约束见 [录屏生命周期](../architecture/screen-recording-lifecycle.md)「构建身份与旧账本」，
身份规则同步在 [产品名与代码名](../architecture/product-name.md)。

## 验证

- `arch -arm64 swift run --arch arm64 SrtFlowCoreChecks`：1109 项通过。
  新增回归实写正式版 / Beta / Dev / 冒烟四份不同会话，核对路径和磁盘解码值；每种身份重建
  store 仍读到自己，清账不动其余身份；旧账本及所有临时媒体逐字节保持不变。
- 反向验证：把 store 的身份目录临时改回共用 `SrtFlow`，核心检查退出码 1，4 项失败，
  抓住误读旧账本、阻塞新录制与错误磁盘路径；再单独恢复旧协调者初始化，接线守卫退出码 1，
  报“录屏账本必须使用本构建 bundle id 的入口”和禁止共用位置两条错误。
  两处均在 `finally` 中恢复，再跑本地检查。
- 推送前运行 `arch -arm64 /bin/bash scripts/check-local.sh core`：全部扫描守卫通过，
  核心 1109 项通过（修复已恢复），退出码 0。
- **未执行多 App 真录与 GUI 冒烟**：用户要求不碰窗口，且 Beta 正被另一个任务使用。
  这次验证覆盖路径、持久化隔离及生产接线，不把它报告成真机捕获通过。发版前人工矩阵已写入生命周期文档。

### 旁查：用户已停止并入轨，AI 再 Stop 却报 cancelled（未修）

用户另报：浮窗 Stop 已完成入轨，再调 `record_screen action=stop`，却回
`Stopped before recording began; nothing was recorded.` / `status: cancelled`。

当前代码的 `AIScreenRecordingTool.stop` 在空闲时已有“返回最近已结束 job”的分支；
这句取消文案来自 `AIScreenRecordingJob.cancelBeforeStart()` 或 `.nothingRecorded`。
仅凭静态代码无法确认用户那次返回的是哪个 job、它为什么进入未开录取消路径；
不能只把 cancelled 文案改成成功就声称入轨已被验证。

本 PR 不扩展 AI 任务历史或录屏状态机，也不操作使用中的 Beta 追踪。后续需在获准操作时记录
start / 用户 Stop / 再 Stop 的 job id、状态和入轨结果，明确区分未开录取消、正在收尾和已入轨；
已完成时应说没有正在录制的会话、最近一次已停止并入轨，带原 job id。人工回归已登记。

## 教训 / 防回归

1. 运行期账本的身份边界必须与执行它的 App 一致；单例、`.idle` 和一次性恢复闸都是进程内约束。
2. 无归属的旧账本不能自动认领，更不能为了“迁移干净”去碰其中点名的媒体。
3. 路径隔离既要实写实读，也要守住生产调用入口；只测 store、协调者仍传旧目录会是假绿。
4. 不可复现的任务结果不能靠换一句文案掩盖；保留已知症状与待查边界。
