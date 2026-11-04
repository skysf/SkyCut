# 2026-11-04 非零时间线起点让原生尾帧请求落到前一个刻度

## 症状

真实后台 MCP 为官方镜头采集 `current.last_used` 时，源窗 `[0, 10)`、工程 24 fps、
镜头放在 10 秒，最后工程帧为 `479/24` 秒。`freeze_frame` 成功写出 PNG，但原生
metadata 的请求为 `5974/600`，实际返回 `238000/24000`，漂移 `-0.04` 秒，
超过半工程帧 `1/48` 秒；严格锚点审查正确拒绝。

同轮另一段放在 0 秒，相同源窗的最后请求为 `5975/600`，实际 `239000/24000`，
漂移为零。MCP 素材信息报告两者源帧率均为 24；不能仅凭 actualTime 的 24000 标度推断帧率。

## 根因

全局工程帧 `479/24` 的 Double 是 `19.958333333333332`，减去段首 10 后得到
`9.958333333333332`，乘 600 为 `5974.999999999999`。旧生产入口直接使用
`CMTime(seconds:preferredTimescale:600)`，本次原生请求截成了 5974，少一个刻度。
放在 0 秒时 `239/24` 的 Double 为 `9.958333333333334`，换算为 5975，因此没有暴露问题。

这是请求算术的量化差异。原始记录同时证明 AVFoundation 在该请求下实际返回了前一帧，
没有使用容差回退；不能把零容差成功等同于 actualTime 与请求严格相同，也不能把实际帧改写为预期帧。

## 修复

只修改 `NativeSourceFrameSampler.requestedTime`：先拒绝非有限值，保留有限负值归零，
再显式取最近的 1/600 秒刻度，半刻度向远离零方向取整。用 `Int64(exactly:)` 拦住
不可表示的刻度，避免整数转换崩溃；实际请求保留 valid / hasBeenRounded 标志。

原生取样、旁白尾帧和锚点期望请求继续共用该入口。全局 `EditClip` 时间映射、
fallback tolerance、解码器、actualTime、漂移上限与精确半开窗口均不改。
旧截断请求与当前边缘不再匹配时需重新抽帧，历史 metadata 不自动升级。

原有“量化到用窗之前”的合成负例由 `source_in=1.0009` 改为 `1.0001`：
前者按新政策应取 601/600 并进入窗口，后者仍取 600/600、落在窗口外。
纯值守卫和六例 MCP 夹具同步更换数值，保持原来的拒绝目的；真实失败记录没有修改。

## 验证

直接检查 `scripts/check-film-production.sh` 调用生产量化入口，覆盖非零段首、刻度两侧、
半刻度、零 / 负值、非有限 / Int64 边界；严格 reader 另验证同一边缘的预期请求、
独立原生 actualTime、旧截断证据过期以及前一帧仍被半帧漂移守卫拒绝。
合成 CGImage / CMTime 不代表真实素材已重抽；本刀不通过 CLI 解码真实媒体。

- 正向：`/bin/bash scripts/check-film-production.sh`，304 项、0 失败。
- 反向：只在 `/private/tmp/skycut-native-request-rounding-reverse-20261104/` 用 HEAD 的旧
  sampler 替换编译输入，其余源与脚本一致；304 项、10 失败、退出 1，分别命中非零段首、
  tick 下侧、上半刻度、半刻度、五种非法 / 溢出值及严格 reader 的非零段首预期请求。
- 恢复正向：同一仓库脚本 304 项、0 失败、退出 0；隔离反向前后生产 sampler 的 SHA-256 相同。
- 日志分别为 `/private/tmp/skycut-native-request-rounding-positive-20261104.log`、
  上述隔离目录的 `legacy.log`，恢复正向记录在
  `/private/tmp/skycut-native-request-rounding-restored-20261104.log`。
  首次受限沙箱的 Clang 缓存写入失败另存 `skycut-native-request-rounding-sandbox-denied-20261104.log`，
  该次未执行检查，不算代码失败或通过。
- 本刀本地统一入口五组为 53 / 11 / 7 / 6 / 8，共 85 项全部通过；第 3 组计时守卫通过后，
  只让独立媒体组与静态扫描重叠，未放宽时限或数值阈值。完整日志在本机
  `/private/tmp/skycut-native-request-rounding-20261104/full/`。

真实尾帧及免费报价由后台 MCP 另行验收，不把本机纯值通过当作服务端生产启用或付费输出验收。

## 教训 / 防回归

整数格点经全局 Double 减法可能落在格点的任意一侧。请求量化政策应在唯一原生入口显式定义，
不能靠放宽输出证据守卫隐藏请求错误，也不能把这项修复推广为全局合成时间换算修改。
长期合同见[定格](../architecture/freeze-frame.md#5-抽帧的两条纪律)和
[官方帧锚点](../architecture/official-film.md#原生帧锚点与历史输入)。
