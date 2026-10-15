# 2026-10-15 预览里字幕的自动折行是贪心的，成片（libass）是摊匀的

## 症状

2026-10-15 傍晚在测试版 0.18.32 上跑 [AI 接口](../architecture/ai-control-mcp.md) 第八节新加的两项真机回归（字幕的框、撞水印），顺带量到：
一句不带换行符、一行放不下的字幕，预览和成片折行点不同。测试句
`This is a much longer subtitle line that goes on and on so that it has to wrap onto a second line at the bottom`，默认样式
（Helvetica 粗体 56、底部居中、左右边距 80），1920×1080：

| 渲染面 | 第一行 x（画布比例） | 第二行 x |
| --- | --- | --- |
| 预览（`BurnInSubtitleOverlay`，SwiftUI 的 Text 自己折） | 0.058–0.941（78 个字符，贪心填满） | 约 0.31–0.69（32 个字符） |
| 成片（libass，ASS 头 `WrapStyle: 0`） | 0.184–0.815 | 0.187–0.813（两行差不多宽） |
| `get_subtitles` 报的 box（`SubtitleLineBoxes`，PR #215） | 0.18–0.82（宽 0.64，lines 2） | 同上 |

一行放得下的句子三者在 0.005 以内对得上，竖向的两行高也对（9-29 的两个案例修过），**只有折行点错**。影响面：

- 剪辑页预览、烧录页播放中的叠层、AI 的 `look`（`AIFrameComposer`）都用这个视图画字幕 —— AI 看到的也是贪心折的。
- `subtitle_overlaps`（PR #215）跟的是框 / 成片，用户在预览里看到的「撞上 / 没撞」可能和它不一致。
- 更根本的：预览和成片本来就该一样（和 9-29 那两个案例同一类 —— 两个渲染器对同一份样式画出不同的东西）。

是老问题（从 2026-07-30 有这个叠层起就这样），不是 #212–#215 引进的。位置自检 `checks/SubtitleBurnSize/PositionChecks.swift` 里所有两行样本都带显式
`\n`，自动折行从没量过，所以一直绿。

## 根因

**同一句字，三个地方各用一套折行算法。**

1. 预览：`styledLines` 只按 `\n` 拆成一行一个 `Text`，每个 Text `.lineLimit(nil)` + `.fixedSize(horizontal: false, …)`，整块 `.frame(maxWidth: usableWidth)`，
   放不下的行由 SwiftUI 自己折 —— 贪心（第一行填满）。
2. 成片：libass 的 WrapStyle 0 是「先贪心断行，再把上一行最后一个词往下挪、只要两行宽度之差变小就挪，挪到挪不动」（`ass_render.c` 的
   `wrap_lines_naive` + `wrap_lines_rebalance`），所以两行摊匀。
3. AI 读的框（`SubtitleLineBoxes.lineWidths`，#215 新加）：用 Core Text 的断行点 + 二分「还装得进这么多行的最小宽度」模拟。两行时和 libass 碰巧一致，
   五行时折在别处（100 号 Helvetica 的一句：二分给 1490 / 1462 / 1358 / 1339 / 1097，libass 真烧是 1698 / 1548 / 1335 / 1047 / 1088）。

顺带查明一件事：**libass 只在 ASCII 空格处折行**。vendor/ffmpeg 里的 libass（≥ 0.17，二进制里有 `libass wasn't built with ASS_FEATURE_WRAP_UNICODE support`
这句）没编 libunibreak，ffmpeg 的 `subtitles` 滤镜也没开那个 feature，所以没有空格的中文一行放不下时**不折、整行溢出到画面两边**（真烧核过：
一句 55 个字的中文墨迹从 x 2 到 1918）。以前预览和框都替它折了 —— 又是一处预览和成片不一样。

## 修复

**改预览和框、不改成片**（同 9-29 两个案例的取舍：成片、别的播放器打开的 .ass 都是 libass 的样子）：

- **`SubtitleLineWrap`**（新，`Sources/SrtFlow/SubtitleLineWrap.swift`）：折行点只有这一份。对着 libass 0.17 的源码 port 三步：
  贪心（从行首第一个字的墨迹左沿量到当前字的墨迹右沿，≥ 最大宽就在上一个空格处断；当前字是空格不算溢出；没有空格不断）、
  摊匀（每轮对每对相邻的软断行试着把上一行最后一个词挪下去，`|l1' − l2'| < |l1 − l2|` 才挪；上一行只有一个词跳过；挪过再来一轮）、
  去空白（行首行尾的空格不画、不算宽；一行的宽 = 步进之和，libass 居中按它）。字的位置和墨迹从 Core Text 来：一个自然段排成一行
  （`CTLineCreateWithAttributedString`），逐 glyph 取位置、步进、字体的 bounding box；空格当零宽（libass 里空轮廓的 bbox 归零）。
  每一截的字体按 `SubtitleFontScale.runs`（回退的也算、按 libass 的比例缩），亮着的词按倍数放大（烧录的 `\fs` 也放大，折行要算上）。
- **`BurnInSubtitleOverlay`**：body 里算一次 `lines`，**一行一个 `Text`、只画算好的那一行**（`lineLimit(1)` + `fixedSize(horizontal: true, vertical: true)`），
  不让 SwiftUI 再折第二次（Core Text 和 SwiftUI 量宽差一两个像素时它会多折出一行）。行里再按字体边界、亮着的词的边界切 piece。
  放不进一行的（没有空格的中文）就溢出，和 libass 一样。
- **`SubtitleLineBoxes`**：行数和每行的宽改问 `SubtitleLineWrap`，删掉二分那一份；块宽不再夹到可用宽度里（中文溢出时框照实比画面宽），
  `get_subtitles` 的 `box_note` 加一句「比画面宽 = 放不下，没有空格的字不折」。

## 验证

- **先用探针对着真烧核算法**（scratchpad 里的 `wrap-probe`：预览离屏渲一张、`BurnInWorkspace` + vendor/ffmpeg 真烧一帧，按墨迹的空白行切成几行，
  比每一行的左右沿；同时打印 `SubtitleLineWrap` 算的每一行是哪几个字）。19 种句子 —— 两行 / 三行 / 五行、中英混排（Helvetica、Hiragino）、很长的单词、
  一个比画面还宽的单词、没有空格的中文、带空格的中文、布局覆盖左右不对称（500 / 100）、9:16（六行）、左对齐、右对齐、逐词高亮放大 1.2 倍、
  两个空格、字距 3、带换行的两段、100 号五行 —— 修完**全部**预览 vs 成片每一行左右沿差 ≤ 3 px（1080p），行数全对。修之前预览第一行 1698 px、
  成片 1212 px。
- **新自检** `checks/SubtitleBurnSize/WrapChecks.swift`（`scripts/check-subtitle-burn-size.sh`，第 3 组）：17 种句子预览 vs 真烧按行比左右沿（容差 4 px）、
  行数要等于 libass 烧出来的、预览每行的墨迹宽要和 `SubtitleLineWrap` 算的步进宽对上（差一个词就红 —— 管切 piece）；再钉 libass 的规矩本身（纯算）：
  100 号五行的每一行是哪几个字、两行摊匀、行首行尾空格不进行、换行符各自成段、亮着的词放大那一行变宽、没有空格的中文一行且比画面宽（框也是）、带空格的中文折。
  `checks/MCP/SubtitleBoxChecks.swift`（`scripts/check-mcp.sh`）：「中文没有空格也折」改成「不折、框比画面宽」，加「框的行数 = `SubtitleLineWrap` 的行数」。
- **反向验证**：见文末「反向验证记录」（撤掉修复、守卫真红过，再恢复）。
- 回归面：剪辑页预览、烧录页播放中、`look` 是同一个视图；接口没变（`BurnInSubtitleOverlay` 的参数不动）；没有新视图类型，`checks/preview-perf-wiring.sh` 过；
  `checks/check-script-source-lists.sh` 过（两个脚本的清单都加了新文件）。
- 真机：装上新测试版后 `look time=9.5` 第一行 x 应在 0.18–0.82 附近、和成片抽帧一致，`get_subtitles` 的 box 不变 —— 写进
  [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md) 的人工清单。

## 已知不足

- ~~没有空格的长中文句成片不折、溢出两边，预览和框照实画~~ —— 当天晚上用户拍板「要折」：烧录改成照 `SubtitleLineWrap` 写 `\N`、WrapStyle 2，
  中日文在字之间折，见 [没有空格的长中文字幕成片整行溢出](2026-10-15-chinese-subtitles-overflow-without-spaces.md)。
- 折行点按 Core Text 的字宽算，libass 按 FreeType + HarfBuzz，一行的宽正好卡在最大宽度一两个像素以内时两边可能差一个词（样本里没撞上）。

## 教训 / 防回归

- **「一份数值、两个渲染面」连折行点也要比。** 9-29 比了大小、比了位置，两行样本全带显式换行，自动折行这一维漏了一个月。比两个渲染器时把
  「渲染器自己拿主意」的每一维都列出来：大小、行框、折行、对齐。
- **对一个有源码的渲染器，别猜近似算法，照源码 port。** #215 的二分最小宽度在两行时碰巧对、五行时错；libass 的摊匀是逐词的局部挪动，不是全局最优，
  只有照抄才一致。port 完一定真烧核 —— 探针先跑一遍，守卫再钉。
- **先问渲染器到底做不做，再决定自己做不做。** libass 不折中文是查二进制里的字符串 + 真烧才确认的；以前两处都「理所当然」地替它折了。
- 长期约束写在 [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md)「画面上的布局」第 2 条、
  [AI 接口](../architecture/ai-control-mcp.md) 第四节第 51 条。前两个案例：[成片里的字幕比预览小一截](2026-09-29-subtitle-preview-bigger-than-burn.md)、
  [预览的位置和行距和成片对不上](2026-09-29-subtitle-preview-line-box-differs-from-libass.md)。

## 反向验证记录

- 修好后本机 `scripts/check-subtitle-burn-size.sh`：**All 253 checks passed**（原有 90 条大小 / 位置 / 阴影 + 新加的折行一批）。17 种句子预览 vs 真烧每一行
  左右沿最大差 3 px（Hiragino 混排的第二行：预览 335…1583、成片 333…1586），其余 ≤ 2 px。
- 撤掉修复（把叠层换回「一个自然段一个 Text、`lineLimit(nil)` + 横向不 `fixedSize`、让 SwiftUI 自己折」）再跑：**78 of 217 checks failed**，
  17 种句子**每一种都红**（行数不对、每一行左右沿不对、预览每行的宽和 `SubtitleLineWrap` 算的不对三类都红），比如 reported sentence
  「row 1 spans x 103…1801 in the preview, 353…1565 burned」、五行那句预览折成 6 行、9:16 折成 4 行（libass 6 行）、没有空格的中文预览替它折成了 2 行。
  纯算的那几条（libass 的规矩本身）不红 —— 它们钉的是 `SubtitleLineWrap`，这次没动它。
- 恢复修复后再跑：全绿（253 / 253）。
