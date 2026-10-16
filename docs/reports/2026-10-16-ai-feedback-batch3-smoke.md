# 2026-10-16 第三批 AI 反馈的测试版冒烟（0.18.35，扮成 AI 客户端）

对应方案：[第三批 AI 反馈](../plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md)。三个 PR（#218、#219、#220）合进 main 83fda3e 之后出测试版
0.18.35 装上，用 `scripts/gui-smoke/mcp-client/client.py` 驱动它的小程序，素材是 L30 课程（英文口播、2560×1440、1:41，拷到 scratchpad）。

## 一次查完 V1 的剪辑点（`listen cuts=true`）

- 新工程、整条 L30 上 V1，`transcribe` 命中缓存；`listen clip_id` 量到的停顿（≥ 0.3 秒）有 27.179–27.648、56.448–56.917 等。
- 切三刀：27.45（停顿里）、38.9（「custom AI」里的「AI」上）、56.7（停顿里；转写把「Your」的开口估在 56.50，声音说 56.917 才开口）。
- `listen cuts=true` 报 5 个剪辑点：0 和 101.334 两头 in_pause；27.45、56.7 两头都 in_pause（56.7 这一刀证明是先听声音、不信转写的开口）；
  38.9 两头 on_speech、词「AI」、建议 38.464（「moved to the quiet spot between the words」）。`from=30 to=60` 只剩 38.9、56.7 两个；
  带 `clip_id` 报错说清楚 cuts 查的是整条 V1。
- 照建议改：`edit_clip` 前一段 `source_out=38.464 ripple=true`（结尾左移 0.436 秒、后面的 V1 跟着左移），后一段 `source_in=38.464 ripple=true`
  （时间线上的开头不动、结尾右移回去）—— 和 #218 写进说明的语义一致。`undo steps=1` 正好退掉最后那一次 edit_clip（含 ripple）。
- **撞出一个 bug**：改完再查，38.464 这个剪辑点两头报 on_speech、词「custom」、没有建议 —— 它自己建议的那一格又被判成切到字。根因和修法见
  [案例](../bugfixes/2026-10-16-listen-cuts-suggested-spot-reported-on-speech.md)（加 `quiet_spot` 一档）。

## 字幕行距（`style.line_spacing`）

- 这台 Mac 上 Yuanti SC 不能用于烧录（cmap 体检没过，`style.font` 报错并列出能用的字体），改用 win 量度同样只有 1.0 em 的 Songti SC 72 号。
- 两行中文字幕，`get_subtitles` 的框：行距 1 时高 0.14、1.3 时高 0.16（+0.02 = 0.3 × 72 / 1080），框往上长（底部对齐）。
- 量图（字幕黑描边的暗像素，1080 高的单位）：

  | 图 | 两行字的描边占的行 |
  | --- | --- |
  | 预览 look，行距 1 | 879–1030 一整块（两行的描边连在一起，就是测试员说的「挨得很紧」） |
  | 预览 look，行距 1.3 | 858–928、952–1030（第一行上移 21 px，两行之间空出 24 px） |
  | 成片 1080p，第 3 秒那一帧 | 860–928、950–1030 |

  成片和预览的两行上下沿差 ≤ 2 px、互相关的竖向偏移 0 行；`export_video` 结果报 1920×1080、24 fps。

## 没做的

- Yuanti SC 本身在这台机器上进不了字幕字体清单（圆体的 cmap 坏，见 2026-09-29 的案例），圆体两行的效果要在测试员那台装着能用的圆体的机器上看。
