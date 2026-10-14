# 2026-10-14 审美盲测撞出的六处 AI 工具小毛病

> 来源：2026-10-06 审美盲测（[剪辑美感方案](../plans/2026-10-05-editing-aesthetics.md)，新旧风格卡各剪南极 / 课程 / 婚礼三条），
> AI 剪片时撞上、自己绕过去的六处工具问题。大的几条各有案例（[几个 AI 会话的改动落进别人的工程](2026-10-14-ai-edits-land-in-another-sessions-project.md)、
> [App 卡住时只会干等](2026-10-14-ai-calls-time-out-silently-when-app-hangs.md)、[look 看转场和成片对不上](2026-10-14-look-transitions-differ-from-export.md)、
> [文字入场闪一帧](2026-10-14-text-blinks-at-animation-seam.md)、[以为成片是 720p](2026-10-14-ai-thinks-export-is-720p.md)），这里收剩下的小的。
> 长期约束写进了 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 2、11、12、21、23 条和字幕样式那一节。

## 症状

1. **`set_transition` 只回 `{"cuts": 1, "type": "pushUp"}`**：不说转场落在哪、实际多长，也不说余料不够时补了多少定格。
   AI 只好每次都 look 一遍去猜，课程片里两处转场其实各有半秒是静止的画面，它不知道。
2. **`duplicate_items track=A2` 报「There is no track A2 yet; set_track changes existing tracks」**：只有 A1 时想复制一段到新的音频轨，
   报错却叫它去用 set_track（set_track 改不了还不存在的轨）。add_clips 写 A2 就是新开一条，同一个名字两个工具两种意思。
3. **look 读某个 upscale 出来的文件只回「SrtFlow could not read pictures from …mp4」**：不说为什么。AI 不知道是文件坏了、格式不认、
   还是自己参数写错了，换着参数又试了两次。
4. **look 把水下镜头的暗处当成黑边**：「black_bars: left 0.16, bottom 0.13」，暗棚里说话的人四边都是「黑边」（0.04 / 0.23 / 0.27 / 0.37）。
   AI 差点对它们 remove_black_bars。
5. **edit_subtitles 拒「PingFang SC」，却收「蘋方-簡」**；set_text 收「PingFang SC」。AI 先被拒，再从报错的字体表里抄了「蘋方-簡」才设上。
6. **find_audio 的说明写着结果里有 vocals，结果里一首都没有**：AI 想找带人声的歌，看不出哪首有。

## 根因

1. `AITimelineTools.transition` 只数改了几条缝。实际多长要过 `transitionCapacity` 的夹紧、窗口在哪要看两段是相接还是相叠、
   定格多少要看两边的余料（`transitionExtension`），这些渲染时都算了，结果里一样没报。
2. duplicate_items 借了 set_track 的轨道名解析（`AITrackSettings.target`）：它只认现有的轨，「正好多一条」（`AITrackName.target`
   给的 `.newAudioBottom`）落进 default 分支，报的是给 set_track 写的那句话。
3. 那几个文件是 2026-10-02 upscale 实测那天留下的：HEVC 封成了「hev1」（ffmpeg 封 HEVC 不点名时的默认写法），macOS 的视频框架只开
   「hvc1」—— 轨道 `isDecodable` 为假，取帧报 AVFoundationErrorDomain −11869 Cannot Open。之后生产的 upscale 都点名 hvc1
   （[视频 upscale](../architecture/video-upscale.md)），可旧文件还在用户的文件夹里。`AIFrameSampler.frames` 取不到就跳过（`try?`），
   look 只知道「一帧都没有」，没人去问为什么。
4. `AIBlackBars` 认黑边只看一行（一列）够不够黑：最亮的点 ≤ 40、平均 ≤ 20。水下、暗棚的边上每一列都过得了这两条（实测平均 2–12），
   从边上往里数，一直数到一点点亮到过线为止。真遮幅和暗处的差别不在「多黑」，在**有没有一道边**：遮幅和画面之间一刀切开
   （紧挨着的那一行比遮幅亮 25–200），暗处是一点点亮起来的（0–2）。
5. 字幕的字体清单（`FontCatalog`）用 Core Text 的 `kCTFontFamilyNameAttribute` 当族名。用户自己装在 ~/Library/Fonts 的
   PingFang-SC-Regular.ttf，这个属性给的是 name 表里的「蘋方-簡」（这份文件的默认名字是繁中写的），英文的「PingFang SC」在同一张表里
   却没人读。set_text 走的是 `NSFontManager` / `NSFont(name:)`，按英文名认得到。
6. 清单里每一首音乐都带 `has_vocals`（79 首全是 false，库里收的都是器乐），`AIMusicCredits.describe` 只在为真时写 `vocals: true`，
   于是一首都没写。说明答应了这个字段，AI 分不清「没有」和「不知道」。

## 修复

1. 新增 `AITransitionReport`：每条缝报 `after`（出场段）、`cut`（缝在哪）、`from` / `to` / `duration`（窗口，和时间线上的遮罩同一个
   `transitionWindow`）、被夹短时 `shortened_from`、余料不够时 `holds_last_frame` / `holds_first_frame`（`transitionExtension` 的定格那一截，
   压黑不借料不报），做不出来的 `not_shown`（太短、一侧藏着）；有定格时附一句怎么避免。磁吸开着时 perform 收尾会重排 V1，按收尾之后的状态报。
2. `AIDuplicate.apply` 收轨道名，按 add_clips 那一套解析（`AITrackName.target`）：新开的那条先放一条空轨指着它（粘贴只认现有的轨），
   复制出来的没落在它上面就收掉。结果另带 `tracks`（剪辑落在哪几条轨）。参数说明加一句「the next number opens a new track」（+36 字）。
3. 新增 `AIUnreadableVideo`：一帧都取不出来时查文件在不在、视频轨的四字符编码、`isDecodable`，换成 AI 能照做的话 ——
   hev1 说清楚是什么、用 compress_videos 转一份 H.264（自带的 ffmpeg 照读 hev1）再用。look 看文件、text_scan、分镜头、一次看几个文件都用它
   （分镜头扫描失败但文件本身没毛病时照旧说「找不到镜头」）。
4. `AIBlackBars`：数完黑行，紧挨着的一两行要比黑边最后几行亮出 `edgeStep`（20），或者里面有亮点（`edgePeak` 100：遮幅里的字幕、
   黑底上的东西）才算一道边；都没有的那一边「说不准」（`Reading` 里是 nil）。单看一帧（look 的描述）说不准当没有；几帧合起来
   （remove_black_bars）说不准的帧不参加这一边 —— 遮幅电影里碰巧有一帧是夜景，别因为它认不出遮幅；每一帧都说不准就当没有。
5. 新增 `FontFamilyNames`（读字体 name 表里的族名：nameID 1 / 16，Unicode / Windows 平台的 UTF-16、Mac 平台的 Roman），`SubtitleFont`
   挪进自己的文件并带上 `aliases`；`FontCatalog.scan` 顺手读。`resolvingFont` 族名先认、再认别名，回清单里的族名；报错列字体时带英文别名
   （「蘋方-簡 (PingFang SC)」）。
6. 音乐每一首都写 `vocals`（true / false）；音效不写。

## 验证

- `scripts/check-mcp.sh`：
  - `TransitionReportChecks`：余料充足时窗口跨在缝上两边各一半、不定格不附话；一点余料都没有时两边各定格 0.5 秒并附话、压黑不定格；
    要 3 秒两段各 2 秒夹到 0.8 并报原来要 3；all=true 里太短的缝说做不出来、一侧藏着的说看不见；type none 只报缝。
  - `DuplicateChecks`：只有 A1 时 track=A2 新开 A2 且落在上面；new_video 开 V2；指着新音频轨复制的却是画面时不留空轨；A3 照样报不认识、
    报错不提 set_track。
  - `UnreadableVideoChecks`：纯值的几句话；真写一段 H.264（AVAssetWriter），把视频轨的样本描述 avc1 改成 hev1：AVFoundation 照样报
    hev1、`isDecodable` 为假，给 AI 的话带文件名、hev1、compress_videos；原文件没毛病（`problem` 为 nil）；不在了的文件说不在了。
  - `BlackBarChecks`：水下（从左边一点点亮起来）和暗棚（四边往中间一点点亮）都没有黑边，水下那一边是「说不准」；暗地面上的真遮幅照样认得出；
    原有的遮幅、柱边、夜空星星、遮幅里的字幕、一个像素的边线都不变；几帧合起来时说不准的帧不抵消别的帧认出的黑边、每帧都说不准当没有。
  - `SubtitleStyleChecks`：「PingFang SC」认作「蘋方-簡」、不分大小写、中文别名也认、报错列字体带英文别名；手造的 name 表（繁中 / 英文 /
    Mac Roman 同名去重、全名和看不懂的编码跳过、残缺的表不崩）；系统冬青黑体的真表里有英文和中文的族名。
  - `MusicLibraryChecks`：音乐每首都写 vocals（false 也写），音效不写。
- 真素材（本机，盲测文件夹里的帧，不进仓库）：新规则下水下两帧左 / 下「说不准」、暗棚四边「说不准」，两条真遮幅（0.104 / 0.104、0.110 / 0.084）不变。
  旧规则在这些帧上报的就是症状里那几个数。
- 反向验证：见 PR 描述（不合并的草稿 PR，CI 上跑）。

## 教训 / 防回归

- **结果里只回一个计数等于没回**：渲染时算出来的几个关键数（落在哪、实际多长、有没有静止的画面）就是 AI 下一步要用的，顺手报出来。
- **借别的工具的解析要看它的报错是写给谁的**：set_track 的报错叫人去用 set_track，搬到 duplicate_items 就是错话；同一个名字（A2）两个工具
  两种意思，比报错本身更糟。
- **「读不出来」要追一步问为什么**：`try?` 吞掉的错误里就有答案（Cannot Open + 编码 hev1），说出来 AI 就知道去转一份。
- **区分两种东西的特征要挑它们真正不同的那一处**：黑边和暗处都够黑，差在有没有一道边；只调「多黑算黑」的门槛修不好。
  一帧里分不出来的（黑底上的一个圆和遮幅里的字幕）就承认分不出，写进文档，不硬猜。
- **一份字体有几个名字**：Core Text 给的「族名」只是 name 表里的一个，按名字认字体时要认全。
- **说明里答应的字段，结果里就要每次都有**：只在为真时写，等于让读的人去猜「没写」是什么意思。
