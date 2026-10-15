# 2026-10-15 没有空格的长中文字幕，成片整行溢出到画面两边

## 症状

手打或导入的一句长中文字幕（没有空格、没有换行），一行放不下时成片里**不折行**：整行从画面两边溢出去，两头的字被切掉。
[上一个案例](2026-10-15-subtitle-preview-wraps-greedily.md)（PR #216）之后预览和 AI 读的框也照实画成一行溢出 —— 三处一致了，
但一致地放不下。生成的字幕平时碰不到（`SubtitleLineFit` 按一行放得下来切），翻译成中文的译文、AI 用 `edit_subtitles` 写的长句、
导入的 .srt 会碰到。

## 根因

vendor/ffmpeg 里的 libass 没编 libunibreak、ffmpeg 的 `subtitles` 滤镜也没开 `ASS_FEATURE_WRAP_UNICODE`，`wrap_lines_naive` 只把
ASCII 空格当折行点（`ALLOWBREAK` 退化成 `symbol == ' '`）。中文没有空格，一个「词」就是整句，贪心那一步找不到能断的地方就不断。
PR #216 之前预览（SwiftUI 的 Text）和 box（二分最小宽度）都替它折了，和成片不一样；#216 把三处统一到 libass 的行为（都不折），
并把「要不要让烧录也能折中文」交给用户拍板。用户 2026-10-15 晚定：**要**。

## 修复

折行点仍只有 `SubtitleLineWrap` 一份，但现在**烧录也照它写**，libass 只照着画：

- `SubtitleLineWrap`：能起新一行的地方 = ASCII 空格之后（原来的）+ **中日文的字之间**（两边有一边是汉字 / 假名 / 注音 / 全角字就行，
  标点避头尾：行首不许是「，。、！？」』）」这类收尾的标点和小假名、长音，行尾不许是「（「『【」这类开头的标点）。韩文、拉丁字母、数字只在空格处
  （韩文词之间本来就有空格，拆词不好看；一个比画面宽的英文单词照旧溢出）。贪心 + 摊匀两步照旧，摊匀时「上一行最后一个词」对中文就是最后一个字，
  一次挪一个字，所以中文两行差不多宽、100 号四行是 1290 / 1376 / 1290 / 1376 这种 libass 式的局部摊匀。
  `usableWidth`（画面宽 − 边距）搬进这里：预览、框、烧录三处以前各抄一份；加 `joined` 把折好的几行写回成带换行的字，亮着的词的位置跟着换算
  （跨在折行点上的词拆成两截）。
- `BurnInWorkspace.prewrapped`：写 ASS 之前，每一块每一段事件的字换成折好的几行（字号 / 字距 / 可用宽度按 ASS 的虚拟画布算），三个烧录入口
  （剪辑导出 `VideoEditExportGraph`、烧录队列 `EncodeQueue`、烧录页预览 `BurnInPreviewRenderer`）都经 `create`，改一处就全改了。
- `BurnInStyle.assDocument(prewrapped:)`：写 `WrapStyle: 2`（不自动折、只认 `\N`）。不能留 0：一行宽正好卡在最大宽度一两个像素以内时
  libass（FreeType 的字宽）会再折一次、多出一行，预览和成片又不一样。`playResolution` 把 PlayResX 的算法（1080 高、宽取偶数）收成一份，
  `SubtitleLineBoxes.referenceBox` 也用它。
- `SubtitleLineBoxes`、`BurnInSubtitleOverlay`：可用宽度改问 `SubtitleLineWrap.usableWidth`；`get_subtitles` 的 `box_note` 改说
  「在空格处和中日文的字之间折；框比画面宽 = 一个词比画面宽」。
- 代价：英文的折行点也从 libass 的 FreeType 字宽换成 Core Text 的字宽。#216 真烧核过 19 + 17 种句子两边一致，差只在一行宽卡在边界一两个像素
  时可能差一个词；现在那种情况成片跟着预览走、不会多出一行，是往一致的方向变。

## 验证

- `scripts/check-subtitle-burn-size.sh` 的 `WrapChecks`：新加 8 种中韩文句子真烧 vs 预览按行比左右沿（没有空格的中文、冬青黑体、100 号四行、
  9:16 七行、带标点、中英文连着写、中文 + 高亮放大、带空格的韩文；日文只钉纯算的规矩，见已知不足；Helvetica 里的中文回退到哪一款看机器，这些用例只要求预览、成片、
  `SubtitleLineWrap` 三处行数一样，冬青黑体的用例钉死行数）；纯算的规矩：中文两行摊匀、100 号四行是哪几个字、逗号 / 开括号 / 长音插在任何位置
  都不落到行首 / 行尾、带标点的句子标点留在行尾、中英文连着写在中英文之间断、日文在假名和汉字之间折、韩文只在空格处折、超长单词照旧溢出、框同几行；ASS：WrapStyle 2、
  `\N` 正好一个、亮着的词换算到了新的字里、跨行的词拆两截、没有字的事件不动、用户自己的换行照旧是硬断。本机 335 条全绿（日文真烧那条去掉之前是 341）。
- 反向验证：`BurnInWorkspace.create` 把 `blocks` 原样交给 `assDocument`（不 prewrapped，libass 自己折）→ 25 / 327 条红（9 种中日文句子每一种都红，英文的照旧绿）：中文那几句成片一行溢出、
  预览两行（纯算的 prewrap 那几条直接调 `prewrapped` / `assDocument(prewrapped:)`，不经 `create`，所以照旧绿 —— 真烧的那几句才是证据）；
  恢复后文件逐字节一样（cmp），341 条全绿（反向验证跑在去掉日文真烧那条之前）。
- `checks/MCP/SubtitleBoxChecks.swift`：「中文不折、框比画面宽」改成「折成几行、框在边距以内」（`scripts/check-mcp.sh`，CI 跑）。
- `SrtFlowCoreChecks`：`assDocument(prewrapped: true)` 写 `WrapStyle: 2`、默认还是 0；`playResolution` 16:9 / 9:16 / 不像样的宽高比。
- 真机（2026-10-15 晚，测试版 0.18.34 出自这条分支，`scripts/gui-smoke/mcp-client` 那一套的驱动）：新建工程放一段 1920×1080 的素材，
  `edit_subtitles` 加一句没有空格的 55 字中文和一句带「，。」的中文，`get_subtitles` 两句都 `lines: 2`、框在边距以内（0.18–0.83、0.14–0.85），
  `look` 和真导出抽帧按行量白墨迹：没有空格那句两行都是 x 0.178–0.822（两边完全一样），带标点那句成片 0.157–0.843 / 0.147–0.841、
  look 0.158–0.842 / 0.147–0.841，标点留在行尾（「过去。等」/「…去。」）；修之前这种句子成片是一行、溢出到 x 0.00–1.00。

## 已知不足

- **日文没有真烧的用例**：第一次上 CI，日文那句预览和成片折的行一样、但每行两边各宽 17 px（约 2.5%）—— 没下载苹方的机器上假名回退到的字体
  预览和 libass 选的不是同一款粗细（本机有苹方、两边一样）。这是 `SubtitleFontScale` / `SubtitleFallbackFont` 字的大小那一头的事，不是折行，
  另案处理；折行的规矩日文照样钉着（假名和汉字之间折、小假名 / 长音不在行首）。

## 教训 / 防回归

- **渲染器做不到的，App 算好、把它关掉，比「照实画」更接近用户要的 —— 但三处仍要同一份算法。** #216 把折行点收成一份之后，这一步只是多一个消费者
  （烧录）；要是当时让预览自己折中文、成片不折，今天就要再对一遍。
- **先把事实摆出来，决定权是用户的。** 中文折不折、韩文拆不拆词，是产品口径不是实现细节：#216 先照实画并写进「已知不足」，用户看过再拍板。
- **关掉渲染器的自动行为要关彻底。** 写了 `\N` 还留 WrapStyle 0，一行卡在边界时 libass 会再折一次 —— 多出的那一行比折在别处更难看。
- 长期约束写在 [字幕轨可见性与布局](../architecture/subtitle-track-visibility-and-layout.md) 布局第 2 条。
