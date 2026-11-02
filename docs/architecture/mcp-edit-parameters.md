# MCP 编辑参数：校验、实际值与素材就绪

`edit_clip` / `edit_clips` 复用 `AIClipTools.plan`、`AIClipEditPlan` 和 `AIClipEdit`，不为批量另做校验。
`set_text(s)` / `set_shape(s)` 同样复用 `AIOverlayEdits` 与原生模型的收口规则。
本合同不改变产品限制，也不扩展静帧素材的长度。

## 范围来源与处理政策

`get_timeline.edit_limits` 从 `AIEditLimits` 返回当前运行版本的范围和 `policy`。不要在 MCP 说明中再抄一份
原生数值；错误中的 `allowed` 是当前素材 / 窗口的合法范围，成功结果中的 `limits` 只回与本次字段有关的项。

| 参数 | 唯一范围来源 | 政策 |
| --- | --- | --- |
| 速度 | `TimelineTrim.clipSpeedRange`（检查器 / 原生写入同用） | 越界拒绝 |
| 源窗口最短长度 | `TimelineTrim.clipMinimumDuration` | 越界拒绝 |
| 图片源窗口最大长度 | `StillImageClipFactory.stillDuration`（真实循环素材） | 越界拒绝，不再悄悄截短 |
| 视频 / 声音出入点 | 实际素材时长 + 最短窗口，边界舍入复用 `ClipFileReplacement.tolerance` | 大幅越界拒绝；既有微小舍入容差保留并反馈 |
| 音量 / 曲线 / 推子 | `AudioGain.minimumDB` / `maximumDB`，线性增益仍由 `AudioGain` 转换 | 原生限幅，回实际 dB；最小 dB 对应静音 |
| 手动四边裁切 | `ClipCrop.maximumManualInset` | 越界拒绝，建议 `region`；不限制原生 region / 自动取景 |
| 静态 x/y / scale | `MCPFramingLimits.center` / `scale` | 越界拒绝；省略字段保留已有布局，不把 region 的大倍率夹回手动范围 |
| 关键帧 | `MCPFramingLimits` + `AIKeyframes` / `KeyframeTrack` | 原有位置、大小、角度、不透明度限幅和同帧合并照旧，回实际点 |
| 淡入淡出 | `FadeWindow` / `AudioFadeWindow` / 动画自己的 `window` | 回实际窗口，包含两端比例收缩及转场优先 |
| 文字 / 形状 | `TextStyle`、`TextOverlay`、`ShapeAnnotation` 与其原生写入路径 | 原有限幅照旧，回实际几何、字号、动画窗口等 |

图片源窗口仍归零，长度按请求的出点减入点计算；时间线长度还受速度影响。窗口规则由 `AIClipSourceWindow`
同时供新增与编辑调用。同步旁白的计划也经过相同编辑内核，不能绕过速度或源窗口能力限制。

## 错误与成功反馈

非法请求在提交前抛 `AIToolError`。MCP `isError=true`，文字内容是 JSON，含 `status=invalid_parameter`、
`parameter`、`requested`、`allowed`、`suggested`、`retryable=false`、`changed=false`。没有任何合法源窗口时，
返回更换较长素材的 `suggestion`，不能捏造一个仍然非法的建议数字。批量失败保留这些字段并增加 `batch` / `index`。
无音轨的画面不能请求音频音量或淡变，返回 `unsupported_parameter` 并提示画面应使用 entrance / exit。
旧的非参数错误仍保留纯文字合同。

成功结果的 `requested` / `applied` 从本次输入及**提交收尾后的最终工程**产生，`adjustments` 列出差异及原因。
默认值相同也返回 applied；原生限幅不能只回请求值。例如请求音量 +8.1 dB 时，applied 必须来自实际线性增益的
反算，不能把 dB 四舍五入成另一个限制。曲线按段首读值，并说明平移后部分点饱和。
`set_track`、`set_keyframes`、文字 / 形状单项与批量、`add_clips` 和定格时长同样提供实际值。
关键帧的 applied 从实际轨直接读取，不能复用三位小数的展示摘要再当精确值。

旧的 start/end 等摘要字段保留兼容的展示精度；核对本次数值请使用 applied。后续批量条目、磁吸或联动改变了落点，
也必须按最后的状态报告，不能逐项报中间候选状态。

## 原子性与素材就绪

所有参数解析、素材读取和几何计算先在副本中完成；探到的 `MediaInfo` 也随有效编辑一起采用，不提前写进工程。
异步准备之后按原片段身份和内容、画布及批量快照检查是否过期。任何字段失败都不提交、不记撤销、不重建预览。
成功继续使用现有 `perform` / `AIBatchEdit`，不增加另一套事务机制。

`AIClipReadiness` 与 `MediaProbeCache.State` 区分：

- 图片转换未完成、真实元数据探测在途：`media_loading`、`retryable=true`、`retry_after_ms`。同参数稍后重试。
- 尺寸缺失但尚未探测：异步编辑先复用原生探测；同步关键帧入口启动同一缓存任务后返回 loading，重试消费缓存。
- 文件缺失或一次真实探测已失败：`media_unavailable`、`retryable=false`、具体 `reason`；建议重链接 / 换源，不称作已证明损坏。

只改图片时长 / 位置不需要尺寸，可以继续编辑占位块。取景 / 画面效果则等待转换完成。
探测任务按 URL 合并，缓存成功和失败状态；失败不会永久锁死重探，但不能在没有任务进行时无限回“正在加载”。
可播放的静帧视频已经就绪时，不因原图暂时缺失而拒绝编辑。

## 回归

- `scripts/check-mcp.sh`：各类边界 / 越界 / 正常值、合法建议、原生限幅与精确反馈、后项失败、单项 / 批量共用。
- `scripts/check-parameter-limits.sh`：完整 App 对象、临时工程与合成视频 / 图片；失败零修改、成功一次提交 / 撤销、
  实际 gain/fades、真实探测、图片转换前后相同请求重试，缺失与不支持素材区分。
- 修改限制或结果字段时做反向验证：撤掉生产修复必须使对应守卫变红，然后逐字恢复并重跑。

人工回归：真实录屏图片刚拖入后立即用 MCP 取景，若返回 loading，等转换后同请求应成功；同时在检查器核对 applied，
用一次撤销恢复。该项涉及真实窗口和交互，不能由独立 App 对象检查替代。
