# 2026-11-05 声音主时钟停住导致预览无法播放

## 症状

本机 SkyCut 打开的「留一束光 - 30s-480p-test」工程点击播放后，按钮变成暂停，但指针和视频停在约 3.6 秒。
界面和 AI 状态查询仍能响应；工程已保存，素材缩略图和波形正常。现场版本为
`0.18.56-local.20261104.1834.g1acb20b.officialfilm`，进程已运行约 20 小时。

卡顿日志持续记录「画面 3.700 s、引擎 3.594 s，重新钉到引擎」，每秒一次、位置不变。
这证明停住的是声音主时钟，而非主线程完全卡死。现场历史日志没有留下对应的设备事件，
无法确定最初是哪次插拔 / 设备重配或唤醒触发，不把这一触发源说成已证实。

## 根因

`PlaybackAnchor.playing` 只记录用户是否要播放，不是 `AVAudioEngine.isRunning`。
引擎只在首次建立预览时 `start()`；之后 `PlayerClock.play()` 只发布播放锚点，Timer 只读引擎的播放头。
原生图停止后采样时间不再更新，而锚点仍标着 playing。播放头停住，视频对表逻辑又把画面不断钉回旧位置。

Apple 对 [AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange)
的说明确认：输入 / 输出硬件采样率或声道变化会停止引擎，需要 App 恢复。
已有代码既不检查真实运行状态，也没有恢复路径；这类停止可以在原生图上确定性复现。

同一生命周期边界还有一处缺口：卸片没有摘掉 `PlayerClock.audioSource` 和计时器，
后台预览停止后再建的新引擎又被「已经挂过一个」的条件拒绝，仍可能读到停止的旧时钟。

## 修复

- `TimelineAudioEngine.recoverIfNeeded` 检查原生图；停了才启动，并保留时间线位置与播放 / 暂停状态。
  重启先清旧采样 / host 时间、再重钉锚点，否则新采样从 0 起步时还要等到追上旧值，指针仍会暂时不动。
- `PlayerClock` 开播前和播放中的 Timer 都检查恢复；恢复后视频重新对齐，失败暂停两边并记下错误，用户下次点击可重试。
- 卸片摘掉声音源和 Timer；换源先停旧源。`PreviewAudioEngineHost.apply` 复用引擎时也重新接线。
- 正常图不重复启动，不改变离线混音的段落 / 增益规则。

## 验证

- `scripts/check-player-clock.sh`：63 项，0 失败。新回归走真 AVPlayer / Timer，覆盖开播前与播放中中断恢复、
  恢复失败停播与手动重试、换源、卸片和复用源重新接线。
- `scripts/check-audio-engine.sh`：172 项，0 失败，含原生图停止 / 重启与采样时间域的回归；
  `scripts/check-audio-engine.sh --realtime-recovery`：本机真实输出设备静音运行，4 项，0 失败。
- 反向验证后均恢复生产代码：移除时钟的恢复调用 → 6 项失败；移除卸片摘源 → 2 项失败；
  原生图恢复直接返回 → 3 项失败；不清旧采样 / host 时间 → 时间连续性失败；
  移除宿主复用引擎后的接线 → `open-projects-wiring` 点名变红。
- `/usr/bin/arch -arm64 /bin/bash scripts/check-local.sh player-clock audio-engine`：全部扫描守卫通过，
  播放器 63 项、音频引擎 172 项均为 0 失败。
- `0.18.57-local.20261105.playback` 已按原固定证书打包并安装到本机；arm64、完整签名和产物中的新增恢复逻辑均核对。
  打包与沙箱外的签名校验通过，证书 SHA-1 与原安装包一致；沙箱内信任查询的 `CSSMERR_TP_NOT_TRUSTED` 是环境限制，
  在同一构建权限环境复核后通过，没有更换证书。
- 真窗口重开原工程：播放头从 0 推进到 17.5 秒，截图中画面进入第二镜；再次从头播放，6.1 秒暂停、续播推进到 17.0 秒。
  Return 回到开头、定位到 3.6 秒均正常；验收后暂停并留在 3.6 秒。工程仍为已保存且无未保存改动。
  设备插拔 / 睡眠唤醒的具体系统事件未人为触发，仍列在架构文档人工回归清单里。
- 沙箱内首次检查被 Swift 缓存写权限与架构检测限制阻止，没有执行到自检；换到沙箱外的原生 arm64 后才取得上述结果。

## 教训 / 防回归

逻辑上的「在播放」不能代替硬件渲染图的运行状态；作为全工程主时钟的系统组件必须有停止后的恢复路径。
只验证离线音频正确，覆盖不到长时间运行中的设备变化。长期合同和设备 / 唤醒人工回归清单见
[音频引擎](../architecture/audio-engine.md)第二节第 10 条、第三节与第五节。
