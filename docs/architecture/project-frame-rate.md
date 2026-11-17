# 工程帧率：唯一事实来源与容差空间

> 2026-08-07 随录屏功能的 Phase 1 落地。案例背景见
> [bugfixes/2026-08-07-screen-recording-foundation-review.md](../bugfixes/2026-08-07-screen-recording-foundation-review.md)。

## 长期约束

1. **帧率只有一个来源：`TimelineState.frameRate`（`ProjectFrameRate`，24/30/60，默认 24）。**
   预览合成的 `frameDuration`、`VideoEditExporter` 九处滤镜的 `fps=` / `r=`、
   预渲染的临时时间线、关键帧容差，全部从它取。任何地方**不许再写死帧率** ——
   `checks/no-hardcoded-fps.sh` 扫描守卫拦（含 `minimumFrameInterval` 与
   `AVVideoExpectedSourceFrameRateKey` 的字面量；用文件系统枚举，未 `git add`
   的新文件也在保护范围内）。

2. **工程格式 v5 无条件落盘帧率。** 默认 24 也要写键、也要写 v5 —— v4 及更早把
   帧率硬编码成 30，省略键+降级会让同一文件在旧版按 30 fps 出片（版本闸门要防
   的正是这种语义分裂）。回退只发生在**读** v1–v4 老文件（缺键按 24）。

3. **关键帧容差分空间**（最容易写错的一处）：
   - `KeyframeTrack.keys[].time` 是 **source time**。source 比 timeline 快
     `speed` 倍，所以 source 侧容差 = `工程半帧 × |speed|`
     （`KeyframeTrack.sourceTolerance(frameRate:speed:)`）。
   - ‹ › 跳帧先把 source 映射回 timeline 再比较，那一侧**只用工程半帧，不再乘
     speed**（乘了是重复折算）。
   - 方法签名强制显式传 `tolerance`，不给默认值 —— 逼调用方想清楚自己在哪个空间。
   - 30 fps 的半帧恰等于迁移前写死的 `1/60`，30 fps 工程行为不变。

4. **`TimelineExportSelection.subset`（只导出选中的）与预渲染的临时 `TimelineState` 必须继承帧率**，
   漏了就是「选段导出退回 24」「预渲染产物接缝对不上」。

5. **`minimumFrameInterval` 是上限不是固定帧率**（录屏侧，Phase 0 实测）：
   idle 帧不带 image buffer 且占比可达 45–62%，录制产物是**变帧率**的，
   导入时长必须取容器时长，不能按帧数推。

6. **主轨拼接链的 timebase 合同**（帧率的下游，别只对帧率不对它）：
   - 每一节的产出统一是 `1/fps` —— 素材段的 `fps=<帧率>`、补黑场的
     `color=…:r=<帧率>` 都按帧率设 timebase。
   - `concat` 的输出**固定**是 `AVTB`(1/1000000)，这是 ffmpeg 写死的，
     改不了也别指望它跟随输入。
   - `xfade` 在 `config_output()` 里对两条输入的 timebase 做**逐字段相等**的
     硬检查，不等直接 EINVAL、整个导出配置失败。因此 `VideoEditExportGraph`
     在每个 `xfade` 前把两侧都 `settb=AVTB`；`xfade` 的输出继承第一条输入，
     于是也是 `AVTB`，与 `concat` 一致，整条链自洽。
   - 往拼接链里加新滤镜或新的段类型时，除了帧率/SAR/pix_fmt，**timebase 也
     要一起对账**；用例必须覆盖「硬切与转场混排、且转场不在第一处接缝」，
     否则这类问题按顺序才现形。事故见
     [转场前面有硬切就导不出](../bugfixes/2026-08-12-xfade-timebase-mismatch.md)。

7. **Time ↔ frame number goes through `FrameGrid` (SrtFlowCore, 2026-11-17).** `frame(containing:)`,
   `firstFrame(atOrAfter:)` and `time(ofFrame:)` allow for floating-point noise (1e-6 of a frame). A plain
   `floor(time × fps)` is wrong on exact frame times — 123 / 30 s × 30 = 122.99999999999999 — and on sums like
   `0.5 + 10 / 30`; it made exported text and shapes repeat a frame, and the preview stopped on such a frame drew the
   overlays one frame behind ([case](../bugfixes/2026-11-17-overlay-export-repeats-a-frame.md)). Output frames of the export graph are not exactly on
   the grid either: after `concat` / `xfade` their AVTB timestamps sit microseconds before or after it (at 30 fps after a
   crossfade, 0.7 µs early). Anything ffmpeg must line up with an output frame (an overlay frame, an `enable` edge) sits
   half a frame away from the grid, never on it — see [画面文字](text-overlays.md)「Frames on the grid」.
   This includes upper-track video (both ordinary streams and prerendered fill + matte), covers (blur / mosaic) and
   grades: reuse `OverlayExportFile.enableWindow` for their left-closed, right-open windows. Upper video also uses
   `OverlayExportFile.placement` and two cloned tail frames so framesync picks the current frame and EOF cannot drop
   the last one. Cover streams keep the main stream's timestamps; only their enable edges move.
   Preview/AI cover and grade selection uses `FrameGrid.contains(_:from:to:)` too: adding start + duration can put
   an exact end a few ulps after its frame, so comparing raw seconds on the read side can also keep one extra frame.
   See the [upper-video / cover / grade case](../bugfixes/2026-11-17-export-layer-frame-windows.md).

## 回归矩阵（谁守什么）

| 检查 | 守什么 | 局限 |
| --- | --- | --- |
| `checks/no-hardcoded-fps.sh` | 源码里不出现写死的帧率 | 静态扫描，不验行为 |
| `scripts/check-export-frame-rate.sh` | **真实 `VideoEditExportGraph.plan()`** 的参数与实际出帧（24/30/60 → 48/60/120 帧，源素材 10fps 排除透传）；另有硬切+转场混排两种顺序的拼接链用例（约束 6） | 需要 vendor/ffmpeg |
| `scripts/check-preview-composition.sh` | 预览合成 `frameDuration` + 真导出出帧率 | `AVAssetReaderVideoCompositionOutput` 直通时按源帧透传，必须真导出才测得出 |
| `scripts/check-export-alpha-compositing.sh` | alpha 合成数学与帧率无关 | 只取第一帧，**帧率写错它发现不了** —— 别拿它当帧率回归 |
| `SrtFlowCoreChecks` | `ProjectFrameRate` 纯逻辑 + v5 持久化 + 容差 | 纯逻辑 |
| `scripts/check-text-render.sh` group 20 | every exported frame of moving text / shapes is the frame for its own time at 24 / 30 / 60 fps (constraint 7) | needs vendor/ffmpeg |
| `scripts/check-export-frame-rate.sh` (`LayerWindowChecks`) | every frame of upper video (ordinary and fill + matte), blur, mosaic and grades at 24 / 30 / 60 fps over cuts/crossfades; native preview comparison and preview/AI stack boundaries | needs vendor/ffmpeg; AI look's cover selection is pinned by `checks/project-file-wiring.sh` |

## 反向验证要求

新增帧率相关守卫时必须做反向验证（故意注入错误确认它变红）——
`no-hardcoded-fps.sh` 曾因用 `git ls-files` 而对未跟踪文件静默放行了好几轮。
