# 2026-11-03 文件 listen 的短区间仍读取整条音轨

## 症状

对一个很长的素材调用 `listen(file, source_in, source_out)`，即使只要靠近结尾的几秒，也要从头解码音轨。
等到调用的截止时间，工具可能以「文件只读到某秒」为由拒绝一个实际有效的晚时间点区间。
调用结束后，共享波形任务还可能继续解码；对只需要短窗的请求浪费本机读取与计算。

## 根因

`AIListenTool.listenToFile` 先无条件订阅整文件 `WaveformStore`，随后才按 `source_in/source_out` 切统计范围。
这两个参数限制的是已经读完的波形下标，没有限制 `AVAssetReader` 的读取。

`waveform(of:until:)` 最多等 40 秒；超时后拿到的是部分 `WaveformPeaks`。它的 `duration` 是已读覆盖范围，
旧代码却把它当成源文件总时长做边界校验。取消订阅只移走消费者，不会取消 UI 可能仍需要的共享任务。
只改错误文字或把等待时间加长，均不能减少整文件读取，也不能解决晚时间点范围被误判。

## 修复

- `AIListenTool` 保留路径解析、存在性和读取权限检查，文件统计统一转交 `AIListenFileAudio`。
- 文件显式给了 `source_in/source_out` 中任意一头时，`AIListenAudioWindow` 先加载可靠容器时长校验区间，
  再在现有 `MediaReadQueue.analysis` 上通过原生 `AVAssetReader.timeRange` 读取请求窗；不订阅或启动整文件波形。
- 复用 `ChunkBuilder` 的峰值/均方及 `AIAudioLevels` 的统计；按真实采样 PTS 裁包边界，局部波形加回源时间，
  静音和曲线不会从零秒开始报告。读取错误、取消或截止时间到达均失败，不把半份快照当作完整结果。
- 同时检查首尾实际覆盖与每个缓冲的 PTS 连续性；容器音轨有起始偏移、短于视频，或带空编辑时，不能把读到的中间部分
  冒充整窗、把后半段声音提前。覆盖不足明确拒绝完整报告，不推断缺失部分为静音。
- `AIListenReadControl` 同时管排队与已经启动的原生 reader：待执行 operation 可取消；活跃读取取消后收尾再返回。
  不修改 `WaveformStore`，也不影响时间线和 UI 的共享总览任务；未给区间的整文件读取仍明确允许部分报告。
- `beats=true` 独立沿用短音乐的整首缓存分析，结果说明分析范围；文件总长超过既有 15 分钟音乐限制时明确不给节拍解码，
  电平/静音仍可有界返回。本修复不改变节拍算法、不新增工具参数或试听能力。

## 验证

真实生产路径回归为 `scripts/check-mcp.sh` 中的 `ListenRangeChecks`：原生本机合成一小时的稀疏 PCM WAV，
只实际写入晚时间点的 3.2 秒测试信号；不使用任何用户媒体。

- 暂停测试进程的 `overview` 队列后，直接调用文件 listen 生产服务，3200.125–3203.125 秒仍应完整返回。
  电平、峰值、静音与源秒位置有独立的信号期望，窗外更响的测试信号不能混进统计。
- 核对原生实际读取帧数和首尾 PTS，统计仅包含三秒；容器时长是一小时，而非部分解码的覆盖长度。
- 覆盖只给一头、超出文件范围、排队中及活跃读取的超时/取消、失败后队列恢复、长文件节拍限制和短文件兼容；
  原生 reader 的内部生命周期探针先确定 `startReading` 已成功、再取消并核对收尾事件，不能以固定 sleep 或其他队列任务成功推断。
- 另外用原生生成的短 AAC 验证非采样格整点入出点、包边界裁切和读样帧数；合成 MOV 空编辑，以及长于音轨的视频/起始偏移音轨，
  验证统计覆盖确实完整，或者明确拒绝，绝不折叠源时间。
- 每组真实读取带独立线程看门狗，不能无限挂起或因依赖缺失而假绿。

执行结果：`scripts/check-mcp.sh` **3168 checks passed**。阻塞读取与源文件清单单项守卫通过。

反向验证：临时关闭 `AIListenFileAudio.listen` 中的显式范围分支，让文件请求再次走共享整文件波形。
同一个 `scripts/check-mcp.sh` 编译成功并实际运行，得到 **2 of 3146 checks failed**，明确点名
`bounded file listen must work with overview suspended` 与长文件节拍限制的生产入口；不是因编译/依赖失败变红。
恢复分支后同一检查转绿。再加入 AAC、真实生命周期与空编辑/音轨偏移覆盖后为上述 3168 项。

第二次反向验证：临时去掉 PTS 连续性与首尾覆盖校验，代码仍成功编译并运行，得到
**1 of 3168 checks failed**：`a completed edit-list report covers its full requested range`。
说明只看 reader 的 completed 状态仍会把音轨覆盖不全的区间误报为完整；覆盖校验恢复后重新跑同一检查。

恢复全部修复后，`scripts/check-mcp.sh` 重新通过 3168 项；`scripts/check-guards.sh` 全部扫描守卫通过；
`scripts/check-all.sh` 实际退出 0，**82 项通过、0 项失败**，含完整 App 编译、波形、音频引擎与现有剪辑/导出回归。
App 实机验收另由执行协调进行，本次未安装或重启 App。

## 教训 / 防回归

**请求只分析几秒，解码边界就必须是那几秒；统计层截取不等于读取有界。**
部分缓存的覆盖范围不是素材元数据。共享任务取消与单次读取取消也必须区分，不能为结束一通请求而停掉别的消费者。
长期合同已更新 [AI 接口第 13 条](../architecture/ai-control-mcp.md)、
[波形与深度缩放](../architecture/audio-waveform.md) 和 [阻塞的媒体读取](../architecture/blocking-media-reads.md)。
