# 2026-11-10 浮点素材里有坏采样，做克隆参考录音时整个 App 崩掉

## 症状

PR #346 合并后审查时复现：15 秒、44.1 kHz 的 32 位浮点 WAV，中间放一个 NaN（换成 +Inf、−Inf 或 1e20 也一样），交给
`VoiceReferenceSample.prepare`（AI 那一路就是 `add_voiceover clone_from`），进程 SIGTRAP、整个 SkyCut 退出。
16-bit 的素材、正常的浮点素材都不会；#346 之前参考段由 AVFoundation 直接转成 Int16，也不会 —— 这是 #346 带进来的回归。

## 根因

`quantize` 写成 `Int16(clamping: Int((Double(value) * 32_768).rounded()))`。`Int16(clamping:)` 只夹得住**整数**，可它之前
`Int(_:)` 先把 Double 转成整数：NaN、无穷、超出 `Int` 范围的数在这一步就 trap（Swift 的浮点转整数不夹、不报错，是运行时错误）。
`clamping` 让人以为「夹住了」，实际夹的位置在崩溃之后。自检的素材全是正常的 16-bit / 浮点信号，没有一个坏采样。

## 修复

- `VoiceReferenceSample.quantize`：不是有限数（NaN、±Inf）就记成 0，当静音；有限的先在 Double 上夹到 −32768…32767，再转 Int16。
  只改这一处：量化是参考录音里唯一一次浮点转整数。
- 量响度那一边不用改：均方按 Double 累加，NaN 让那一格的均方根成了 NaN、比较时算停顿；无穷算有声。两种都不崩，
  最后以写出去的 16-bit 采样再数一遍为准。

## 验证

- `scripts/check-mcp.sh` 的 `VoiceReferenceChecks`：`quantize` 对 NaN、±Inf、±1e20、最大有限数分别给 0、0、0、±满幅、满幅。
- `VoiceReferenceFileChecks` 现写 15 秒的 32 位浮点 WAV（5 秒处 NaN、6 秒 +Inf、7 秒 −Inf、8 秒 1e20、9 秒 −1e20），走生产的 `prepare`：
  不崩，那几处写成 0 / 0 / 0 / 32767 / −32768，其余照常，有效人声 15 秒。
- 反向验证：把 `quantize` 换回原来的写法，`check-mcp` 跑到这一组当场崩（SIGTRAP），脚本退出码非 0；恢复后转绿。

## 教训 / 防回归

- 浮点转整数之前先排除非有限数、先在浮点上夹范围；`Int16(clamping:)` 这类「夹住」只管整数之间的转换。
- 读用户文件的代码，测试素材要带坏数据（NaN、无穷、特别大的数），不能只有正常信号。
- 长期约束写在 [声音库](../architecture/voice-library.md) 第四节。
