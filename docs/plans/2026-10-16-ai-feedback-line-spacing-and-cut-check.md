# 2026-10-16 第三批 AI 反馈：字幕行距、入点说明、一次检查 V1 的剪辑点

2026-10-16 用户转来测试员（AI 会话）的第 8–10 条反馈，问「看下这些是否需要优化下」。核对代码后的结论是三条都值得做、
分量差很多；用户定「按照你的建议来」，所以下面的板是我拍的，理由写在这里。实施状态以 PR 和代码为准。

## 三条反馈与核对

**第 8 条：字幕样式没有行距。** 「Yuanti SC 两行字幕挨得很紧，样式里没有 line_spacing 可以调。」

- 真缺：`BurnInStyle` 只有字距（`letterSpacing`）没有行距；烧录页的样式编辑器、AI 的 `style` 都没有。
- 圆体挨得紧有量化的原因：libass 把每种字体的一行高度都钉成字号（按 OS/2 的 usWinAscent + usWinDescent 撑满），字形大小按这个
  量度反推。本机量到：

  | 字体 | winAscent + winDescent（em） | 同字号下的字形相对大小 |
  | --- | --- | --- |
  | Yuanti SC Regular | 1.008 | 1.39× |
  | Hiragino Sans GB | 1.16–1.24 | 1.13–1.21× |
  | Helvetica | 1.18–1.25 | 1.12–1.19× |
  | PingFang SC | 1.400 | 1× |

  圆体的字形几乎占满整行，两行自然碰在一起。预览按同一口径画（`SubtitleFontScale` / `SubtitleLineMetrics`），所以预览也紧，
  是一致的限制，不是 bug。
- 难点在烧录：ASS 没有行距这一项，ffmpeg 的 subtitles 滤镜也没暴露 libass 的 `ass_set_line_spacing`。

**第 9 条：edit_clip 改入点的行为说明不够清楚。** 行为是故意的（AI 给绝对值，开头不动、结尾动），只写在代码注释里。
见 [案例](../bugfixes/2026-10-16-edit-clip-trim-semantics-undocumented.md)。

**第 10 条：缺一个检查剪辑点的功能。** 「这次是逐个片段用 listen 确认每个剪辑点前后都是静音。建议加一个功能，一次性报告 V1 上
每个剪辑点是不是落在静音里、会不会切到字。」

- 真缺，但零件都在：判「这一刻在不在停顿里、切不切到字、最近的停顿在哪」的算法就是 cut_speech 用的 `AISpeechCutPoints`
  （电平窗、停顿、转写缓存、链接的声音从哪段来），缺的只是对 V1 每一段的头和尾各跑一遍、按时间线列出来。

## 拍的板

1. **顺序：9 → 10 → 8**，各自一个 PR（AGENTS「一个 PR 只做一件事」）。9 是一句话；10 半天；8 最大，而且烧录那一侧要先做探针。
2. **第 10 条做成 `listen cuts=true`**，和已有的 `beats=true` 一个样子，不另开工具：单开一个「检查剪辑点」会和 listen 长得像
   （清单的规矩「不许两个长得像」），塞进 `get_timeline` 也不行 —— 量声音要等波形读完，listen 已经有「40 秒没读完先给一半、请再调」
   那套。只查 V1（口播在 V1，同 cut_speech）；每一段的头和尾各量一次，相邻的两段合成一个剪辑点报，开着缝的各报各的；
   转写只读缓存、不起任务（listen 是只读工具），没有缓存就只按声音判并说一句。每个切口报：在停顿里 / 在声音上、切到的词、
   建议的 source_in / source_out（AI 直接拿去 edit_clip）。
3. **第 8 条的行距是倍数 1.0–2.0，默认 1**，和画面文字的 `lineSpacing` 同口径（`TextStyle.lineSpacingRange` 是倍数）。下限是 1：
   烧录只能加大、不能收紧（见下一条），预览和 AI 的框照同一个数。
4. **烧录用垫片空行**：PR #217 之后折行点已经由 App 自己算好写成 `\N`（`BurnInWorkspace.prewrapped`、WrapStyle 2），可以在两行
   之间插一行很矮的空行（`\N{\fs<垫片>}\h\N` 一类，字号换回去），libass 给空行的高度就是当时生效的字号。**要先用仓库的 ffmpeg
   真烧量过**（现成的「预览离屏渲 vs 真烧量上下沿」那套自检 `PositionChecks` 加两行 + 行距的样本），实测不对就换路子，不许凭印象写。
   垫片只在烧录（prewrapped 那条路）写，导出给别人用的 .ass 文件不带这种 hack。
5. **工程文件不为它 +1 版本**：行距存在 `BurnInStyle` 的 JSON 里，老文件缺键按 1 读，老 App 读新文件忽略不认识的键，两个方向都
   宽容；在工程文件文档里记一句就够。

## 分刀

| PR | 做什么 | 守卫 |
| --- | --- | --- |
| 1 | edit_clip 的说明 + 参数说明写明开头不动、结尾动 | `ProtocolChecks` 查说明含「timeline start stays」 |
| 2 | `listen cuts=true`：V1 每个剪辑点在不在停顿里、切到哪个词、建议的入出点 | `ListenChecks` 用合成的电平和转写：停顿里 / 声音上 / 相邻合并 / 开缝分开 / 第一段的头、最后一段的尾 |
| 3 | `BurnInStyle.lineSpacing`：模型、预览、AI 的框、烧录垫片、`style.line_spacing`、烧录页滑杆、各语言文案 | `SubtitleRenderChecks`（1 不写垫片、>1 写）、`PositionChecks` 真烧对上下沿、工程文件缺键读 1、`SubtitleStyleChecks` 的范围 |

清单预算：动手前 83,914 / 90,000 字符（47 个工具，含 fal 的两个），三条加起来约 700。
