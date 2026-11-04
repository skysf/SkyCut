# 2026-11-04 定格把首个使用帧误当成不可分割的边缘

## 症状

后台 MCP 制作状态验收中，已知 24 fps 原片裁到源区间 `[0.5, 1.7)`，放在自有 V2 的 0 秒。
`freeze_frame(clip_id:…, time:0)` 显式返回不能定格，未产生 `source_frame`。
前面的两个 last_used 锚点已成功，问题出现在 six-case 原生边界验收的首个 trim-first 场景。

失败原始回包保留在本机
`/private/tmp/srtflow-film-production-mcp-20261104/official-evidence-1793781791051222000/native-trim-first-62d96c00-raw.json`。
这不是实际取帧时间被舍入后的失败：请求在进入原生取样之前就被准入挡住。

## 根因

`isFreezeEligible`、手动/MCP 默认目标选择、`insertFreeze` 复用了 `EditClip.contains(time:)`。
该函数服务普通分割，要求离两端都超过 1 毫秒；定格却应能取源窗第一帧。
因此精确片段起点和距起点不足 1 毫秒的第一个工程格点都被错误拒绝。

只放宽第一层准入也不正确：原 `insertFreeze` 默认 `split` 一定产生左右两段，
但普通 split 仍会拒绝边缘；其后右段索引、FreezeSliver 与插入位置都不成立。
此外原 ripple 使用 `time - 0.0005`，极近起点时会把应该保留的左段也后移。

## 修复

- 定格专用 `FreezeFrame.contains` 使用有限半开范围 `[timelineStart, timelineEnd)`，
  同时接到手动选择、MCP 默认 V1 选择、入口/CAS 准入和纯值插入；全局 `EditClip.contains` 不变。
- 在精确起点，直接在原段前插静帧。原段保留同一 ID、完整源窗及其余字段，只改时间线位置；
  不创建零长度左半，也不把完整的短片当成 FreezeSliver 删除。
- 内部切点共用 `TimelineClipSplit` 的既有字段复制规则，左右源长度必须为正。
  普通 `TimelineState.split` 继续保留原 1 毫秒准入；定格的 ripple 显式排除保留下来的左段。
- 半开末端、V1 转场、隐藏/非视频准入以及单飞、最终 CAS、一次提交/撤销路径保持原约束。
- `insertFreeze` 本身只改目标轨；真实 `perform` 仍按既有 linkage 开关跟随主轨画面。
  没有新增联动抑制，也没有改音频/字幕的产品规则。

为满足单文件上限，将真实出现第二个消费者的 split 纯值体抽成 65 行顶层类型，
`VideoEditTimelineEdits.swift` 从 600 降到 559 行。21 份显式 swiftc 清单机械补同一源文件，
现有 upscale 复制扫描跟到新文件。

## 验证

- `/bin/bash scripts/check-freeze-frame.sh`：118/118，通过。覆盖磁吸开/关下段首前插、
  同 ID 全字段保留、完整短片保留、分数起点 + speed 2 下的近起点与近末端、
  半开末端/非有限数拒绝、普通 split 不变、目标轨边界和既有 linkage 纯值跟随。
- 安全反向只改 `/private/tmp` 的源副本，生产树保持同一哈希：
  恢复旧 insertFreeze 后 89/98，9 条预期红；保留修复只删左段 ripple 保护后 117/118，
  仅该条红；恢复旧 isFreezeEligible 的扫描副本也红。前一组失败后的索引安全 guard
  不执行后续依赖断言，因此计数少于正向，并非把跳过当通过。
- 本机正反向日志：`/private/tmp/skycut-freeze-boundary-positive-20261104.log`、
  `/private/tmp/skycut-freeze-boundary-reverse-20261104/evidence.json`；
  最终正向 `/private/tmp/skycut-freeze-boundary-restored-20261104.log` 再次 118/118，退出码 0。
- project-file-wiring、source-file-size 通过；source-list 21 份脚本、16 个模型同伴及内部依赖闭合，
  结果见 `/private/tmp/skycut-freeze-boundary-source-lists-20261104.log`。
- 修复后的完整 App / helper 重链通过（18.51 秒），隔离 App 的后台 MCP 六例边界全部完成，
  并写入完整状态验收 16 项通过的结果。裁切首帧请求源时间 `300/600`，原生实际时间
  `6144/12288`，均为 0.5 秒；半开末端准确拒绝，量化到使用窗之前的真实源帧在 author 时拒绝。
  证据在本机 `srtflow-film-production-fixed-mcp-20261104/official-evidence-1793783454563751000`，
  含原始回包、六例 checked 文件、PNG 阅图及 `state-smoke-summary.json`。
- 首次重跑的 driver 把 `/tmp` 与 `/private/tmp` 同一物理文件误判为不同路径；只将两处夹具断言
  改为物理路径比较，原生 identity.path 仍严格比较，异文件和篡改身份负例仍拒绝。
  原失败与 raw-reply 正反向证据保留，不把那次未完成的六例算作通过。
- 上述实际 MCP 不声称覆盖 App perform 下 A1/字幕跟随、云端生产启用或服务端并发验收；
  联动规则另由既有纯值检查与原生产路径保持证据覆盖。

## 教训 / 防回归

普通分割的两端余量不是画面采样的时间定义；允许首帧前，必须把准入、插入、
零长度片段和 ripple/尾段删减一起核对。长期合同放在
[定格](../architecture/freeze-frame.md) 的准入与纯值变换章节。
