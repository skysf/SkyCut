# 2026-11-10 参考录音的有声门限借了配音响度的常量，比服务器宽一点点

## 症状

PR #346 合并后审查：一段贴着门限的录音（审查用的 `borderline.wav`：9.9 秒正常说话，加 5 格均方根 0.0056152 ≈ −45.01 dBFS 的声音），
SkyCut 数出正好 10.0 秒有效人声，收下、上传；正在写的服务器照**精确的** −45 dBFS（0.0056234）数，只有 9.9 秒，会回 `too_little_speech`。
SkyCut 说够了、服务器说不够，用户要到上传之后才被拒。

## 根因

- 门限借的是 `AIVoiceLevel.activeFloor` = 0.0056（配音音量里数「说话部分」用的门限），实际是 −45.04 dBFS。文档和 PR 正文都写成「−45 dBFS」，
  服务器照文字实现成精确的 −45 dBFS，比 SkyCut 严约 0.035 dB。两边「同一个口径」只在文字上一致，数没有对过。
- 借别处的常量还有一层风险：以后调配音的响度门限，参考录音这份跨仓库的合同就会悄悄跟着变。数值检查看不出来，因为两个值现在碰巧相等。

## 修复

- 协调者定的合同：SkyCut 的门限是均方根 ≥ **0.0056**（均方 ≥ 3.136e-5，≈ −45.04 dBFS）；服务器故意放宽到 ≥ **0.0055**，
  吃掉两边浮点和取整的差别，保证服务器只会比 SkyCut 宽、不会更严（Sky Studio 那边已通知）。
- `VoiceReferenceWindow.speechRMSFloor = 0.0056` 单独写死，不再借 `AIVoiceLevel.activeFloor`。代码注释、[声音库](../architecture/voice-library.md)
  第二节和 AGENTS.md 都改成写实数。

## 验证

- `scripts/check-mcp.sh` 的 `VoiceReferenceChecks`：门限就是 0.0056；0.0056 和精确的 −45 dBFS 算有声，比 0.0056 小一点的和服务器的 0.0055 不算。
- `VoiceReferenceFileChecks`：照 `borderline.wav` 的形状现写一份（9.9 秒 + 5 格 ±184），走生产的 `prepare`：正好 10.0 秒，收。
- 扫描守卫 `checks/MCP/voice-reference-wiring.sh`（由 `scripts/check-mcp.sh` source，`scripts/check-guards.sh` 也跑）：门限是写死的 0.0056，
  代码里不碰 `AIVoiceLevel`。
- 反向验证：门限改成精确的 −45 dBFS（0.0056234）→ 常量、边界两格、borderline 样本三条红；改回 `= AIVoiceLevel.activeFloor`（数值一样）→
  只有扫描守卫红，这正是要它的原因。恢复后转绿。

## 教训 / 防回归

- 跨仓库的合同写数，不写「约等于」的说法：dBFS 和线性值之间一换算，就差在第三位小数。
- 合同用的常量单独定义，不借一个为别的用途定的常量；值碰巧相等时比数值看不出耦合，要靠扫描守卫。
- 两边各自实现同一个判据时，留一份贴着边界的样本，两边都跑一遍。
